#!/usr/bin/env python3
"""
XOR Test Data Generator for the Neuromorphic Accelerator
=========================================================
Generates data_mem.mem and spike_mem.mem for XOR test.

KEY INSIGHT: The spike_forwarder forwarding_map tables MUST be initialized!
Without them, no spikes get routed during inference.

Routing hierarchy:
  main_fifo_in → spike_forwarder_8 → spike_forwarder_4[group] → clusters
  clusters → spike_forwarder_4[group] → spike_forwarder_8 → main_fifo_out

Forwarding map bits (spike_forwarder_8, 9 bits):
  bit[0] = main port, bit[1..8] = group ports 0-7

Forwarding map bits (spike_forwarder_4, 5 bits):
  bit[0] = main port (up to forwarder_8), bit[1..4] = cluster ports 0-3
"""

import os

# ============================================================
# Constants
# ============================================================
NEURONS_PER_CLUSTER = 32

# Neuron controller opcodes (LIF variant)
DECAY_INIT    = 0xFE
ADDER_VT_INIT = 0xF9
WORK_MODE_CMD = 0xF7
END_PACKET    = 0xFF

# Cluster controller opcodes
OPCODE_LOAD_NI      = 0x01
OPCODE_LOAD_IF_BASE = 0x02
OPCODE_LOAD_IF_ADDR = 0x03

# Work modes
LIF2_MODE  = 0x01

# Router IDs
UPPER_ROUTER_ID = 0xA0
LOWER_ROUTER_0_ID = 0x80

# External input virtual cluster ID
EXTERNAL_INPUT_CLUSTER_ID = 62

FRAC_BITS = 16

# ============================================================
# Helpers
# ============================================================

def float_to_q16_16(value):
    scaled = int(round(value * (1 << FRAC_BITS)))
    scaled = max(-(1 << 31), min((1 << 31) - 1, scaled))
    if scaled < 0:
        scaled = (1 << 32) + scaled
    return scaled

def val_to_le_bytes(value):
    return [(value >> (i*8)) & 0xFF for i in range(4)]

# ============================================================
# Neuron Config
# ============================================================

def make_neuron_config(decay_value, vt_value, work_mode):
    c = []
    c.append(DECAY_INIT)
    c.extend(val_to_le_bytes(float_to_q16_16(decay_value)))
    c.append(END_PACKET)
    c.append(ADDER_VT_INIT)
    c.extend(val_to_le_bytes(float_to_q16_16(vt_value)))
    c.append(END_PACKET)
    c.append(WORK_MODE_CMD)
    c.append(work_mode)
    return c

# ============================================================
# Cluster Controller Commands
# ============================================================

def make_ni_command(neuron_id, config_bytes):
    return [OPCODE_LOAD_NI, neuron_id, len(config_bytes)] + config_bytes

def make_if_base_command(base_addr):
    return [OPCODE_LOAD_IF_BASE, base_addr & 0xFF, (base_addr >> 8) & 0xFF]

def make_if_addr_command(cluster_id):
    return [OPCODE_LOAD_IF_ADDR, cluster_id & 0xFF]

# ============================================================
# Flat Packet Builders
# ============================================================

def packet_to_cluster(group, cluster_port, data_bytes):
    """Route data to a specific cluster (flat format)."""
    address = ((group & 0x07) << 2) | (cluster_port & 0x03)
    return [address, len(data_bytes)] + data_bytes

def packet_to_upper_self(data_bytes):
    """
    Route data to upper router's self output → spike_forwarder_8 controller.
    Address = 0xA0 (upper router ID). NO self_data_mng wrapping.
    """
    return [UPPER_ROUTER_ID, len(data_bytes)] + data_bytes

def packet_to_lower_self(group, data_bytes):
    """
    Route data to lower router's self_data_mng.
    Address = lower router ID. self_data_mng then splits by bit[0].
    """
    router_id = group * 4 + 0x80
    return [router_id, len(data_bytes)] + data_bytes

def packet_to_weight_resolver(group, wr_data_bytes):
    """Route data to weight resolver via self_data_mng (port=1)."""
    sdm_payload = [0x01, len(wr_data_bytes)] + wr_data_bytes
    return packet_to_lower_self(group, sdm_payload)

