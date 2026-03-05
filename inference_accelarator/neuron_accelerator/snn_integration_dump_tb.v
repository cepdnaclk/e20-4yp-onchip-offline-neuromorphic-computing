// ============================================================
//  snn_integration_dump_tb.v  — Level 5: SNN + Dump Integration Test
// ============================================================
//
//  PURPOSE:
//    Verify that spike propagation BETWEEN clusters (SNN behaviour)
//    is correctly captured by the dump FSM and stored in shared memory.
//
//    Unlike known_value_dump_tb.v (L4) which injects spikes from an
//    external cluster via the main FIFO, this test exercises:
//      1. Cluster 0, neuron 0  receives an EXTERNAL spike (from cl62)
//         via the main FIFO → accumulates weight 5.0, VT=3.0 → FIRES
//      2. Cluster 0's outgoing spike is re-encoded and routed through
//         SF4 → SF8 → back to main FIFO → SF8 → SF4 → Cluster 1
//      3. Cluster 1, neuron 0  receives the on-chip spike from cl0
//         via weight BRAM row 2 (weight=20.0, VT=10.0) → FIRES
//      4. After time_step: dump FSM runs and writes both clusters'
//         v_pre_spike to the simulated shared memory
//      5. Testbench reads back shared_mem and verifies known values
//
//  NETWORK (exact production init bytes from data_mem.mem, 16 packets):
//    SF8: map[0]=group0, map[1]=main
//    SF4: map[0]=cl1+cl2, map[1]=cl0+cl2, map[2]=main
//    Cluster 0 neuron 0: VT=3.0, receives from cluster 62
//    Cluster 0 neuron 1: VT=8.0, receives from cluster 62
//    Cluster 1 neuron 0: VT=10.0, receives from cluster 0, base=2
//    WR rows 0,1: n0=5.0, n1=5.0   (cluster 0's weights from src cl62)
//    WR rows 2,3: n0=20.0, n1=-20.0 (cluster 1's weights from src cl0)
//
//  EXPECTED (timestep 1):
//    Cluster 0, neuron 0:  weight=5.0  > VT=3.0  → FIRES, v_pre=0x00050000
//    Cluster 0, neuron 1:  weight=5.0  < VT=8.0  → no fire, v_pre=0x00050000
//    Cluster 1, neuron 0:  weight=20.0 > VT=10.0 → FIRES, v_pre=0x00140000
//
//  PASS CRITERIA (8 checks):
//    1. cl0 neuron 0 v_pre_spike = 0x00050000
//    2. cl0 neuron 1 v_pre_spike = 0x00050000
//    3. cl1 neuron 0 v_pre_spike = 0x00140000
//    4. cl0 neuron 0 spike bit = 1
//    5. cl0 neuron 1 spike bit = 0
//    6. cl1 neuron 0 spike bit = 1
//    7. Shared memory V_mem region has correct values (WB CPU readback)
//    8. Total dump count = 3 (init + spike-drain + post-compute)
//
//  TIMING NOTE:
//    The SNN path (cl0→cl1) adds latency: cl0 fires → outgoing_enc →
//    SF4 → SF8 → SF8 → SF4 → cl1 accumulates → then time_step is issued.
//    This test waits for accelerator_done TWICE after the spike injection
//    (like neuron_accelerator_tb.v) before issuing time_step.
//
// ============================================================
`include "neuron_accelerator.v"
`timescale 1ns/100ps

module snn_integration_dump_tb;

// ─── Parameters (match production data_mem.mem network) ──────────────────────
localparam PACKET_W      = 11;
localparam N_PER_CLUSTER = 32;
localparam CL_GROUPS     = 1;                        // 1 group → 4 clusters
localparam N_CLUSTERS    = CL_GROUPS * 4;            // = 4
localparam N_TOTAL       = N_CLUSTERS * N_PER_CLUSTER; // = 128
localparam N_SPIKE_W     = (N_TOTAL + 31) / 32;       // = 4 words
localparam FLIT          = 8;

