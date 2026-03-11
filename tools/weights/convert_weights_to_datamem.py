#!/usr/bin/env python3
"""
convert_weights_to_datamem.py
==============================
Converts a trained SNN weight file into data_mem.mem for the neuron accelerator.

Network : 784 → 200 → 10  (integer weights in best_weights_epoch_1.txt)
Hardware: 32 clusters max  (upper router PORTS=8, each lower router has 4 ports)

Cluster mapping
  Input  neurons  (784) → clusters  0-24  (25 × 32 = 800 slots, 784 used)
  Hidden neurons  (192) → clusters 25-30  ( 6 × 32 = 192 slots)
    NOTE: only the first 192 of the 200 trained hidden neurons are used;
          the last 8 are dropped because the hardware only has 32 clusters total.
  Output neurons   (10) → cluster   31    (32 slots, 10 used)

Router addressing (from neuron_accelerator.v)
  Upper router  ROUTER_ID = 0xA0  (PORTS=8, ROUTER_TYPE=1 upper layer)
  Lower router i ROUTER_ID = 0x80 + i*4   (i = 0..7)
    i=0 → 0x80,  i=1 → 0x84,  …  i=7 → 0x9C

  dest byte routing:
    dest = cluster_id  (0x00–0x7F) → cluster_controller of that cluster
    dest = 0x80 + i*4              → lower router i SELF → weight_resolver

Packet frame format
    [dest_byte][payload_len][payload_byte × payload_len]

Weight row packet  (goes to lower router i SELF → weight_resolver)
    payload = [addr_lo][addr_hi][byte_count=128][w0_b0..w31_b3]  (131 bytes)

Cluster IF_BASE    (OPCODE 0x02)
    payload = [0x02][base_lo][base_hi]

Cluster IF_ADDR    (OPCODE 0x03)
    payload = [0x03][src_cluster_id]

Cluster LOAD_NI    (OPCODE 0x01)
    payload = [0x01][neuron_local][12]
              [0x06][vt_b0][vt_b1][vt_b2][vt_b3][0x00]
              [0x07][0x00][0x00][0x00][0x00][0x00]

Usage
    python convert_weights_to_datamem.py
    python convert_weights_to_datamem.py --hidden_threshold 30 --output_threshold 1
    python convert_weights_to_datamem.py --verify
"""

import argparse
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# NETWORK CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
INPUT_SIZE   = 784
HIDDEN_FULL  = 200   # neurons in the weight file
HIDDEN_SIZE  = 192   # neurons mapped to hardware (6 × 32)
OUTPUT_SIZE  = 10
NPC          = 32    # neurons per cluster

INPUT_CLUSTERS  = list(range(0,  25))   # clusters 0–24
HIDDEN_CLUSTERS = list(range(25, 31))   # clusters 25–30
OUTPUT_CLUSTER  = 31

DEFAULT_HIDDEN_THRESHOLD = 30
DEFAULT_OUTPUT_THRESHOLD = 1

# Hardware opcodes
OPCODE_LOAD_NI      = 0x01
OPCODE_LOAD_IF_BASE = 0x02
OPCODE_LOAD_IF_ADDR = 0x03
ADDER_VT_INIT       = 0x06
WORK_MODE           = 0x07
END_BYTE            = 0x00


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def lower_router_dest(group_idx):
    """Dest byte for lower router group_idx SELF (routes to weight_resolver)."""
    return 0x80 + group_idx * 4


def int32_le(val):
    """Signed int32 → 4 little-endian bytes."""
    v = int(val) & 0xFFFFFFFF
    return [(v >> (8 * i)) & 0xFF for i in range(4)]


def to_q16_16(integer_weight, scale=1):
    """Integer weight → Q16.16 signed int32 (multiply by 2^16)."""
    v = int(integer_weight) * int(scale) * 65536
    return max(-(1 << 31), min((1 << 31) - 1, v))


def frame(dest, payload):
    """Wrap payload in [dest][len][payload…]. len must fit in 1 byte (≤ 255)."""
    n = len(payload)
    if n > 255:
        raise ValueError(f"Payload length {n} > 255 for dest=0x{dest:02X}")
    return [int(dest), n] + [int(b) for b in payload]