def packet_to_spike_forwarder_4(group, sf4_data_bytes):
    """Route data to spike_forwarder_4 via self_data_mng (port=0)."""
    sdm_payload = [0x00, len(sf4_data_bytes)] + sf4_data_bytes
    return packet_to_lower_self(group, sdm_payload)

# ============================================================
# High-Level Packet Constructors
# ============================================================

def pkt_configure_neuron(group, cluster_port, neuron_id, decay, vt, mode):
    config = make_neuron_config(decay, vt, mode)
    ni_cmd = make_ni_command(neuron_id, config)
    return packet_to_cluster(group, cluster_port, ni_cmd)

def pkt_set_if_base(group, cluster_port, base_addr):
    return packet_to_cluster(group, cluster_port, make_if_base_command(base_addr))

def pkt_set_if_addr(group, cluster_port, source_cluster_id):
    return packet_to_cluster(group, cluster_port, make_if_addr_command(source_cluster_id))

def pkt_load_weight_row(group, row_addr, weights_32bit):
    assert len(weights_32bit) == NEURONS_PER_CLUSTER
    weight_bytes = []
    for w in weights_32bit:
        weight_bytes.extend(val_to_le_bytes(w))
    wr_data = [row_addr & 0xFF, (row_addr >> 8) & 0xFF, len(weight_bytes)] + weight_bytes
    return packet_to_weight_resolver(group, wr_data)

# ============================================================
# Spike Forwarder Init
# ============================================================

def pkt_init_sf8_row(row_index, forwarding_row_9bit):
    """
    Initialize spike_forwarder_8's forwarding_map[row_index].
    
    Controller_8 takes 2 bytes:
      Byte 0: {row_index[3:0] = data[7:4], forwarding_row[8] = data[0]}
      Byte 1: forwarding_row[7:0]
    
    forwarding_row is 9 bits: [bit8, bit7..0]
      bit[0] = main port, bit[1..8] = group ports 0-7
    """
    byte0 = ((row_index & 0x0F) << 4) | (forwarding_row_9bit >> 8)
    byte1 = forwarding_row_9bit & 0xFF
    return packet_to_upper_self([byte0, byte1])

def pkt_init_sf4_row(group, row_index, forwarding_row_5bit):
    """
    Initialize spike_forwarder_4's forwarding_map[row_index].
    
    Controller_4 takes 1 byte:
      data[7:5] = row_index, data[4:0] = forwarding_row
    
    forwarding_row is 5 bits:
      bit[0] = main port (up to sf8), bit[1..4] = cluster ports 0-3
    """
    byte0 = ((row_index & 0x07) << 5) | (forwarding_row_5bit & 0x1F)
    return packet_to_spike_forwarder_4(group, [byte0])

# ============================================================
# XOR Network
# ============================================================

