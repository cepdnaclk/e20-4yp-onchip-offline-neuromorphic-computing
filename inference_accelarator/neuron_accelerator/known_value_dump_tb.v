// ============================================================
// known_value_dump_tb.v  — Level 4 Self-Contained Dump Test
// ============================================================
//
// PURPOSE:
//   Same spirit as neuron_cluster_tb.v (L2, passes 8/8),
//   but runs through the FULL accelerator pipeline:
//     init_router → weight_resolver → spike_forwarder → cluster → dump FSM
//
//   All init bytes are EMBEDDED in this file — no data_mem.mem needed.
//   Expected outputs are KNOWN in advance so every failure is traceable.
//
// NETWORK (matches neuron_cluster_tb.v values exactly):
//   - Only group 0 (clusters 0..3) used; cluster_group_count=1
//   - Cluster 0, Neuron 0: weight=5.0 Q16.16 (0x00050000), VT=3.0 → FIRES
//   - Cluster 0, Neuron 1: weight=2.0 Q16.16 (0x00020000), VT=3.0 → NO FIRE
//   - Input spike: cluster 3, neuron 0 (packet 0x060)
//   - NOTE: cluster_id=3 is used as the "source" because number_of_clusters=4
//     gives $clog2(4)=2-bit cluster ID width. Cluster 62 would need 6 bits.
//
// EXPECTED DUMP (after timestep):
//   Neuron 0 (cluster 0, index 0):  v_pre_spike = 0x00050000 (5.0)  spike=1
//   Neuron 1 (cluster 0, index 1):  v_pre_spike = 0x00020000 (2.0)  spike=0
//   Neurons 2..31:                  v_pre_spike = 0x00000000         spike=0
//
// DOUBLE-DUMP FIX:
//   The dump FSM triggers on the rising edge of accelerator_done.
//   It fires TWICE: once after init (all zeros), once after inference.
//   This testbench detects the second dump and checks that one.
//
// GTKWave:
//   Open known_value_dump_tb.vcd in GTKWave.
//   Key signals to trace (all in one group):
//     clk, rst, time_step, accelerator_done, dump_done
//     portb_we, portb_addr, portb_din
//     all_pre_spike[31:0]  (neuron 0 of cluster 0 — should be 0x00050000)
//     all_spikes[0]        (neuron 0 spike bit — should go high)
//     dump_state           (FSM: 0=IDLE 1=VMEM 2=SPIKES 3=DONE)
//     dump_idx             (counter 0..1023 for vmem, 0..31 for spikes)
//
// ============================================================
`include "neuron_accelerator.v"
`timescale 1ns/100ps

module known_value_dump_tb;

// ─── Parameters ──────────────────────────────────────────────────────────────
localparam PACKET_W      = 11;
localparam N_PER_CLUSTER = 32;
localparam CL_GROUPS     = 1;          // ONLY 1 group → 4 clusters total
localparam N_CLUSTERS    = CL_GROUPS * 4;  // = 4
localparam N_TOTAL       = N_CLUSTERS * N_PER_CLUSTER; // = 128
localparam N_SPIKE_W     = (N_TOTAL + 31) / 32;        // = 4 words
localparam FLIT          = 8;
localparam VMEM_BASE     = 16'h1000;   // small address range for clarity
localparam SPIKE_BASE    = 16'h1100;

// Expected values for easy checking
localparam EXP_N0_VPRE   = 32'h00050000; // 5.0 Q16.16
localparam EXP_N1_VPRE   = 32'h00020000; // 2.0 Q16.16
localparam EXP_N0_SPIKE  = 1'b1;
localparam EXP_N1_SPIKE  = 1'b0;

// ─── Clock & Reset ────────────────────────────────────────────────────────────
reg clk = 0, rst = 1;
always #5 clk = ~clk;  // 100 MHz

// ─── Accelerator I/O ─────────────────────────────────────────────────────────
reg  network_mode       = 0;
reg  time_step          = 0;
reg  rst_potential      = 0;
reg  load_data_in       = 0;
reg  [FLIT-1:0] data_in = 0;
wire ready_in;
wire [FLIT-1:0] data_out;
wire load_data_out;
reg  ready_out          = 1;
reg  [PACKET_W-1:0] main_fifo_din_in = 0;
reg  main_fifo_wr_en_in = 0;
wire main_fifo_full_in;
wire [PACKET_W-1:0] main_fifo_dout_out;
wire main_fifo_empty_out;
wire accelerator_done;
wire dbg_all_clusters_done;
wire dump_done;
wire data_out_done;
// Always drain the output FIFO so fired spikes don't block accelerator_done
// (same as the reference neuron_accelerator_tb.v: assign rd_en = ~empty)
wire main_fifo_rd_en_out = ~main_fifo_empty_out;

