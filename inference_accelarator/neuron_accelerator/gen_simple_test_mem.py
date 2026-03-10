#!/usr/bin/env python3
"""
gen_simple_test_mem.py - Generate minimal data_mem.mem and spike_mem.mem
for a simple, manually-verifiable SNN test.

Network:
  Input  : cluster 0, neuron 0  (fires every timestep)
  Hidden : cluster 1, neuron 0  (receives from cluster 0, weight = 100)
  Output : cluster 2, neuron 0  (receives from cluster 1, weight = 50)

Expected behaviour:
  T=0: Input fires (from spike_mem).
       Cluster 1 neuron 0 accumulates: V_mem += 100
       → if threshold=80: FIRES, V_mem resets to 0
       Cluster 2 neuron 0 accumulates: V_mem += 50 (if cluster 1 fires)

Memory files produced:
  data_mem.mem  - hex bytes, one per line (init packets)
  spike_mem.mem - hex 11-bit words, one per line (input spikes)
"""

# ── Parameters matching testbench ──────────────────────────────────────────
NEURONS_PER_CLUSTER = 32
TIME_STEPS          = 5   # how many timesteps to simulate

# ── Network definition ─────────────────────────────────────────────────────
# (src_cluster, dst_cluster, weight_for_dst_neuron_0)
# The weight is a 32-bit signed integer (4 bytes, little-endian)
CONNECTIONS = [
    # src_cluster, dst_cluster, dst_neuron_id, bram_base_row, weight_value (int32)
    (0, 1, 0, 0, 100),   # cluster 0 → cluster 1 neuron 0, weight=100
    (1, 2, 0, 0, 50),    # cluster 1 → cluster 2 neuron 0, weight=50
]

# Neuron threshold = 80, decay_mode = 0 (no decay for simplicity)
# These are loaded via OPCODE_LOAD_NI + sub-opcodes inside neuron controller
# From neuron.v comments:
#   DECAY_INIT   <decay_opcode><v_low><v_b1><v_b2><v_high><END>
#   ADDER_VT_INIT <vt_opcode><v_low><v_b1><v_b2><v_high><END>
# From controller.v defaults: threshold and decay are set at reset to safe values.
# For this test we rely on ADDER_VT_INIT to set threshold.

# controller.v opcodes (from the code)
DECAY_INIT    = 0x01
ADDER_VT_INIT = 0x06
WORK_MODE     = 0x07
END_PACKET    = 0x00

# cluster_controller opcodes
OPCODE_LOAD_NI      = 0x01
OPCODE_LOAD_IF_BASE = 0x02
OPCODE_LOAD_IF_ADDR = 0x03

def int32_to_bytes(val):
    """Convert int32 to 4 little-endian bytes."""
    val = val & 0xFFFFFFFF
    return [(val >> (8*i)) & 0xFF for i in range(4)]

def pack_neuron_init(neuron_id, threshold, decay_mode=0):
    """
    Build OPCODE_LOAD_NI packet for one neuron.
    Sets threshold (ADDER_VT_INIT) and decay mode.
    Returns list of bytes.
    """
    pkt = []
    pkt.append(OPCODE_LOAD_NI)       # opcode
    pkt.append(neuron_id & 0xFF)     # neuron_id
    # flit_count: 2 sub-packets × 6 bytes each = 12 flits
    # Each sub-packet: opcode(1) + value(4) + END(1) = 6 bytes
    pkt.append(12)                    # flit_count
    # Sub-packet 1: set threshold
    pkt.append(ADDER_VT_INIT)
    pkt += int32_to_bytes(threshold)
    pkt.append(END_PACKET)
    # Sub-packet 2: set decay mode (WORK_MODE with decay=0)
    pkt.append(WORK_MODE)
    pkt.append(decay_mode)           # work_mode byte: bits[3:0]=work_mode, bits[5:4]=reset_mode
    pkt.append(END_PACKET)
    pkt.append(END_PACKET)
    pkt.append(END_PACKET)
    pkt.append(END_PACKET)
    return pkt