def generate_xor_data():
    b = []
    
    # ========== 1. SPIKE FORWARDER INITIALIZATION ==========
    # This MUST come first so spikes can flow during inference.
    
    # --- spike_forwarder_8 ---
    # Map[0] (from main): forward to group 0 (bit[1]) = 0b0_0000_0010
    b.extend(pkt_init_sf8_row(0, 0b0_00000010))
    # Map[1] (from group 0): forward to main (bit[0]) = 0b0_0000_0001
    b.extend(pkt_init_sf8_row(1, 0b0_00000001))
    
    # --- spike_forwarder_4 for group 0 ---
    # Map[0] (from main/sf8): forward to cluster 0 (bit[1]) AND cluster 1 (bit[2])
    #   = 0b00110
    b.extend(pkt_init_sf4_row(0, 0, 0b00110))
    # Map[1] (from cluster 0): forward to main (bit[0]) AND cluster 1 (bit[2])
    #   Cluster 0's output spikes need to reach cluster 1 AND go back to main/sf8
    #   = 0b00101
    b.extend(pkt_init_sf4_row(0, 1, 0b00101))
    # Map[2] (from cluster 1): forward to main (bit[0]) only
    #   = 0b00001
    b.extend(pkt_init_sf4_row(0, 2, 0b00001))
    
    # ========== 2. NEURON CONFIGURATION ==========
    # H0 (cluster 0, neuron 0): OR-like, VT=3.0
    b.extend(pkt_configure_neuron(0, 0, 0, decay=0.0, vt=3.0, mode=LIF2_MODE))
    # H1 (cluster 0, neuron 1): AND-like, VT=8.0
    b.extend(pkt_configure_neuron(0, 0, 1, decay=0.0, vt=8.0, mode=LIF2_MODE))
    # Output (cluster 1, neuron 0): XOR, VT=10.0
    b.extend(pkt_configure_neuron(0, 1, 0, decay=0.0, vt=10.0, mode=LIF2_MODE))
    
    # ========== 3. INCOMING FORWARDER CONFIG ==========
    # Cluster 0: base=0, register external cluster 62
    b.extend(pkt_set_if_base(0, 0, 0))
    b.extend(pkt_set_if_addr(0, 0, EXTERNAL_INPUT_CLUSTER_ID))
    # Cluster 1: base=2, register cluster 0
    b.extend(pkt_set_if_base(0, 1, 2))
    b.extend(pkt_set_if_addr(0, 1, 0))
    
    # ========== 4. WEIGHT LOADING ==========
    # Row 0: A → H0:+5, H1:+5
    row0 = [0] * NEURONS_PER_CLUSTER
    row0[0] = float_to_q16_16(5.0)
    row0[1] = float_to_q16_16(5.0)
    b.extend(pkt_load_weight_row(0, 0, row0))
    
    # Row 1: B → H0:+5, H1:+5
    row1 = [0] * NEURONS_PER_CLUSTER
    row1[0] = float_to_q16_16(5.0)
    row1[1] = float_to_q16_16(5.0)
    b.extend(pkt_load_weight_row(0, 1, row1))
    
    # Row 2: H0 → Out:+20
    row2 = [0] * NEURONS_PER_CLUSTER
    row2[0] = float_to_q16_16(20.0)
    b.extend(pkt_load_weight_row(0, 2, row2))
    
    # Row 3: H1 → Out:-20
    row3 = [0] * NEURONS_PER_CLUSTER
    row3[0] = float_to_q16_16(-20.0)
    b.extend(pkt_load_weight_row(0, 3, row3))
    
    return b

def generate_spike_mem():
    SPIKE_A = (EXTERNAL_INPUT_CLUSTER_ID << 5) | 0
    SPIKE_B = (EXTERNAL_INPUT_CLUSTER_ID << 5) | 1
    NO_SPIKE = 0x7FF
    
    time_step_window = 10
    patterns = [(0,0), (0,1), (1,0), (1,1)]
    
    spikes = []
    for a, b_val in patterns:
        for _ in range(time_step_window):
            spikes.append(SPIKE_A if a else NO_SPIKE)
            spikes.append(SPIKE_B if b_val else NO_SPIKE)
    return spikes

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = os.path.join(script_dir, '..', 'inference_accelarator', 'neuron_accelerator')
    
    print("=" * 60)
    print("XOR Test Data Generator (v4 - with spike forwarder init)")
    print("=" * 60)
    
    data_bytes = generate_xor_data()
    data_mem_path = os.path.join(output_dir, 'data_mem.mem')
    with open(data_mem_path, 'w') as f:
        for b in data_bytes:
            f.write(f"{b:02X}\n")
        f.write("xx\n")
    print(f"✓ data_mem.mem: {len(data_bytes)} bytes")
    
    spike_packets = generate_spike_mem()
    spike_mem_path = os.path.join(output_dir, 'spike_mem.mem')
    with open(spike_mem_path, 'w') as f:
        for p in spike_packets:
            f.write(f"{p:03X}\n")
    print(f"✓ spike_mem.mem: {len(spike_packets)} packets")
    
    print("\nSpike Forwarder Tables:")
    print("  SF8[0] main→group0: 0b000000010")
    print("  SF8[1] group0→main: 0b000000001")
    print("  SF4[0] main→cl0+cl1: 0b00110")
    print("  SF4[1] cl0→main+cl1: 0b00101")
    print("  SF4[2] cl1→main:     0b00001")
    print("\nNeurons: H0(VT=3), H1(VT=8), Out(VT=10)")
    print("Weights: A/B→H0/H1:+5, H0→Out:+20, H1→Out:-20")
    print("\nExpected: [0,0]→0  [0,1]→1  [1,0]→1  [1,1]→0")

if __name__ == "__main__":
    main()
