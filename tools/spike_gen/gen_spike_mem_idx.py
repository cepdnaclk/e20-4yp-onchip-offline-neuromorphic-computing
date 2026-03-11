#!/usr/bin/env python3
"""
gen_spike_mem_idx.py
====================
Fast, dependency-free spike_mem.mem generator from raw MNIST IDX files.
Writes output to file (no stdout buffering issues).

Usage:
    python3 gen_spike_mem_idx.py \
        --images tools/mnist_data/t10k-images-idx3-ubyte \
        --labels tools/mnist_data/t10k-labels-idx1-ubyte \
        --samples 100 \
        --timesteps 16 \
        --out inference_accelarator/neuron_accelerator/spike_mem.mem \
        --lbl inference_accelarator/neuron_accelerator/test_labels.txt \
        --log /tmp/spike_gen.log
"""

import struct
import random
import sys
import argparse
from pathlib import Path

# ── Hardware constants ────────────────────────────────────────────────────────
NPC       = 32      # neurons per cluster
IN_SIZE   = 784     # 28×28 pixels
NO_SPIKE  = 0x7FF   # sentinel written when neuron is silent


def encode_packet(nid):
    """11-bit spike packet: [cluster_id:6][neuron_in_cluster:5]"""
    return ((nid // NPC) << 5) | (nid % NPC)


def rate_encode(pixels, timesteps, threshold=0.05):
    """
    Rate-code one image (pixels: list of floats 0..1).
    Returns list[set]: firing[t] = set of neuron indices that fire at timestep t.
    """
    firing = [set() for _ in range(timesteps)]
    for nid, val in enumerate(pixels):
        if val < threshold:
            continue
        n_spikes = max(1, round(val * timesteps))
        if n_spikes >= timesteps:
            for t in range(timesteps):
                firing[t].add(nid)
        else:
            step = timesteps / n_spikes
            for k in range(n_spikes):
                firing[int(k * step)].add(nid)
    return firing


def load_idx(image_path, label_path, num_samples, log):
    """Load raw IDX binary files (uncompressed)."""
    log.write(f"[idx] Reading images from: {image_path}\n"); log.flush()
    with open(image_path, 'rb') as f:
        magic, n, rows, cols = struct.unpack('>IIII', f.read(16))
        log.write(f"[idx] magic={magic} n={n} rows={rows} cols={cols}\n"); log.flush()
        total_px = rows * cols
        n_read = min(n, num_samples)
        raw = f.read(total_px * n_read)
    X = []
    for i in range(n_read):
        base = i * total_px
        X.append([raw[base + j] / 255.0 for j in range(total_px)])

    log.write(f"[idx] Reading labels from: {label_path}\n"); log.flush()
    with open(label_path, 'rb') as f:
        magic2, n2 = struct.unpack('>II', f.read(8))
        raw_lbl = f.read(n_read)
    y = list(raw_lbl)

    log.write(f"[idx] Loaded {len(X)} samples\n"); log.flush()
    return X, y


def generate(X, y, timesteps, out_path, lbl_path, threshold, log):
    num_samples = len(X)
    total_entries = num_samples * timesteps * IN_SIZE
    log.write(f"[gen] {num_samples} samples × {timesteps} timesteps × {IN_SIZE} neurons = {total_entries:,} entries\n")
    log.flush()

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(lbl_path).parent.mkdir(parents=True, exist_ok=True)

    total_spikes = 0
    with open(out_path, 'w') as fout:
        for s, pixels in enumerate(X):
            firing = rate_encode(pixels, timesteps, threshold)
            for t in range(timesteps):
                for nid in range(IN_SIZE):
                    if nid in firing[t]:
                        fout.write(f"{encode_packet(nid):03X}\n")
                        total_spikes += 1
                    else:
                        fout.write(f"{NO_SPIKE:03X}\n")
            if (s + 1) % 10 == 0:
                log.write(f"[gen] encoded {s+1}/{num_samples}\n"); log.flush()

    with open(lbl_path, 'w') as fl:
        for label in y:
            fl.write(f"{label}\n")

    log.write(f"[gen] Done. spike entries={total_entries:,}  spike events={total_spikes:,} "
              f"({100.0*total_spikes/total_entries:.1f}% active)\n")
    log.write(f"[gen] spike_mem.mem  → {out_path}\n")
    log.write(f"[gen] test_labels.txt → {lbl_path}\n")
    log.flush()


def main():
    repo = Path(__file__).resolve().parent.parent.parent
    p = argparse.ArgumentParser()
    p.add_argument('--images',    default=str(repo / 'tools/mnist_data/t10k-images-idx3-ubyte'))
    p.add_argument('--labels',    default=str(repo / 'tools/mnist_data/t10k-labels-idx1-ubyte'))
    p.add_argument('--samples',   type=int,   default=100)
    p.add_argument('--timesteps', type=int,   default=16)
    p.add_argument('--threshold', type=float, default=0.05)
    p.add_argument('--out',       default=str(repo / 'inference_accelarator/neuron_accelerator/spike_mem.mem'))
    p.add_argument('--lbl',       default=str(repo / 'inference_accelarator/neuron_accelerator/test_labels.txt'))
    p.add_argument('--log',       default='/tmp/spike_gen.log')
    args = p.parse_args()

    with open(args.log, 'w') as log:
        log.write("=" * 60 + "\n")
        log.write(f"  spike_mem.mem Generator\n")
        log.write(f"  samples={args.samples}  timesteps={args.timesteps}  threshold={args.threshold}\n")
        log.write("=" * 60 + "\n")
        log.flush()

        X, y = load_idx(args.images, args.labels, args.samples, log)
        generate(X, y, args.timesteps, args.out, args.lbl, args.threshold, log)

        log.write("[done]\n")


if __name__ == '__main__':
    main()