def pack_if_base(base_addr):
    """
    OPCODE_LOAD_IF_BASE packet: sets base_weight_addr in incoming_forwarder.
    Format: [OPCODE_LOAD_IF_BASE][addr_low][addr_high]
    """
    return [
        OPCODE_LOAD_IF_BASE,
        base_addr & 0xFF,
        (base_addr >> 8) & 0xFF,
    ]

def pack_if_addr(cluster_id):
    """
    OPCODE_LOAD_IF_ADDR packet: registers a source cluster_id.
    Format: [OPCODE_LOAD_IF_ADDR][cluster_id]
    """
    return [OPCODE_LOAD_IF_ADDR, cluster_id & 0xFF]

def pack_weight_row(bram_addr, weights_32):
    """
    weight_resolver init packet for ONE BRAM row.
    Packet: [addr_low][addr_high][flit_count][w0_b0][w0_b1][w0_b2][w0_b3]...[wN_b3]
    weights_32: list of NEURONS_PER_CLUSTER int32 values (weights for each dest neuron)
    """
    pkt = []
    pkt.append(bram_addr & 0xFF)
    pkt.append((bram_addr >> 8) & 0xFF)
    byte_data = []
    for w in weights_32:
        byte_data += int32_to_bytes(w)
    pkt.append(len(byte_data) & 0xFF)  # flit_count
    pkt += byte_data
    return pkt

# ══════════════════════════════════════════════════════════════════════════════
# BUILD PER-CLUSTER INIT DATA
# Clusters: we need 3 clusters (0=input, 1=hidden, 2=output)
# cluster_group_count=8, 4 clusters per group:
#   Group 0 handles clusters 0,1,2,3
# Each cluster receives its own init stream via cluster_controller
# ══════════════════════════════════════════════════════════════════════════════

# cluster_init[c] = list of bytes for cluster c
cluster_init = {0: [], 1: [], 2: []}

# ── Cluster 1 (hidden): receives spikes from cluster 0 ──────────────────────
c = 1
# 1a. Register cluster 0 as a source, base BRAM address = 0
cluster_init[c] += pack_if_base(0)          # BRAM rows for cluster 0 start at 0
cluster_init[c] += pack_if_addr(0)          # cluster 0 is a valid source

# 1b. Load weights: for each of 32 source neurons in cluster 0,
#     write one BRAM row. Row i = weights from src neuron i to all 32 dest neurons.
#     We only care about neuron 0 in cluster 1, so weights[:,0] = 100, rest = 0.
for src_neuron in range(NEURONS_PER_CLUSTER):
    weights = [0] * NEURONS_PER_CLUSTER
    if src_neuron == 0:
        weights[0] = 100    # cluster 1, neuron 0 gets weight 100 from src neuron 0
    bram_row = 0 + src_neuron   # base=0, row_index=src_neuron
    cluster_init[c] += pack_weight_row(bram_row, weights)

# 1c. Init neuron 0 with threshold=80
cluster_init[c] += pack_neuron_init(0, threshold=80)

# ── Cluster 2 (output): receives spikes from cluster 1 ──────────────────────
c = 2
# 2a. Register cluster 1 as a source, base BRAM address = 0
cluster_init[c] += pack_if_base(0)
cluster_init[c] += pack_if_addr(1)          # cluster 1 is a valid source

# 2b. Load weights: for src neuron 0 of cluster 1, weight to output neuron 0 = 50
for src_neuron in range(NEURONS_PER_CLUSTER):
    weights = [0] * NEURONS_PER_CLUSTER
    if src_neuron == 0:
        weights[0] = 50     # output neuron 0 gets weight 50 from hidden neuron 0
    bram_row = 0 + src_neuron
    cluster_init[c] += pack_weight_row(bram_row, weights)

# 2c. Init neuron 0 with threshold=80
cluster_init[c] += pack_neuron_init(0, threshold=80)

# ── Cluster 0 (input): no incoming weights, but we do a neuron init ──────────
# Input cluster doesn't need incoming_forwarder setup (no pre-synaptic)
cluster_init[0] += pack_neuron_init(0, threshold=255)  # high threshold, won't fire naturally