# ─────────────────────────────────────────────────────────────────────────────
# PACKET BUILDERS
# ─────────────────────────────────────────────────────────────────────────────

def pkt_if_base(cluster_id, bram_base_addr):
    """Tell cluster_controller where this source cluster's weights start in BRAM."""
    return frame(cluster_id, [OPCODE_LOAD_IF_BASE,
                               bram_base_addr & 0xFF,
                               (bram_base_addr >> 8) & 0xFF])


def pkt_if_addr(cluster_id, src_cluster_id):
    """Tell cluster_controller which source cluster to listen to."""
    return frame(cluster_id, [OPCODE_LOAD_IF_ADDR, src_cluster_id & 0xFF])


def pkt_neuron_init(cluster_id, neuron_local, threshold_q16):
    """Initialise one neuron: fire threshold and work mode."""
    vt = int32_le(threshold_q16)
    payload = [
        OPCODE_LOAD_NI, neuron_local & 0xFF, 12,
        ADDER_VT_INIT, vt[0], vt[1], vt[2], vt[3], END_BYTE,
        WORK_MODE, END_BYTE, END_BYTE, END_BYTE, END_BYTE, END_BYTE,
    ]
    return frame(cluster_id, payload)


def pkt_weight_row(group_idx, bram_addr, weights_int32):
    """
    One 32-neuron weight row → weight_resolver via lower router SELF.
    payload = [addr_lo][addr_hi][128][w0_b0 .. w31_b3]  (131 bytes total)
    """
    assert len(weights_int32) == NPC
    weight_bytes = []
    for w in weights_int32:
        weight_bytes += int32_le(w)          # 32 × 4 = 128 bytes
    payload = ([bram_addr & 0xFF, (bram_addr >> 8) & 0xFF, len(weight_bytes)]
               + weight_bytes)
    return frame(lower_router_dest(group_idx), payload)


# ─────────────────────────────────────────────────────────────────────────────
# WEIGHT FILE PARSER
# ─────────────────────────────────────────────────────────────────────────────

def parse_weights(filepath):
    """
    Parse best_weights_epoch_1.txt.
    Returns W1[784][200], W2[200][10] as list-of-lists of ints.
    """
    print(f"[weights] Parsing {filepath}")
    W1, W2 = [], []
    current = None
    with open(filepath) as fh:
        for line in fh:
            s = line.strip()
            if not s:
                continue
            if 'Layer 1' in s:
                current = W1
            elif 'Layer 2' in s:
                current = W2
            elif current is not None:
                try:
                    current.append(list(map(int, s.split())))
                except ValueError:
                    pass

    assert len(W1) == INPUT_SIZE and len(W1[0]) == HIDDEN_FULL, \
        f"W1 shape {len(W1)}×{len(W1[0])} ≠ expected {INPUT_SIZE}×{HIDDEN_FULL}"
    assert len(W2) == HIDDEN_FULL and len(W2[0]) == OUTPUT_SIZE, \
        f"W2 shape {len(W2)}×{len(W2[0])} ≠ expected {HIDDEN_FULL}×{OUTPUT_SIZE}"

    print(f"[weights] W1: {INPUT_SIZE}×{HIDDEN_FULL}   W2: {HIDDEN_FULL}×{OUTPUT_SIZE}")
    print(f"[weights] Using first {HIDDEN_SIZE}/{HIDDEN_FULL} hidden neurons "
          f"({HIDDEN_FULL - HIDDEN_SIZE} dropped — hardware limit)")
    return W1, W2


# ─────────────────────────────────────────────────────────────────────────────
# INIT STREAM BUILDER
# ─────────────────────────────────────────────────────────────────────────────