// ─── Port B (dump to shared memory) ──────────────────────────────────────────
wire [15:0] portb_addr;
wire [31:0] portb_din;
wire        portb_we;
wire        portb_en;

// ─── Local shared memory capture ─────────────────────────────────────────────
reg [31:0] shared_mem [0:65535];
integer    write_count      = 0;
integer    vmem_write_count = 0;
integer    spike_write_count= 0;
integer    dump_number      = 0; // count how many complete dumps happen

// Track dump number so we can check the SECOND one (post-inference)
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

// ─── DUT ──────────────────────────────────────────────────────────────────────
neuron_accelerator #(
    .packet_width       (PACKET_W),
    .main_fifo_depth    (32),
    .forwarder_8_fifo_depth(16),
    .forwarder_4_fifo_depth(8),
    .number_of_clusters (N_CLUSTERS),
    .neurons_per_cluster(N_PER_CLUSTER),
    .incoming_weight_table_rows(64),
    .max_weight_table_rows     (256),
    .flit_size          (FLIT),
    .cluster_group_count(CL_GROUPS)
) dut (
    .clk(clk), .rst(rst),
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

// ─── Diagnostic monitors ─────────────────────────────────────────────────────

// INIT CHECK: SF8 and SF4 map writes
always @(posedge clk) begin
    if (dut.spike_forwarder.spike_forwarder_controller_inst.load_row)
        $display("[INIT] SF8  map[%0d] = 0b%09b @%0t",
                 dut.spike_forwarder.spike_forwarder_controller_inst.row_index,
                 dut.spike_forwarder.spike_forwarder_controller_inst.forwarding_row, $time);
    if (dut.gen_spike_forwarder_4[0].spike_forwarder_4_inst.spike_forwarder_controller_inst.load_row)
        $display("[INIT] SF4[0] map[%0d] = 0b%05b @%0t",
                 dut.gen_spike_forwarder_4[0].spike_forwarder_4_inst.spike_forwarder_controller_inst.row_index,
                 dut.gen_spike_forwarder_4[0].spike_forwarder_4_inst.spike_forwarder_controller_inst.forwarding_row, $time);
end

// INIT CHECK: incoming_forwarder cluster_id table
always @(posedge clk) begin
    if (dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.if_load_cluster_index)
        $display("[INIT] Cluster0 IF load_cluster_index: cl_id=%0d @%0t",
                 dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.if_cluster_id, $time);
    if (dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.if_load_addr_in)
        $display("[INIT] Cluster0 IF load_addr_in: base=%0d @%0t",
                 dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.if_base_weight_addr_init, $time);
end

// INIT CHECK: weight_resolver state changes
always @(posedge clk) begin
    if (dut.gen_spike_forwarder_4[0].weight_resolver_inst.load_data)
        $display("[INIT] WR load_data: byte=0x%02h state=%0d flit_cnt=%0d ctr=%0d @%0t",
                 dut.gen_spike_forwarder_4[0].weight_resolver_inst.data,
                 dut.gen_spike_forwarder_4[0].weight_resolver_inst.state,
                 dut.gen_spike_forwarder_4[0].weight_resolver_inst.weight_flit_count,
                 dut.gen_spike_forwarder_4[0].weight_resolver_inst.weight_flit_counter, $time);
    if (dut.gen_spike_forwarder_4[0].weight_resolver_inst.load_weight_mem)
        $display("[INIT] WR[0] mem[%0d] written: w[0]=0x%08h w[1]=0x%08h @%0t",
                 dut.gen_spike_forwarder_4[0].weight_resolver_inst.weight_addr_init,
                 dut.gen_spike_forwarder_4[0].weight_resolver_inst.weight_in_mem[31:0],
                 dut.gen_spike_forwarder_4[0].weight_resolver_inst.weight_in_mem[63:32], $time);
end
// Track load_weight_mem changes directly
always @(dut.gen_spike_forwarder_4[0].weight_resolver_inst.load_weight_mem) begin
    $display("[INIT] WR load_weight_mem changed to %b chip_mode=%b @%0t",
             dut.gen_spike_forwarder_4[0].weight_resolver_inst.load_weight_mem,
             dut.gen_spike_forwarder_4[0].weight_resolver_inst.chip_mode, $time);
end

// INFERENCE: SF8→SF4 write
always @(posedge clk) begin
    if (dut.spike_forwarder.spike_forwarder_inst.fifo_wr_en_out[0])
        $display("[INF] SF8→SF4[0]: data=0x%03h @%0t",
                 dut.spike_forwarder.spike_forwarder_inst.fifo_in_data_out[10:0], $time);
end

// INFERENCE: SF4→Cluster0 write
always @(posedge clk) begin
    if (dut.gen_spike_forwarder_4[0].spike_forwarder_4_inst.spike_forwarder_inst.fifo_wr_en_out[0])
        $display("[INF] SF4[0]→Cluster0: data=0x%03h @%0t",
                 dut.gen_spike_forwarder_4[0].spike_forwarder_4_inst.spike_forwarder_inst.fifo_in_data_out[10:0], $time);
end

// INFERENCE: incoming_forwarder match and weight address request
always @(posedge clk) begin
    if (dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.address_buffer_wr_en)
        $display("[INF] Cluster0 IF addr_buf_wr: addr=%0d @%0t",
                 dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.weight_address_out, $time);
    if (dut.gen_spike_forwarder_4[0].resolver_buffer_wr_en[0])
        $display("[INF] WR[0] addr pushed: addr=%0d @%0t",
                 dut.gen_spike_forwarder_4[0].resolver_buffer_addr_in[0 +: 8], $time);
end

// INFERENCE: weight_resolver outputs to cluster0
always @(posedge clk) begin
    if (dut.gen_spike_forwarder_4[0].resolver_load_weight_out[0])
        $display("[INF] WR→Cluster0: w[0]=0x%08h w[1]=0x%08h @%0t",
                 dut.gen_spike_forwarder_4[0].resolver_weight_out[31:0],
                 dut.gen_spike_forwarder_4[0].resolver_weight_out[63:32], $time);
end

// INFERENCE: Cluster0 load_weight_in
always @(posedge clk) begin
    if (dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.load_weight_in)
        $display("[INF] Cluster0 load_weight: w[0]=0x%08h w[1]=0x%08h @%0t",
                 dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.weights_in[31:0],
                 dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.weights_in[63:32], $time);
end

// INFERENCE: time_step + final state
always @(posedge clk) begin
    if (time_step)
        $display("[INF] time_step pulse: all_pre_spike[31:0]=0x%08h spike[0]=%b @%0t",
                 dut.all_pre_spike[31:0], dut.all_spikes[0], $time);
end

always @(dut.all_pre_spike[31:0]) begin
    if (dut.all_pre_spike[31:0] != 0)
        $display("[INF] all_pre_spike[0] NON-ZERO: 0x%08h @%0t",
                 dut.all_pre_spike[31:0], $time);
end
// Only print non-zero dump writes to keep output concise
always @(posedge clk) begin
    if (portb_we && portb_en && portb_din != 0) begin
        if (portb_addr >= VMEM_BASE && portb_addr < SPIKE_BASE)
            $display("[DUMP%0d] NON-ZERO V_MEM neuron=%0d = 0x%08h",
                     dump_number, portb_addr - VMEM_BASE, portb_din);
        else if (portb_addr >= SPIKE_BASE)
            $display("[DUMP%0d] NON-ZERO SPIKE word=%0d = 0b%032b",
                     dump_number, portb_addr - SPIKE_BASE, portb_din);
    end
end

// DUMP FSM timing probe — shows first 4 entries only (for debug; normally quiet)
always @(posedge clk) begin
    if (dut.dump_state == 1 && dut.dump_idx < 2 && dut.portb_we && dut.portb_din != 0)
        $display("[DUMP_FSM] VMEM idx=%0d val=0x%08h @%0t",
                 dut.dump_idx-1, dut.portb_din, $time);
end
// Track accelerator_done rising edge
reg prev_accel_done = 0;
always @(posedge clk) begin
    prev_accel_done <= dut.accelerator_done;
    if (dut.accelerator_done && !prev_accel_done)
        $display("[DUMP_FSM] accelerator_done ROSE: all_pre_spike[31:0]=0x%08h all_spikes[0]=%b @%0t",
                 dut.all_pre_spike[31:0], dut.all_spikes[0], $time);
end

// Detailed accelerator_done components — only show near time_step (for debug; keep quiet by default)
// Uncomment the $display below if you need to trace accelerator_done decomposition:
always @(posedge clk) begin
    if (time_step) begin
        // $display("[PROBE] t=%0t accel=%b all_cl=%b all_fwd=%b fifo_ei=%b fifo_eo=%b res=%b neurons_done=%b",
        //          $time, dut.accelerator_done, dut.all_clusters_done, dut.all_forwarders_done,
        //          dut.main_fifo_empty_in, dut.main_fifo_empty_out, dut.resolvers_done,
        //          dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0].neuron_cluster_inst.neurons_done_out);
    end
end

// ─── Init byte stream (EMBEDDED — no .mem file needed) ───────────────────────
//
// Packet structure fed to init_router (upper router ID = 0xA0):
//
//  FORMAT (each packet):
//   Byte 0:  router_address
//   Byte 1:  payload_byte_count
//   Bytes 2..N: payload
//
// For cluster 0 in group 0:
//   router_address = (group*4 + cluster_port) = 0x00  → lower_router_0
//   payload = cluster_controller bytes
//
// self_data_mng sits between lower_router and cluster_controller/weight_resolver:
//   Byte 0: port_select  (0=forwarder/cluster, 1=weight_resolver)
//   Byte 1: count        (bytes that follow)
//   Bytes 2..N: forwarded to selected module
//
// Spike forwarder 8 (upper self, address 0xA0):
//   byte0: {row_index[3:0], forwarding_row[8]}
//   byte1: forwarding_row[7:0]
//
// Spike forwarder 4 for group 0 (via self_data_mng port 0):
//   byte0: {row_index[2:0], forwarding_row[4:0]}
//
// Weights via self_data_mng port 1:
//   byte0: addr_low
//   byte1: addr_high
//   byte2: flit_count (=128 = 32 neurons * 4 bytes)
//   bytes 3..130: weight data (all Q16.16, little-endian)
//
// Q16.16 encoding:
//   5.0  = 0x00050000  → bytes: 00 00 05 00
//   2.0  = 0x00020000  → bytes: 00 00 02 00
//   3.0  = 0x00030000  → bytes: 00 00 03 00  (VT)

// Embedded init byte array (built with C-style integer literals for readability)
// Index tags show which logical packet each section belongs to.

integer init_idx;
integer init_len;
reg [7:0] init_rom [0:599]; // max 600 bytes, enough for this test

task load_init_rom;
    integer i;
    begin
        // zero everything first
        for (i = 0; i < 600; i = i + 1) init_rom[i] = 8'hxx;
        i = 0;

        // ====================================================
        // PKT 1: Init spike_forwarder_8 row 0
        //   Map[0] (from main): forward to group 0 (bit[1]) = 0b0_00000010
        //   byte0 = {row_index[3:0]=0, forwarding_row[8]=0} = 0x00
        //   byte1 = forwarding_row[7:0] = 0x02
        //   Packet: address=0xA0 (upper self), count=2, payload=[0x00, 0x02]
        // ====================================================
        init_rom[i]=8'hA0; i=i+1; // router addr = upper router self
        init_rom[i]=8'h02; i=i+1; // count = 2
        init_rom[i]=8'h00; i=i+1; // byte0: row=0, fwd_row[8]=0
        init_rom[i]=8'h02; i=i+1; // byte1: fwd_row[7:0]=0b00000010 → group0

        // ====================================================
        // PKT 2: Init spike_forwarder_8 row 1 (cluster 0 → back to main)
        //   Map[1] (from group 0): forward to main (bit[0]) = 0b0_00000001
        //   byte0 = {row_index=1, fwd[8]=0} = 0x10
        //   byte1 = 0x01
        // ====================================================
        init_rom[i]=8'hA0; i=i+1;
        init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h10; i=i+1; // byte0: row=1, fwd_row[8]=0
        init_rom[i]=8'h01; i=i+1; // byte1: fwd_row[7:0]=0b00000001 → main

        // ====================================================
        // PKT 3: Init spike_forwarder_4 (group 0) row 0
        //   Map[0] (from main): forward to cluster 0 port only (bit[1])
        //   byte0 = {row_index[2:0]=0, forwarding_row[4:0]=0b00010} = 0x02
        //   Packet: lower router self for group 0
        //     → lower router 0 ID = 0 * 4 + 0x80 = 0x80
        //     → self_data_mng wrapping: port_select=0 (forwarder), count=1, data=[byte0]
        //     → lower_self_packet: [0x80, 3, 0x00, 1, 0x02]
        //                           addr  cnt  sdm_port sdm_cnt sf4_byte
        // ====================================================
        init_rom[i]=8'h80; i=i+1; // router addr = lower router 0 self
        init_rom[i]=8'h03; i=i+1; // count = 3 bytes follow
        init_rom[i]=8'h00; i=i+1; // sdm: port_select=0 (→ spike_forwarder_4)
        init_rom[i]=8'h01; i=i+1; // sdm: count=1
        init_rom[i]=8'h02; i=i+1; // sf4 byte: {row=0, fwd=0b00010} → cl port 0

        // ====================================================
        // PKT 4: Init spike_forwarder_4 row 1
        //   Map[1] (from cluster 0 port): forward to main (bit[0]) = 0b00001
        //   byte0 = {row=1, fwd=0b00001} = (1<<5)|1 = 0x21
        // ====================================================
        init_rom[i]=8'h80; i=i+1;
        init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h01; i=i+1;
        init_rom[i]=8'h21; i=i+1; // {row=1, fwd=0b00001}

        // ====================================================
        // PKT 5: Cluster 0 — incoming_forwarder: base addr = 0
        //   OPCODE_LOAD_IF_BASE = 0x02, addr_low=0x00, addr_high=0x00
        //   Cluster controller packet for cluster 0 in group 0:
        //   lower_router port address = 0 (cluster 0 of group 0)
        //   packet: [0x00, count, cluster_ctrl_bytes...]
        // ====================================================
        init_rom[i]=8'h00; i=i+1; // addr: group0*4 + cluster0 = 0
        init_rom[i]=8'h03; i=i+1; // count = 3
        init_rom[i]=8'h02; i=i+1; // OPCODE_LOAD_IF_BASE
        init_rom[i]=8'h00; i=i+1; // base addr low
        init_rom[i]=8'h00; i=i+1; // base addr high

        // ====================================================
        // PKT 6: Cluster 0 — incoming_forwarder: register cluster 3
        //   OPCODE_LOAD_IF_ADDR = 0x03, cluster_id = 3
        //   NOTE: number_of_clusters=4 → cluster_id width=$clog2(4)=2 bits.
        //   Using cluster_id=3 (fits in 2 bits). Spike packet = 0x060.
        // ====================================================
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h02; i=i+1; // count = 2
        init_rom[i]=8'h03; i=i+1; // OPCODE_LOAD_IF_ADDR
        init_rom[i]=8'h03; i=i+1; // cluster_id = 3 (fits in 2-bit ID space)

        // ====================================================
        // PKT 7: Cluster 0 — Neuron 0 init: VT=3.0 Q16.16, LIF2 mode
        //   OPCODE_LOAD_NI=0x01, neuron_id=0, flit_count=9
        //   Payload (9 bytes):
        //     ADDER_VT_INIT=0xF9, 0x00,0x00,0x03,0x00, END=0xFF
        //     WORK_MODE=0xF7, LIF2_MODE=0x01 (no END needed for WORK_MODE)
        //     Padding END: 0xFF to fill flit_count
        //   WAIT: controller.v says flit_count = how many DATA flits follow
        //   Let's count: VT_INIT(1)+4 bytes+END(1) + WORK_MODE(1)+mode(1) = 8
        //   flit_count = 8
        // ====================================================
        init_rom[i]=8'h00; i=i+1; // addr: cluster 0
        init_rom[i]=8'h0B; i=i+1; // count = 11 bytes for cluster_ctrl
        init_rom[i]=8'h01; i=i+1; // OPCODE_LOAD_NI
        init_rom[i]=8'h00; i=i+1; // neuron_id = 0
        init_rom[i]=8'h08; i=i+1; // flit_count = 8
        // VT sub-packet (6 flits):
        init_rom[i]=8'hF9; i=i+1; // ADDER_VT_INIT
        init_rom[i]=8'h00; i=i+1; // VT = 0x00030000 → LE bytes: 00 00 03 00
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'hFF; i=i+1; // END_PACKET
        // WORK_MODE sub-packet (2 flits):
        init_rom[i]=8'hF7; i=i+1; // WORK_MODE
        init_rom[i]=8'h01; i=i+1; // LIF2_MODE = 0x01 (decay=LIF2, reset_mode=0)

        // ====================================================
        // PKT 8: Cluster 0 — Neuron 1 init: VT=3.0, LIF2 mode
        //   Same as above but neuron_id = 1
        // ====================================================
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h0B; i=i+1;
        init_rom[i]=8'h01; i=i+1; // OPCODE_LOAD_NI
        init_rom[i]=8'h01; i=i+1; // neuron_id = 1
        init_rom[i]=8'h08; i=i+1; // flit_count = 8
        init_rom[i]=8'hF9; i=i+1;
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF7; i=i+1;
        init_rom[i]=8'h01; i=i+1;

        // ====================================================
        // PKT 9: Weight Resolver (group 0) — Load weight row 0
        //   Row 0: source neuron 0 from cluster 62 → all 32 dest neurons
        //   Neuron 0 gets weight 5.0 (0x00050000), Neuron 1 gets 2.0 (0x00020000)
        //   All others: 0.
        //
        //   weight_resolver init protocol (via self_data_mng port 1):
        //     sdm_payload: [addr_low, addr_high, flit_count, w0[0..3], w1[0..3], ...]
        //     flit_count = 32 neurons * 4 bytes = 128 = 0x80
        //
        //   Packet: [0x80, count_outer, 0x01, count_inner, ...wr_bytes...]
        //           addr   total_cnt   port  sdm_cnt
        // ====================================================
        begin : weight_block
            integer wb;
            // sdm_payload = [addr_low=0x00, addr_high=0x00, flit_count=0x80, w0..w31]
            // total sdm payload bytes = 3 + 128 = 131
            // sdm wrap: [0x01(port), 131(count), 131 bytes] = 133 bytes
            // outer packet: [0x80(addr), 133(count), 133 bytes] = 135 bytes total
            init_rom[i]=8'h80; i=i+1; // addr: lower router 0 self
            init_rom[i]=8'h85; i=i+1; // count = 133 = 0x85
            init_rom[i]=8'h01; i=i+1; // sdm: port_select=1 (→ weight_resolver)
            init_rom[i]=8'h83; i=i+1; // sdm: count=131 = 0x83
            // weight_resolver header
            init_rom[i]=8'h00; i=i+1; // weight_addr low = 0
            init_rom[i]=8'h00; i=i+1; // weight_addr high = 0
            init_rom[i]=8'h80; i=i+1; // flit_count = 128 bytes (32 × 4)
            // Neuron 0: weight = 5.0 = 0x00050000 → LE: 00 00 05 00
            init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h05; i=i+1;
            init_rom[i]=8'h00; i=i+1;
            // Neuron 1: weight = 2.0 = 0x00020000 → LE: 00 00 02 00
            init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h02; i=i+1;
            init_rom[i]=8'h00; i=i+1;
            // Neurons 2..31: weight = 0
            for (wb = 2; wb < 32; wb = wb + 1) begin
                init_rom[i]=8'h00; i=i+1;
                init_rom[i]=8'h00; i=i+1;
                init_rom[i]=8'h00; i=i+1;
                init_rom[i]=8'h00; i=i+1;
            end
        end

        // Terminate with sentinel (0xXX = undefined stops init stream)
        init_rom[i] = 8'hxx;
        init_len = i;
        $display("[INIT_ROM] Built %0d bytes for init stream", i);
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
            end else begin
                load_data_in <= 0;
            end
        end else begin
            load_data_in <= 0;
            if (ready_in && !load_data_in) begin
                start_init   <= 0;
                init_done    <= 1;
                network_mode <= 0; // exit init mode — resolver uses pending_write so chip_mode drop is safe
                $display("[INIT] Stream complete at byte %0d", init_index);
            end
        end
    end else begin
        load_data_in <= 0;
    end
end

// ─── VCD dump for GTKWave ────────────────────────────────────────────────────
// We explicitly dump the internal DUT signals that matter for the trace.
// Open known_value_dump_tb.vcd in GTKWave and add these groups.
initial begin
    $dumpfile("known_value_dump_tb.vcd");
    $dumpvars(0, known_value_dump_tb); // all TB signals
    // DUT internal signals (depth=3 to catch cluster and neuron internals)
    // GTKWave: search for dut.gen_spike_forwarder_4[0].gen_neuron_cluster[0]
    //         .neuron_cluster_inst.neuron_layer_inst.neuron_gen[0].neuron_inst
    $dumpvars(3, dut);
end

// ─── Test ─────────────────────────────────────────────────────────────────────
integer pass_count = 0;
integer fail_count = 0;

initial begin
    $display("=============================================================");
    $display(" Known-Value Dump FSM Test (Level 4 Self-Contained)");
    $display("=============================================================");
    $display(" Network: cluster_group_count=1, 4 clusters, 128 neurons total");
    $display(" Cluster 0:");
    $display("   Neuron 0: weight=5.0  VT=3.0 → FIRES   v_pre=0x00050000");
    $display("   Neuron 1: weight=2.0  VT=3.0 → NO FIRE v_pre=0x00020000");
    $display("   Neurons 2..31: weight=0 → NO FIRE      v_pre=0x00000000");
    $display(" N_TOTAL=%0d N_SPIKE_W=%0d", N_TOTAL, N_SPIKE_W);
    $display(" vmem_base=0x%04h spike_base=0x%04h", VMEM_BASE, SPIKE_BASE);
    $display("=============================================================\n");

    // Build the init ROM
    load_init_rom();

    // Reset
    rst = 1;
    network_mode = 0;
    repeat(10) @(posedge clk);
    rst = 0;

    // Enter init mode and start streaming
    network_mode = 1;
    start_init   = 1;
    $display("[PHASE 1] Streaming init bytes (forwarder tables + neuron config + weights)...");

    // Wait for init bytes to all be accepted into the router
    wait(init_done);
    $display("[PHASE 1] Init done (byte %0d sent). dump_number so far = %0d", init_index, dump_number);

    // The first dump may have already occurred concurrently with init streaming.
    // Wait until dump_number reaches at least 1 (first dump_done pulse).
    if (dump_number < 1) begin
        $display("[PHASE 1] Waiting for first dump_done...");
        wait(dump_number >= 1);
    end
    $display("[PHASE 1] First dump complete (dump_number=%0d). All-zeros init dump done.", dump_number);
    repeat(5) @(posedge clk);

    // ==========================================================
    // PHASE 2: Inject spike, assert time_step, check dump 3
    //
    // PROTOCOL (matches neuron_accelerator_tb.v):
    //   1. Inject spike into main FIFO
    //   2. Wait for dump_done #2 (accelerator_done after spike pipeline drains)
    //      This dump captures all-zeros (time_step not yet issued)
    //   3. Issue time_step pulse → neurons compute → v_pre_spike latched T+1
    //   4. Wait for dump_done #3 (accelerator_done after neuron compute)
    //      Dump FSM latches all_pre_spike one cycle AFTER accelerator_done rises,
    //      so it captures the settled v_pre_spike values
    //   5. Verify dump 3 has correct values
    // ==========================================================
    $display("\n[PHASE 2] Injecting spike: cluster=3, neuron=0 (packet=0x060)");
    @(posedge clk); #1;
    main_fifo_din_in    <= 11'h060;  // {cluster_id=3, neuron_id=0}
    main_fifo_wr_en_in  <= 1;
    @(posedge clk); #1;
    main_fifo_wr_en_in  <= 0;
    $display("[PHASE 2] Spike injected. Waiting for dump_done #2 (pipeline drain)...");

    // Wait for dump 2 (accelerator_done after spike pipeline clears, values=0)
    wait(dump_number >= 2);
    $display("[PHASE 2] dump #2 received (dump_number=%0d) — spike pipeline cleared", dump_number);

    // Now issue time_step to trigger neuron computation
    $display("[PHASE 2] Asserting time_step...");
    @(posedge clk); #1;
    time_step <= 1;
    @(posedge clk); #1;
    time_step <= 0;
    $display("[PHASE 2] time_step done. Waiting for dump_done #3 (post-compute dump)...");

    // Wait for dump 3: triggered by accelerator_done after neurons compute
    // The dump FSM latches all_pre_spike 1 cycle after the trigger,
    // capturing the settled v_pre_spike values.
    wait(dump_number >= 3);
    repeat(5) @(posedge clk);
    $display("[PHASE 2] dump #3 received (dump_number=%0d)", dump_number);

    // ==========================================================
    // VERIFICATION
    // ==========================================================
    $display("\n=============================================================");
    $display(" VERIFICATION (checking dump #3 — post-inference timestep)");
    $display("=============================================================");

    // Dump sequence:
    //   dump 1: accelerator_done after init (all zeros)
    //   dump 2: accelerator_done after spike pipeline drains (no time_step, still zeros)
    //   dump 3: accelerator_done after neuron compute (v_pre_spike = real values)
    //
    // shared_mem is overwritten each dump (same addresses). The LAST values
    // are from dump 3 which has the correct v_pre_spike.

    // CHECK 1: Total write count = 3 dumps × (N_TOTAL vmem + N_SPIKE_W spike)
    begin : chk1
        integer expected_total;
        expected_total = 3 * (N_TOTAL + N_SPIKE_W);
        if (write_count == expected_total) begin
            $display("  [PASS] Total writes = %0d (3 dumps x %0d)", write_count, N_TOTAL+N_SPIKE_W);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Total writes = %0d, expected %0d (3 dumps x %0d)",
                     write_count, expected_total, N_TOTAL+N_SPIKE_W);
            fail_count = fail_count + 1;
        end
    end

    // CHECK 2: Neuron 0 v_pre_spike = 5.0 = 0x00050000
    if (shared_mem[VMEM_BASE + 0] == EXP_N0_VPRE) begin
        $display("  [PASS] Neuron 0 v_pre_spike = 0x%08h (5.0 Q16.16) ✓",
                 shared_mem[VMEM_BASE + 0]);
        pass_count = pass_count + 1;
    end else begin
        $display("  [FAIL] Neuron 0 v_pre_spike = 0x%08h, expected 0x%08h (5.0)",
                 shared_mem[VMEM_BASE + 0], EXP_N0_VPRE);
        fail_count = fail_count + 1;
    end

    // CHECK 3: Neuron 1 v_pre_spike = 2.0 = 0x00020000
    if (shared_mem[VMEM_BASE + 1] == EXP_N1_VPRE) begin
        $display("  [PASS] Neuron 1 v_pre_spike = 0x%08h (2.0 Q16.16) ✓",
                 shared_mem[VMEM_BASE + 1]);
        pass_count = pass_count + 1;
    end else begin
        $display("  [FAIL] Neuron 1 v_pre_spike = 0x%08h, expected 0x%08h (2.0)",
                 shared_mem[VMEM_BASE + 1], EXP_N1_VPRE);
        fail_count = fail_count + 1;
    end

    // CHECK 4: Neurons 2..7 are zero (no weights)
    begin : chk4
        integer k;
        integer zero_ok;
        zero_ok = 1;
        for (k = 2; k < 8; k = k + 1)
            if (shared_mem[VMEM_BASE + k] != 0) zero_ok = 0;
        if (zero_ok) begin
            $display("  [PASS] Neurons 2..7 v_pre_spike = 0 (no weights)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Neurons 2..7 should be zero but are not");
            fail_count = fail_count + 1;
        end
    end

    // CHECK 5: Spike word 0 bit 0 = 1 (neuron 0 fired), bit 1 = 0 (neuron 1 did not)
    begin : chk5
        reg [31:0] sw0;
        sw0 = shared_mem[SPIKE_BASE + 0];
        $display("  Spike word[0] = 0b%032b", sw0);
        if (sw0[0] == EXP_N0_SPIKE) begin
            $display("  [PASS] Spike bit[0] = %0b (neuron 0 fired)", sw0[0]);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Spike bit[0] = %0b, expected %0b", sw0[0], EXP_N0_SPIKE);
            fail_count = fail_count + 1;
        end
        if (sw0[1] == EXP_N1_SPIKE) begin
            $display("  [PASS] Spike bit[1] = %0b (neuron 1 did not fire)", sw0[1]);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Spike bit[1] = %0b, expected %0b", sw0[1], EXP_N1_SPIKE);
            fail_count = fail_count + 1;
        end
    end

    // CHECK 6: Exactly 3 dumps happened
    if (dump_number == 3) begin
        $display("  [PASS] dump_done pulsed exactly 3 times (init + spike-drain + inference) ✓");
        pass_count = pass_count + 1;
    end else begin
        $display("  [FAIL] dump_done count = %0d, expected 3", dump_number);
        fail_count = fail_count + 1;
    end

    $display("\n  First 4 V_mem entries (0x%04h...):", VMEM_BASE);
    begin : print_vmem
        integer k;
        for (k = 0; k < 4; k = k + 1)
            $display("    vmem[%0d] @ 0x%04h = 0x%08h  (%s)",
                     k, VMEM_BASE+k, shared_mem[VMEM_BASE+k],
                     (k==0) ? "N0 expect=0x00050000" :
                     (k==1) ? "N1 expect=0x00020000" : "expect=0x00000000");
    end

    $display("\n=============================================================");
    if (fail_count == 0) begin
        $display(" ALL %0d TESTS PASSED", pass_count);
        $display(" v_pre_spike correctly captured and dumped end-to-end!");
    end else begin
        $display(" %0d PASSED  /  %0d FAILED", pass_count, fail_count);
        $display(" Check GTKWave: known_value_dump_tb.vcd");
        $display(" Key signals to inspect:");
        $display("   portb_we / portb_addr / portb_din  — what the FSM writes");
        $display("   dut.all_pre_spike[31:0]            — cluster 0 neuron 0 (expect 0x00050000 after time_step)");
        $display("   dut.all_spikes[0]                  — neuron 0 spike bit");
        $display("   dut.dump_state                     — FSM state (0=IDLE 1=VMEM 2=SPIKES 3=DONE)");
    end
    $display("=============================================================");

    $finish;
end

// ─── Watchdog ─────────────────────────────────────────────────────────────────
initial begin
    #20_000_000;
    $display("[TIMEOUT] 20ms exceeded — possible deadlock");
    $display("  init_done=%b accelerator_done=%b dump_done=%b", init_done, accelerator_done, dump_done);
    $display("  init_index=%0d dump_number=%0d write_count=%0d", init_index, dump_number, write_count);
    $finish;
end

endmodule