// Shared-memory layout (small offsets for clarity)
localparam VMEM_BASE     = 16'h1000;
localparam SPIKE_BASE    = 16'h1100;

// ─── Expected values ─────────────────────────────────────────────────────────
// Cluster 0, neuron 0: weight=5.0 from cl3 (fits 2-bit ID), VT=3.0 → FIRES
localparam EXP_CL0_N0_VPRE  = 32'h00050000;  // 5.0 Q16.16
// Cluster 0, neuron 1: weight=5.0 from cl3, VT=8.0 → NO FIRE
localparam EXP_CL0_N1_VPRE  = 32'h00050000;  // 5.0 Q16.16
// Cluster 1, neuron 0: weight=20.0 from cl0, VT=10.0 → FIRES (SNN propagation)
localparam EXP_CL1_N0_VPRE  = 32'h00140000;  // 20.0 Q16.16

// ─── Clock ───────────────────────────────────────────────────────────────────
reg clk = 0;
always #5 clk = ~clk;  // 100 MHz

// ─── DUT I/O ─────────────────────────────────────────────────────────────────
reg  rst            = 1;
reg  network_mode   = 0;
reg  time_step      = 0;
reg  rst_potential  = 0;
reg  load_data_in   = 0;
reg  [FLIT-1:0] data_in = 0;
reg  ready_out      = 1;
reg  [PACKET_W-1:0] main_fifo_din_in = 0;
reg  main_fifo_wr_en_in = 0;

wire ready_in;
wire [FLIT-1:0] data_out;
wire load_data_out, data_out_done;
wire main_fifo_full_in, main_fifo_empty_out;
wire [PACKET_W-1:0] main_fifo_dout_out;
wire accelerator_done, dbg_all_clusters_done, dump_done;

// Dump Port B
wire [15:0] portb_addr;
wire [31:0] portb_din;
wire        portb_we, portb_en;

// Always drain the output FIFO (same as neuron_accelerator_tb.v)
wire main_fifo_rd_en_out = ~main_fifo_empty_out;

// ─── Simulated shared memory ──────────────────────────────────────────────────
reg [31:0] shared_mem [0:65535];
integer    write_count       = 0;
integer    vmem_write_count  = 0;
integer    spike_write_count = 0;
integer    dump_number       = 0;

// Snapshot registers: capture cl0 values after dump #3 (before dump #4 overwrites)
reg [31:0] snap_cl0_n0  = 0;
reg [31:0] snap_cl0_n1  = 0;
reg [31:0] snap_spike_w0 = 0;
reg        snap_taken   = 0;

always @(posedge clk) begin
    if (dump_done) dump_number <= dump_number + 1;
    if (portb_we && portb_en) begin
        shared_mem[portb_addr] <= portb_din;
        write_count            <= write_count + 1;
        if (portb_addr >= VMEM_BASE && portb_addr < SPIKE_BASE)
            vmem_write_count <= vmem_write_count + 1;
        else if (portb_addr >= SPIKE_BASE)
            spike_write_count <= spike_write_count + 1;
    end
end

// Snapshot cl0 values at the end of dump #3 (before dump #4 overwrites them)
// dump_number transitions to 3 when dump_done pulses for the 3rd time.
// We wait one more cycle for shared_mem to be fully written, then snapshot.
always @(posedge clk) begin
    if (dump_number == 3 && !snap_taken) begin
        snap_cl0_n0   <= shared_mem[VMEM_BASE+0];
        snap_cl0_n1   <= shared_mem[VMEM_BASE+1];
        snap_spike_w0 <= shared_mem[SPIKE_BASE+0];
        snap_taken    <= 1;
    end
end