# ══════════════════════════════════════════════════════════════════════════════
# INTERLEAVE: The testbench sends bytes round-robin across ALL clusters.
# cluster 0 gets bytes going to network cluster 0, etc.
# In neuron_accelerator_tb, data_mem is sent byte-by-byte to load_data_in/data_in
# and the init_router routes to the correct cluster.
#
# The actual routing in the testbench sends to one cluster at a time based on
# header. Let's look at how it sends — actually it sends ALL bytes sequentially
# from data_mem.mem to load_data_in. The init_router decides which cluster gets it.
#
# Based on how the original data_mem.mem was generated, the format is:
# [cluster_id_byte][bytes for that cluster ...][next_cluster_id_byte][bytes...]
# OR all bytes go to broadcast and the opcode routing handles it per-cluster.
#
# From neuron_accelerator.v: chip_mode routes data_in to ALL clusters simultaneously.
# cluster_controller uses the opcode to decide what to do.
# But OPCODE_LOAD_NI has a neuron_id — in chip_mode EACH cluster processes ALL bytes.
# This means the same init byte stream is sent to ALL clusters.
#
# CONCLUSION: All clusters share ONE init stream. We need to send cluster-specific
# data using the routing. Looking at how testbench loads data:
# All load_data_in bytes go to all clusters via chip_mode=1 broadcast.
# The init_router (spike_forwarder_4) routes based on cluster target in the packet.
#
# SIMPLIFICATION for this test: Since chip_mode broadcast goes to all clusters,
# and OPCODE_LOAD_IF_ADDR stores cluster_id into routing table —
# just interleave all cluster inits in one flat stream.
# ══════════════════════════════════════════════════════════════════════════════

all_bytes = []
# Send cluster 1 init first, then cluster 2 init
# Cluster 0 doesn't need incoming weight setup
for c_id, data in [(1, cluster_init[1]), (2, cluster_init[2])]:
    all_bytes += data

print(f"Total init bytes: {len(all_bytes)}")

# Write data_mem.mem
with open("data_mem_simple.mem", "w") as f:
    for b in all_bytes:
        f.write(f"{b:02x}\n")

print(f"Written data_mem_simple.mem ({len(all_bytes)} bytes)")

# ══════════════════════════════════════════════════════════════════════════════
# SPIKE_MEM: Input spikes = cluster 0, neuron 0 fires every timestep
# 11-bit packet: [cluster_id:6][neuron_id:5]
# cluster 0, neuron 0 → 0b000000_00000 = 0x000
# But testbench reads spike_mem as input spikes injected into main FIFO.
# ══════════════════════════════════════════════════════════════════════════════

INPUT_CLUSTER  = 0
INPUT_NEURON   = 0
spike_packet   = (INPUT_CLUSTER << 5) | INPUT_NEURON   # 11-bit

spike_entries = []
for t in range(TIME_STEPS):
    spike_entries.append(spike_packet)  # fire once per timestep

with open("spike_mem_simple.mem", "w") as f:
    for pkt in spike_entries:
        f.write(f"{pkt:03x}\n")

print(f"Written spike_mem_simple.mem ({len(spike_entries)} entries)")

# ══════════════════════════════════════════════════════════════════════════════
# EXPECTED COMPUTATION (for verification)
# ══════════════════════════════════════════════════════════════════════════════
print("\n=== Expected Computation ===")
print("Threshold for hidden (cluster 1, neuron 0) = 80")
print("Threshold for output (cluster 2, neuron 0) = 80")
print()

vmem_hidden = 0
vmem_output = 0
for t in range(TIME_STEPS):
    # Input fires → cluster 1 receives weight 100
    vmem_hidden += 100
    hidden_fired = vmem_hidden >= 80
    if hidden_fired:
        vmem_hidden = 0  # reset after firing

    # Cluster 1 fires → cluster 2 receives weight 50
    if hidden_fired:
        vmem_output += 50
    output_fired = vmem_output >= 80
    if output_fired:
        vmem_output = 0

    print(f"T={t}: hidden_vmem={vmem_hidden} fired={int(hidden_fired)} | "
          f"output_vmem={vmem_output} fired={int(output_fired)}")

print()
print("These V_mem values should appear in the dump at addresses:")
print(f"  hidden (cluster1, neuron0): vmem_base + 1*32 + 0 = vmem_base + 32")
print(f"  output (cluster2, neuron0): vmem_base + 2*32 + 0 = vmem_base + 64")