def build_data_mem(W1, W2, hidden_thresh_q16, output_thresh_q16, scale=1):
    """
    Build the full init byte stream.

    For each destination cluster (hidden 25-30, then output 31):
      For each source cluster that feeds it:
        1. pkt_if_base   → cluster_controller
        2. pkt_if_addr   → cluster_controller
        3. NPC × pkt_weight_row → weight_resolver (via lower router)
      For each neuron in the cluster:
        4. pkt_neuron_init → cluster_controller

    Returns (byte_list, stats_dict).
    """
    out   = []
    stats = {'weight_rows': 0, 'ctrl_pkts': 0, 'ni_pkts': 0}

    # ── Hidden clusters 25–30 ──────────────────────────────────────────────
    for hi, dst_cl in enumerate(HIDDEN_CLUSTERS):
        group_idx = dst_cl // 4
        dst_start = hi * NPC          # global index of first neuron in this cluster
        dst_end   = dst_start + NPC   # exclusive

        for sci, src_cl in enumerate(INPUT_CLUSTERS):
            bram_base  = sci * NPC    # BRAM row base for this source cluster
            src_start  = sci * NPC    # global input neuron index

            out.extend(pkt_if_base(dst_cl, bram_base))
            out.extend(pkt_if_addr(dst_cl, src_cl))
            stats['ctrl_pkts'] += 2

            for src_local in range(NPC):
                src_global = src_start + src_local
                bram_addr  = bram_base + src_local
                row = []
                for dst_local in range(NPC):
                    dst_global = dst_start + dst_local
                    if src_global < INPUT_SIZE and dst_global < HIDDEN_SIZE:
                        w = to_q16_16(W1[src_global][dst_global], scale)
                    else:
                        w = 0
                    row.append(w)
                out.extend(pkt_weight_row(group_idx, bram_addr, row))
                stats['weight_rows'] += 1

        for n_local in range(NPC):
            dst_global = dst_start + n_local
            if dst_global < HIDDEN_SIZE:
                out.extend(pkt_neuron_init(dst_cl, n_local, hidden_thresh_q16))
                stats['ni_pkts'] += 1

        print(f"  Hidden cluster {dst_cl} (group {group_idx}): "
              f"{min(NPC, HIDDEN_SIZE - dst_start)} neurons, "
              f"{len(INPUT_CLUSTERS)} src clusters")

    # ── Output cluster 31 ──────────────────────────────────────────────────
    dst_cl    = OUTPUT_CLUSTER
    group_idx = dst_cl // 4    # = 7

    for sci, src_cl in enumerate(HIDDEN_CLUSTERS):
        bram_base  = sci * NPC
        src_start  = sci * NPC    # index into W2 rows

        out.extend(pkt_if_base(dst_cl, bram_base))
        out.extend(pkt_if_addr(dst_cl, src_cl))
        stats['ctrl_pkts'] += 2

        for src_local in range(NPC):
            src_global = src_start + src_local
            bram_addr  = bram_base + src_local
            row = []
            for dst_local in range(NPC):
                if src_global < HIDDEN_SIZE and dst_local < OUTPUT_SIZE:
                    w = to_q16_16(W2[src_global][dst_local], scale)
                else:
                    w = 0
                row.append(w)
            out.extend(pkt_weight_row(group_idx, bram_addr, row))
            stats['weight_rows'] += 1

    for n_local in range(NPC):
        if n_local < OUTPUT_SIZE:
            out.extend(pkt_neuron_init(dst_cl, n_local, output_thresh_q16))
            stats['ni_pkts'] += 1

    print(f"  Output  cluster {dst_cl} (group {group_idx}): "
          f"{OUTPUT_SIZE} neurons, {len(HIDDEN_CLUSTERS)} src clusters")

    stats['total_bytes'] = len(out)
    return out, stats


# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL SOFTWARE SANITY CHECK
# ─────────────────────────────────────────────────────────────────────────────

def software_forward(W1, W2, pixels, hidden_thresh, output_thresh,
                     timesteps=16, scale=1):
    """Rate-coded LIF forward pass. Returns (predicted_digit, spike_counts)."""
    import random
    vm_h = [0.0] * HIDDEN_SIZE
    vm_o = [0.0] * OUTPUT_SIZE
    cnt  = [0]   * OUTPUT_SIZE
    for _ in range(timesteps):
        inp = [1 if (pixels[i] / 255.0) > random.random() else 0
               for i in range(INPUT_SIZE)]
        fired_h = []
        for h in range(HIDDEN_SIZE):
            vm_h[h] += sum(W1[i][h] * scale * inp[i] for i in range(INPUT_SIZE))
            f = int(vm_h[h] >= hidden_thresh)
            if f:
                vm_h[h] = 0.0
            fired_h.append(f)
        for o in range(OUTPUT_SIZE):
            vm_o[o] += sum(W2[h][o] * scale * fired_h[h] for h in range(HIDDEN_SIZE))
            f = int(vm_o[o] >= output_thresh)
            if f:
                vm_o[o] = 0.0
                cnt[o] += 1
    return cnt.index(max(cnt)), cnt


# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

def main():
    repo_root   = Path(__file__).resolve().parent.parent.parent
    default_wts = str(Path(__file__).resolve().parent.parent / 'best_weights_epoch_1.txt')
    default_out = str(repo_root / 'inference_accelarator' / 'neuron_accelerator'
                      / 'data_mem.mem')

    p = argparse.ArgumentParser(description="Convert SNN weights → data_mem.mem")
    p.add_argument('--weights',          default=default_wts)
    p.add_argument('--output',           default=default_out)
    p.add_argument('--hidden_threshold', type=int, default=DEFAULT_HIDDEN_THRESHOLD,
                   help=f'Hidden layer fire threshold (default {DEFAULT_HIDDEN_THRESHOLD})')
    p.add_argument('--output_threshold', type=int, default=DEFAULT_OUTPUT_THRESHOLD,
                   help=f'Output layer fire threshold (default {DEFAULT_OUTPUT_THRESHOLD})')
    p.add_argument('--scale',            type=int, default=1,
                   help='Multiply all weights by this integer (default 1)')
    p.add_argument('--verify',           action='store_true',
                   help='Run a quick software LIF pass to sanity-check the weights')
    args = p.parse_args()

    h_q16 = args.hidden_threshold * 65536
    o_q16 = args.output_threshold * 65536

    print("=" * 65)
    print("  Neuron Accelerator — Weight → data_mem.mem Converter")
    print("=" * 65)
    print(f"  Network  : {INPUT_SIZE} → {HIDDEN_FULL} (hw:{HIDDEN_SIZE}) → {OUTPUT_SIZE}")
    print(f"  Clusters : input=0-24, hidden=25-30, output=31")
    print(f"  H-thresh : {args.hidden_threshold}  (Q16.16 = 0x{h_q16:08X})")
    print(f"  O-thresh : {args.output_threshold}  (Q16.16 = 0x{o_q16:08X})")
    print(f"  Scale    : ×{args.scale}")
    print()

    W1, W2 = parse_weights(args.weights)

    print("\n[build] Assembling init packet stream ...")
    byte_stream, stats = build_data_mem(W1, W2,
                                        hidden_thresh_q16=h_q16,
                                        output_thresh_q16=o_q16,
                                        scale=args.scale)

    print(f"\n[stats] Weight BRAM rows  : {stats['weight_rows']:,}")
    print(f"[stats] Ctrl pkts (IF/NI) : {stats['ctrl_pkts']:,}")
    print(f"[stats] Neuron init pkts  : {stats['ni_pkts']:,}")
    print(f"[stats] Total bytes       : {stats['total_bytes']:,}")

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, 'w') as fh:
        for b in byte_stream:
            fh.write(f"{b:02X}\n")

    print(f"\n[output] Written → {args.output}")
    print(f"         {len(byte_stream):,} lines (one hex byte per line)")

    if args.verify:
        print("\n[verify] Software LIF pass (all-pixel=200, 16 timesteps) ...")
        dummy = [200] * INPUT_SIZE
        pred, spk = software_forward(W1, W2, dummy,
                                     args.hidden_threshold,
                                     args.output_threshold,
                                     timesteps=16,
                                     scale=args.scale)
        print(f"[verify] Output spike counts : {spk}")
        print(f"[verify] Predicted class     : {pred}")

    print()
    print("[info] Output spike packet for digit k:")
    print(f"       (31 << 5) | k  =  0x{(31 << 5):03X} | k  "
          f"(e.g. digit 0 → 0x{(31<<5)|0:03X}, digit 9 → 0x{(31<<5)|9:03X})")
    print("=" * 65)


if __name__ == '__main__':
    main()