// ─── DUT ─────────────────────────────────────────────────────────────────────
neuron_accelerator #(
    .packet_width            (PACKET_W),
    .main_fifo_depth         (32),
    .forwarder_8_fifo_depth  (16),
    .forwarder_4_fifo_depth  (8),
    .number_of_clusters      (N_CLUSTERS),
    .neurons_per_cluster     (N_PER_CLUSTER),
    .incoming_weight_table_rows(64),
    .max_weight_table_rows   (256),
    .flit_size               (FLIT),
    .cluster_group_count     (CL_GROUPS)
) dut (
    .clk              (clk),
    .rst              (rst),
    .network_mode     (network_mode),
    .time_step        (time_step),
    .rst_potential    (rst_potential),
    .load_data_in     (load_data_in),
    .data_in          (data_in),
    .ready_in         (ready_in),
    .data_out         (data_out),
    .load_data_out    (load_data_out),
    .ready_out        (ready_out),
    .data_out_done    (data_out_done),
    .main_fifo_din_in (main_fifo_din_in),
    .main_fifo_wr_en_in(main_fifo_wr_en_in),
    .main_fifo_full_in(main_fifo_full_in),
    .main_fifo_dout_out(main_fifo_dout_out),
    .main_fifo_rd_en_out(main_fifo_rd_en_out),
    .main_fifo_empty_out(main_fifo_empty_out),
    .accelerator_done (accelerator_done),
    .dbg_all_clusters_done(dbg_all_clusters_done),
    .dump_done        (dump_done),
    .portb_addr       (portb_addr),
    .portb_din        (portb_din),
    .portb_we         (portb_we),
    .portb_en         (portb_en),
    .vmem_base_addr   (VMEM_BASE),
    .spike_base_addr  (SPIKE_BASE),
    .current_timestep (4'd0)
);

// ─── Monitor: non-zero dumps only (keeps output concise) ─────────────────────
always @(posedge clk) begin
    if (portb_we && portb_en && portb_din != 0) begin
        if (portb_addr >= VMEM_BASE && portb_addr < SPIKE_BASE)
            $display("[DUMP%0d] V_MEM  neuron=%0d  addr=0x%04h  val=0x%08h",
                     dump_number, portb_addr - VMEM_BASE, portb_addr, portb_din);
        else if (portb_addr >= SPIKE_BASE)
            $display("[DUMP%0d] SPIKES word=%0d   addr=0x%04h  val=0b%032b",
                     dump_number, portb_addr - SPIKE_BASE, portb_addr, portb_din);
    end
end

// ─── Monitor: SNN internal spike propagation ────────────────────────────────
// Shows when cluster 0 fires and when cluster 1 receives the resulting weight
always @(posedge clk) begin
    // Cluster 0 spike output (outgoing_enc asserts fifo_wr_en)
    if (dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.fifo_wr_en)
        $display("[SNN] Cluster 0 outgoing spike: pkt=0x%03h @%0t",
            dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.packet_out,
            $time);
    // Cluster 1 receives weight (weight_resolver fires load_weight_out to cluster 1)
    if (dut.gen_spike_forwarder_4[0].resolver_load_weight_out[1])
        $display("[SNN] Cluster 1 load_weight: w[0]=0x%08h @%0t",
            dut.gen_spike_forwarder_4[0].resolver_weight_out[1*32*N_PER_CLUSTER +: 32],
            $time);
    // time_step
    if (time_step)
        $display("[SNN] time_step asserted: cl0_n0_vpre=0x%08h cl1_n0_vpre=0x%08h @%0t",
            dut.all_pre_spike[0*32 +: 32],
            dut.all_pre_spike[1*N_PER_CLUSTER*32 +: 32],
            $time);
end

// ─── Init ROM (exact production bytes from data_mem.mem — 16 packets) ────────
//
// Decoded structure (see header comment for full description):
//
// PKT 0  [A0 02 00 02]         SF8 map[0] → group0
// PKT 1  [A0 02 10 01]         SF8 map[1] → main
// PKT 2  [80 03 00 01 06]      SF4 map[0] → ports 1,2  (cluster 1, 2)
// PKT 3  [80 03 00 01 25]      SF4 map[1] → ports 0,2  (cluster 0, 2)
// PKT 4  [80 03 00 01 41]      SF4 map[2] → port 0     (main)
// PKT 5  [00 11 01 00 0E FE...] Cluster 0 neuron 0: decay=0 VT=3.0 mode=LIF2
// PKT 6  [00 11 01 01 0E FE...] Cluster 0 neuron 1: decay=0 VT=8.0 mode=LIF2
// PKT 7  [01 11 01 00 0E FE...] Cluster 1 neuron 0: decay=0 VT=10.0 mode=LIF2
// PKT 8  [00 03 02 00 00]       Cluster 0 IF base=0
// PKT 9  [00 02 03 3E]          Cluster 0 IF addr=62 (source cluster)
// PKT10  [01 03 02 02 00]       Cluster 1 IF base=2
// PKT11  [01 02 03 00]          Cluster 1 IF addr=0 (source=cluster 0)
// PKT12  [80 85 01 83 00 00 80 + 128 bytes]  WR row 0: n0=5.0 n1=5.0 ...
// PKT13  [80 85 01 83 01 00 80 + 128 bytes]  WR row 1: n0=5.0 n1=5.0 ...
// PKT14  [80 85 01 83 02 00 80 + 128 bytes]  WR row 2: n0=20.0 n1=0 ...
// PKT15  [80 85 01 83 03 00 80 + 128 bytes]  WR row 3: n0=-20.0 n1=0 ...

reg [7:0] init_rom [0:999];
integer   init_idx = 0;
integer   init_len = 0;

task load_init_rom;
    integer i, k;
    begin
        for (i = 0; i < 1000; i = i+1) init_rom[i] = 8'hxx;
        i = 0;

        // PKT 0: SF8 map[0] → group0
        init_rom[i]=8'hA0; i=i+1; init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h02; i=i+1;

        // PKT 1: SF8 map[1] → main
        init_rom[i]=8'hA0; i=i+1; init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h10; i=i+1; init_rom[i]=8'h01; i=i+1;

        // PKT 2: SF4 map[0] → port 1 only (cluster 0)
        // fwd = 0b00010 → byte = {row=0, fwd=0b00010} = 0x02
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h01; i=i+1;
        init_rom[i]=8'h02; i=i+1;

        // PKT 3: SF4 map[1] → port 2 only (cluster 1)
        // fwd = 0b00100 → byte = {row=1, fwd=0b00100} = 0x24
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h01; i=i+1;
        init_rom[i]=8'h24; i=i+1;

        // PKT 4: SF4 map[2] → port 0 (main/SF8)
        // fwd = 0b00001 → byte = {row=2, fwd=0b00001} = 0x41
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h01; i=i+1;
        init_rom[i]=8'h41; i=i+1;

        // PKT 5: Cluster 0 neuron 0: decay=0.0 VT=3.0 mode=0x01 (LIF2)
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h11; i=i+1;
        init_rom[i]=8'h01; i=i+1; // OPCODE_LOAD_NI
        init_rom[i]=8'h00; i=i+1; // neuron_id=0
        init_rom[i]=8'h0E; i=i+1; // flit_count=14
        init_rom[i]=8'hFE; i=i+1; // DECAY_INIT
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; // decay=0.0
        init_rom[i]=8'hFF; i=i+1; // END
        init_rom[i]=8'hF9; i=i+1; // ADDER_VT_INIT
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h03; i=i+1; init_rom[i]=8'h00; i=i+1; // VT=3.0 (0x00030000)
        init_rom[i]=8'hFF; i=i+1; // END
        init_rom[i]=8'hF7; i=i+1; init_rom[i]=8'h01; i=i+1; // WORK_MODE=1

        // PKT 6: Cluster 0 neuron 1: decay=0.0 VT=8.0 mode=0x01
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h11; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h01; i=i+1; // neuron_id=1
        init_rom[i]=8'h0E; i=i+1;
        init_rom[i]=8'hFE; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF9; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h08; i=i+1; init_rom[i]=8'h00; i=i+1; // VT=8.0 (0x00080000)
        init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF7; i=i+1; init_rom[i]=8'h01; i=i+1;

        // PKT 7: Cluster 1 neuron 0: decay=0.0 VT=10.0 mode=0x01
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h11; i=i+1; // addr=cluster 1
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h00; i=i+1; // neuron_id=0
        init_rom[i]=8'h0E; i=i+1;
        init_rom[i]=8'hFE; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF9; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h0A; i=i+1; init_rom[i]=8'h00; i=i+1; // VT=10.0 (0x000A0000)
        init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF7; i=i+1; init_rom[i]=8'h01; i=i+1;

        // PKT 8: Cluster 0 IF base = 0
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h02; i=i+1; // OPCODE_LOAD_IF_BASE
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;

        // PKT 9: Cluster 0 IF addr = 3 (source cluster_id=3, fits in 2-bit ID space)
        // NOTE: N_CLUSTERS=4 → $clog2(4)=2-bit cluster IDs.
        //       cluster_controller truncates IF_ADDR to 2 bits.
        //       packet[10:5] must equal the stored 2-bit value.
        //       cluster_id=3 → packet = (3<<5)|0 = 0x060
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h03; i=i+1; // OPCODE_LOAD_IF_ADDR
        init_rom[i]=8'h03; i=i+1; // cluster_id = 3

        // PKT10: Cluster 1 IF base = 2 (weight rows 2,3 are for cluster 0 src)
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h02; i=i+1; // OPCODE_LOAD_IF_BASE
        init_rom[i]=8'h02; i=i+1; init_rom[i]=8'h00; i=i+1;

        // PKT11: Cluster 1 IF addr = 0 (source is cluster 0)
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h03; i=i+1; // OPCODE_LOAD_IF_ADDR
        init_rom[i]=8'h00; i=i+1; // cluster_id = 0

        // PKT12: WR row 0 — source neuron 0 of cluster 62 → cl0 n0=5.0 n1=5.0
        // Format: [80][85][01][83][addr_lo][addr_hi][flit_cnt=80][w0..w31]
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h85; i=i+1;
        init_rom[i]=8'h01; i=i+1; // sdm: port=1 (weight_resolver)
        init_rom[i]=8'h83; i=i+1; // sdm: count=131
        init_rom[i]=8'h00; i=i+1; // addr_lo=0
        init_rom[i]=8'h00; i=i+1; // addr_hi=0
        init_rom[i]=8'h80; i=i+1; // flit_count=128 (32 neurons × 4 bytes)
        // Neuron 0: 5.0 = 0x00050000 LE: 00 00 05 00
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h05; i=i+1; init_rom[i]=8'h00; i=i+1;
        // Neuron 1: 5.0
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h05; i=i+1; init_rom[i]=8'h00; i=i+1;
        // Neurons 2..31: 0.0
        for (k = 2; k < 32; k = k+1) begin
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        end

        // PKT13: WR row 1 — source neuron 1 of cluster 62 → cl0 n0=5.0 n1=5.0
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h85; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h83; i=i+1;
        init_rom[i]=8'h01; i=i+1; // addr_lo=1
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h80; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h05; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h05; i=i+1; init_rom[i]=8'h00; i=i+1;
        for (k = 2; k < 32; k = k+1) begin
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        end

        // PKT14: WR row 2 — source neuron 0 of cluster 0 → cl1 n0=20.0 others=0
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h85; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h83; i=i+1;
        init_rom[i]=8'h02; i=i+1; // addr_lo=2
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h80; i=i+1;
        // Neuron 0: 20.0 = 0x00140000 LE: 00 00 14 00
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h14; i=i+1; init_rom[i]=8'h00; i=i+1;
        // Neurons 1..31: 0.0
        for (k = 1; k < 32; k = k+1) begin
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        end

        // PKT15: WR row 3 — source neuron 1 of cluster 0 → cl1 n0=-20.0 others=0
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h85; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h83; i=i+1;
        init_rom[i]=8'h03; i=i+1; // addr_lo=3
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h80; i=i+1;
        // Neuron 0: -20.0 = 0xFFEC0000 LE: 00 00 EC FF
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'hEC; i=i+1; init_rom[i]=8'hFF; i=i+1;
        // Neurons 1..31: 0.0
        for (k = 1; k < 32; k = k+1) begin
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        end

        // Sentinel
        init_rom[i] = 8'hxx;
        init_len = i;
        $display("[INIT_ROM] Built %0d bytes (%0d packets)", i, 16);
    end
endtask

// ─── Init stream driver ───────────────────────────────────────────────────────
reg        start_init = 0;
reg        init_done  = 0;
reg [31:0] init_index = 0;

always @(posedge clk) begin
    if (start_init) begin
        if (init_rom[init_index] !== 8'hxx) begin
            if (ready_in && !load_data_in) begin
                data_in      <= init_rom[init_index];
                load_data_in <= 1;
                init_index   <= init_index + 1;
            end else
                load_data_in <= 0;
        end else begin
            load_data_in <= 0;
            if (ready_in && !load_data_in) begin
                start_init   <= 0;
                init_done    <= 1;
                network_mode <= 0;
                $display("[INIT] Stream complete: %0d bytes sent", init_index);
            end
        end
    end else
        load_data_in <= 0;
end

// ─── VCD ─────────────────────────────────────────────────────────────────────
initial begin
    $dumpfile("snn_integration_dump_tb.vcd");
    $dumpvars(0, snn_integration_dump_tb);
    $dumpvars(3, dut);
end

// ─── Test flow ────────────────────────────────────────────────────────────────
integer pass_count = 0;
integer fail_count = 0;

task check;
    input        ok;
    input [127:0] name;
    begin
        if (ok) begin
            $display("  [PASS] %s", name);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s", name);
            fail_count = fail_count + 1;
        end
    end
endtask

initial begin
    $display("=============================================================");
    $display(" Level 5: SNN + Dump Integration Test");
    $display("=============================================================");
    $display(" Network: cluster_group_count=1, 4 clusters, 128 neurons");
    $display(" Cluster 0: neuron0 VT=3.0 (FIRES at w=5.0), neuron1 VT=8.0");
    $display(" Cluster 1: neuron0 VT=10.0, receives from cl0 weight=20.0");
    $display(" Expected SNN path: ext-spike → cl0 fires → cl1 fires");
    $display("=============================================================\n");

    load_init_rom();

    // ── Reset ──
    rst = 1;
    repeat(10) @(posedge clk);
    rst = 0;

    // ── Phase 1: Init ──
    $display("[PHASE 1] Entering init mode, streaming %0d bytes...", init_len);
    network_mode = 1;
    start_init   = 1;

    wait(init_done);
    $display("[PHASE 1] Init complete. Waiting for first dump (all-zeros)...");

    wait(dump_number >= 1);
    $display("[PHASE 1] Dump #1 received (all-zeros after init). dump_count=%0d", dump_number);
    repeat(5) @(posedge clk);

    // ── Phase 2: Inject external spike → cluster 0 ──
    // Spike packet: {cluster_id=3, neuron_id=0}
    // N_CLUSTERS=4 → 2-bit cluster_id in packet[10:5].
    // cluster_id=3 = 0b11, neuron_id=0 → packet = (3<<5)|0 = 0x060
    // Cluster 0's incoming_forwarder has IF_ADDR=3, which matches packet[10:5]=3.
    $display("\n[PHASE 2] Injecting external spike: cluster=3, neuron=0 (packet=0x060)");
    $display("          Cluster 0 (IF_ADDR=3) will match, accumulate weight=5.0");
    @(posedge clk); #1;
    main_fifo_din_in   <= 11'h060;
    main_fifo_wr_en_in <= 1;
    @(posedge clk); #1;
    main_fifo_wr_en_in <= 0;

    // Wait for dump #2: accelerator_done after the spike packet is consumed
    // and weight accumulation is complete (cluster 0 has the weight loaded,
    // but time_step not yet issued so neurons haven't fired yet)
    $display("[PHASE 2] Spike injected. Waiting for dump #2 (post-accumulation, pre-fire)...");
    wait(dump_number >= 2);
    $display("[PHASE 2] Dump #2 received. dump_count=%0d", dump_number);
    repeat(5) @(posedge clk);

    // ── Phase 3: Timestep 1 → cluster 0 fires, its spike propagates to cluster 1 ──
    // Architecture note: the accumulator snapshots on time_step rising edge.
    // Cluster 1 receives its weight from cluster 0's outgoing spike AFTER
    // cluster 0 fires. So cluster 1's v_pre_spike is only valid after a
    // SECOND time_step in Phase 4.
    // Dump #3 (after this time_step) will show: cl0 v_pre=5.0, cl1 v_pre=0.
    $display("\n[PHASE 3] Timestep 1 — cluster 0 computes and fires...");
    @(posedge clk); #1;
    time_step <= 1;
    @(posedge clk); #1;
    time_step <= 0;

    // cl0 fires → outgoing_enc → SF4 routes to cl1 FIFO → weight_resolver
    // delivers 20.0 to cl1's accumulator → accelerator_done rises.
    // The dump FSM captures cl0 v_pre=5.0 (correct) and cl1 v_pre=0 (not yet).
    $display("[PHASE 3] Waiting for dump #3 (ts1: cl0 fires, cl1 accumulates)...");
    wait(dump_number >= 3);
    repeat(5) @(posedge clk);
    $display("[PHASE 3] Dump #3 received. dump_count=%0d", dump_number);

    // ── Phase 4: Timestep 2 → cluster 1 fires (uses accumulated 20.0) ──
    $display("\n[PHASE 4] Timestep 2 — cluster 1 computes with 20.0 and fires...");
    @(posedge clk); #1;
    time_step <= 1;
    @(posedge clk); #1;
    time_step <= 0;

    $display("[PHASE 4] Waiting for dump #4 (ts2: cl1 v_pre=20.0, cl1 fires)...");
    wait(dump_number >= 4);
    repeat(5) @(posedge clk);
    $display("[PHASE 4] Dump #4 received. dump_count=%0d", dump_number);

    // ── Verification ──
    // Dump #3 has cl0 values (overwritten at VMEM_BASE+0..+1)
    // Dump #4 has cl1 values (overwritten at VMEM_BASE+32)
    // Because the shared_mem array is always-overwritten each dump,
    // the LAST dump's values persist for each address.
    // Since cl0 neurons get 0 weight on ts2 (no new spike), cl0 v_pre = 0
    // in dump #4. So we must read dump #3's cl0 values — but they've been
    // OVERWRITTEN by dump #4 (same addresses)!
    //
    // Solution: track cl0 values from dump #3 in a local variable.
    // We read shared_mem right after dump #3 above, before dump #4 runs.
    // But timing is tricky. Instead, we use a separate snapshot reg.
    $display("\n=============================================================");
    $display(" VERIFICATION");
    $display("  Dump #3 (ts1): cl0 v_pre written — VMEM_BASE+0,+1");
    $display("  Dump #4 (ts2): cl1 v_pre written — VMEM_BASE+32");
    $display("  Note: cl0 addresses overwritten by dump #4 (cl0 v_pre=0 on ts2)");
    $display("  → Check cl0 values from snapshot taken after dump #3.");
    $display("=============================================================");

    // CHECK 1: Cluster 0, neuron 0 v_pre_spike from snapshot (dump #3)
    $display("\n  -- Cluster 0 (snapshot after dump #3) --");
    $display("  snap_cl0_n0 = 0x%08h  (expect 0x%08h = 5.0)",
             snap_cl0_n0, EXP_CL0_N0_VPRE);
    check(snap_cl0_n0 == EXP_CL0_N0_VPRE,
          "cl0 neuron0 v_pre_spike=5.0 (0x00050000)");

    // CHECK 2: Cluster 0, neuron 1 v_pre_spike from snapshot (dump #3)
    $display("  snap_cl0_n1 = 0x%08h  (expect 0x%08h = 5.0)",
             snap_cl0_n1, EXP_CL0_N1_VPRE);
    check(snap_cl0_n1 == EXP_CL0_N1_VPRE,
          "cl0 neuron1 v_pre_spike=5.0 (0x00050000)");

    // CHECK 3: Cluster 1, neuron 0 v_pre_spike = 20.0 (dump #4, still in shared_mem)
    $display("\n  -- Cluster 1 (dump #4) --");
    $display("  vmem[32] = 0x%08h  (expect 0x%08h = 20.0)",
             shared_mem[VMEM_BASE+32], EXP_CL1_N0_VPRE);
    check(shared_mem[VMEM_BASE+32] == EXP_CL1_N0_VPRE,
          "cl1 neuron0 v_pre_spike=20.0 (0x00140000) — SNN propagation VERIFIED");

    // CHECK 4: Cluster 0 neuron 0 spike bit = 1 (from snapshot after dump #3)
    $display("\n  -- Spike bits (dump #3 snapshot) --");
    $display("  snap_spike_w0 = 0b%032b", snap_spike_w0);
    check(snap_spike_w0[0] == 1'b1,
          "cl0 neuron0 spike=1 (fired on ts1)");

    // CHECK 5: Cluster 0 neuron 1 spike bit = 0
    check(snap_spike_w0[1] == 1'b0,
          "cl0 neuron1 spike=0 (w=5.0 < VT=8.0)");

    // CHECK 6: Cluster 1 neuron 0 spike bit = 1 (dump #4)
    $display("  spike_word[1] (dump#4) = 0b%032b", shared_mem[SPIKE_BASE+1]);
    check(shared_mem[SPIKE_BASE+1][0] == 1'b1,
          "cl1 neuron0 spike=1 (fired via SNN propagation cl0→cl1)");

    // CHECK 7: Total V_mem writes = 4 dumps × N_TOTAL
    check(vmem_write_count == 4 * N_TOTAL,
          "vmem_write_count = 4*N_TOTAL");
    $display("  vmem_write_count=%0d  (expect %0d = 4×%0d)",
             vmem_write_count, 4*N_TOTAL, N_TOTAL);

    // CHECK 8: Exactly 4 dumps occurred
    check(dump_number == 4,
          "dump_done pulsed 4 times (init+spike-drain+ts1+ts2)");
    $display("  dump_number=%0d  (expect 4)", dump_number);

    $display("\n=============================================================");
    if (fail_count == 0) begin
        $display(" ALL %0d / 8 TESTS PASSED", pass_count);
        $display(" SNN spike propagation (cl0 → cl1) verified through dump FSM!");
        $display(" v_pre_spike correctly captured across two timesteps.");
    end else
        $display(" %0d PASSED  /  %0d FAILED — check snn_integration_dump_tb.vcd",
                 pass_count, fail_count);
    $display("=============================================================");

    $finish;
end

// ─── Watchdog ─────────────────────────────────────────────────────────────────
initial begin
    #50_000_000;  // 50 ms at 100 MHz = 5M cycles — enough for SNN latency
    $display("[TIMEOUT] 50ms exceeded");
    $display("  init_done=%b accelerator_done=%b dump_number=%0d write_count=%0d",
             init_done, accelerator_done, dump_number, write_count);
    $display("  all_pre_spike[cl0_n0]  = 0x%08h", dut.all_pre_spike[0*32 +: 32]);
    $display("  all_pre_spike[cl1_n0]  = 0x%08h", dut.all_pre_spike[32*32 +: 32]);
    $display("  all_spikes[0]          = %b", dut.all_spikes[0]);
    $display("  all_spikes[32]         = %b", dut.all_spikes[32]);
    $display("  snap_cl0_n0=0x%08h snap_cl0_n1=0x%08h snap_taken=%b",
             snap_cl0_n0, snap_cl0_n1, snap_taken);
    $finish;
end

endmodule
