// ============================================================================
// packet_trace_tb.v  -  Pipeline packet trace diagnostic testbench
// ============================================================================
//
// PURPOSE
//   Instead of opening GTKWave, this testbench prints every packet movement
//   to the console with a level tag, so you can read top-to-bottom and see
//   exactly where a packet is dropped or gets stuck.
//
// DATA FLOW (spike path, top → bottom)
//
//   LV0  Testbench writes packet → main_fifo_in
//   LV1  spike_forwarder_8 reads from main_fifo_in
//   LV2  spike_forwarder_8 stores packet in SF4[g] out-FIFO
//   LV3  spike_forwarder_4[g] reads packet from SF8
//   LV4  spike_forwarder_4[g] stores packet in cluster[g][c] FIFO
//   LV5  neuron_cluster[g][c] reads packet from its FIFO
//   LV6  neuron_cluster[g][c] raises cluster_done
//
// INIT DATA FLOW
//
//   Bytes stream through:  TB → init_router_upper → init_router_lower[g]
//                                → cluster[g][c] config
//                                → weight_resolver[g] weights
//                          TB → init_router_upper → SF8 forwarding-table
//
// COMPILE
//   # iverilog (plain Verilog):
//   cd inference_accelarator/neuron_accelerator
//   iverilog -g2012 -o packet_trace \
//       -I../neuron_integer/neuron_int_lif \
//       packet_trace_tb.v
//   vvp packet_trace
//
//   # VCS:
//   vcs -full64 -sverilog -debug_access+all +v2k packet_trace_tb.v -o simv_trace
//   ./simv_trace
//
// ============================================================================

`include "neuron_accelerator.v"
`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns / 100ps

module packet_trace_tb;

// ============================================================================
// 1.  PARAMETERS  (must match the existing data_mem.mem / spike_mem.mem)
// ============================================================================
parameter PACKET_W          = 11;
parameter MAIN_FIFO_D       = 32;
parameter FWD8_FIFO_D       = 16;
parameter FWD4_FIFO_D       = 8;
// Must be 64: $clog2(64)=6 bits needed to store EXTERNAL_INPUT_CLUSTER_ID=62
parameter N_CLUSTERS        = 64;
parameter NEURONS_PER_CLU   = 32;
parameter INC_WEIGHT_ROWS   = 1024;
parameter MAX_WEIGHT_ROWS   = 4096;
parameter FLIT_SZ           = 8;
parameter CLU_GROUPS        = 8;    // 8 groups × 4 clusters = 32 clusters

// Trace controls — must match the spike_mem.mem / data_mem.mem layout
// XOR test data: 4 samples × 10 time-steps × 2 input neurons = 80 entries
//   Sample 0 (input 0,0) → ALL 0x7FF  (no spikes expected, XOR input is 0)
//   Sample 1 (input 1,0) → 7C1 spikes start at entry 20
//   Sample 2 (input 0,1) → 7C0 spikes start at entry 40
//   Sample 3 (input 1,1) → mixed spikes start at entry 60
parameter TRACE_INPUTS      = 4;    // total input samples in spike_mem.mem
parameter TRACE_TS          = 10;   // time steps per sample (time_step_window)
parameter TRACE_IN_NEURONS  = 2;    // input neurons per time step
parameter SETTLE_CYCLES     = 300;  // cycles to wait between inject & fire
parameter TIMEOUT_CYCLES    = 200000;// watchdog limit

// ============================================================================
// 2.  DUT SIGNALS
// ============================================================================
reg  clk, rst;
reg  network_mode, time_step, load_data_in, rst_potential;
reg  [FLIT_SZ-1:0]    data_in;
wire                  ready_in;
wire [FLIT_SZ-1:0]    data_out;
wire                  load_data_out;
reg                   ready_out;

reg  [PACKET_W-1:0]   main_fifo_din_in;
reg                   main_fifo_wr_en_in;
wire                  main_fifo_full_in;
wire [PACKET_W-1:0]   main_fifo_dout_out;
wire                  main_fifo_rd_en_out;
wire                  main_fifo_empty_out;

wire accelerator_done, dbg_all_clusters_done, dump_done;

wire [15:0] portb_addr;
wire [31:0] portb_din;
wire        portb_we, portb_en;
wire [31:0] portb_dout;
wire        collision_det;

reg  [31:0] wb_adr_i = 0, wb_dat_i = 0;
wire [31:0] wb_dat_o;
reg  [3:0]  wb_sel_i  = 4'hF;
reg         wb_we_i   = 0, wb_stb_i = 0, wb_cyc_i = 0;
wire        wb_ack_o;

// ============================================================================
// 3.  MEMORIES
// ============================================================================
reg [7:0]  init_mem  [0:10000];
reg [10:0] spike_mem [0:1000];

// ============================================================================
// 4.  TEST FSM REGISTERS
// ============================================================================
reg  start_init, init_done, start_inf;
reg  [31:0] init_index;
reg  [31:0] input_neuron_idx, ts_idx, sample_idx;

localparam S_INJECT = 2'd0;
localparam S_SETTLE = 2'd1;
localparam S_FIRE   = 2'd2;
localparam S_WAIT   = 2'd3;

reg [1:0]  inf_state;
reg [11:0] settle_ctr;
reg        rearm_pending;

// ============================================================================
// 5.  PIPELINE LEVEL COUNTERS
//     Blocking assignments are fine here; debug-only, not synthesised.
// ============================================================================
integer lv0_cnt;  // TB → main_fifo_in          (packets written)
integer lv1_cnt;  // SF8 reads main_fifo_in      (packets consumed by SF8)
integer lv2_cnt;  // SF8 → SF4[g] port-FIFO      (total writes across all groups)
integer lv3_cnt;  // SF4[g] reads from SF8        (total reads across all groups)
integer lv4_cnt;  // SF4[g] → cluster FIFO        (total writes across all clusters)
integer lv5_cnt;  // cluster reads from SF4       (total reads)
// per-sample counters reset for each new sample
integer sample_lv0_cnt;

// ============================================================================
// 6.  SHARED MEMORY
// ============================================================================
localparam SMEM_BASE  = 32'h2000_0000;
localparam SMEM_DEPTH = 49152;

snn_shared_memory_wb #(
    .MEM_DEPTH(SMEM_DEPTH),
    .BASE_ADDR(SMEM_BASE)
) shared_mem (
    .clk(clk), .rst(rst),
    .wb_adr_i(wb_adr_i), .wb_dat_i(wb_dat_i),
    .wb_dat_o(wb_dat_o), .wb_sel_i(wb_sel_i),
    .wb_we_i(wb_we_i), .wb_stb_i(wb_stb_i),
    .wb_cyc_i(wb_cyc_i), .wb_ack_o(wb_ack_o),
    .portb_addr(portb_addr[14:2]),
    .portb_din(portb_din), .portb_dout(portb_dout),
    .portb_we(portb_we), .portb_en(portb_en),
    .collision_detect(collision_det)
);

// ============================================================================
// 7.  DUT INSTANTIATION
// ============================================================================
neuron_accelerator #(
    .packet_width            (PACKET_W),
    .main_fifo_depth         (MAIN_FIFO_D),
    .forwarder_8_fifo_depth  (FWD8_FIFO_D),
    .forwarder_4_fifo_depth  (FWD4_FIFO_D),
    .number_of_clusters      (N_CLUSTERS),
    .neurons_per_cluster     (NEURONS_PER_CLU),
    .incoming_weight_table_rows(INC_WEIGHT_ROWS),
    .max_weight_table_rows   (MAX_WEIGHT_ROWS),
    .cluster_group_count     (CLU_GROUPS),
    .flit_size               (FLIT_SZ)
) uut (
    .clk(clk), .rst(rst),
    .network_mode(network_mode),
    .time_step(time_step),
    .load_data_in(load_data_in),
    .rst_potential(rst_potential),
    .data_in(data_in),
    .ready_in(ready_in),
    .data_out(data_out),
    .load_data_out(load_data_out),
    .ready_out(ready_out),
    .main_fifo_din_in(main_fifo_din_in),
    .main_fifo_wr_en_in(main_fifo_wr_en_in),
    .main_fifo_full_in(main_fifo_full_in),
    .main_fifo_dout_out(main_fifo_dout_out),
    .main_fifo_rd_en_out(main_fifo_rd_en_out),
    .main_fifo_empty_out(main_fifo_empty_out),
    .accelerator_done(accelerator_done),
    .dbg_all_clusters_done(dbg_all_clusters_done),
    .dump_done(dump_done),
    .portb_addr(portb_addr),
    .portb_din(portb_din),
    .portb_we(portb_we),
    .portb_en(portb_en),
    .vmem_base_addr(16'hA000),
    .spike_base_addr(16'hB000),
    .current_timestep(ts_idx[3:0])
);

always #5 clk = ~clk;
assign main_fifo_rd_en_out = ~main_fifo_empty_out;

// ============================================================================
// 8.  PIPELINE TRACE MONITORS
//
//     Each always block fires on posedge clk, checks a signal, and prints
//     a labelled line.  genvar-indexed blocks produce one always per index,
//     which avoids runtime hierarchy indexing.
// ============================================================================

// ─── LV0: TB writes ──────────────────────────────────────────────────────────
always @(posedge clk) begin
    if (main_fifo_wr_en_in && !rst) begin
        $display("[%0t] LV0 TB→FIFO:       wrote pkt=0x%03X  (src_clu=%0d neu=%0d)  [sample=%0d ts=%0d]",
                 $time, main_fifo_din_in,
                 main_fifo_din_in[10:5], main_fifo_din_in[4:0],
                 sample_idx, ts_idx);
        lv0_cnt        = lv0_cnt + 1;
        sample_lv0_cnt = sample_lv0_cnt + 1;
    end
end

// ─── LV1: SF8 reads main_fifo_in ─────────────────────────────────────────────
always @(posedge clk) begin
    if (uut.main_fifo_rd_en_in && !uut.main_fifo_empty_in) begin
        $display("[%0t] LV1 FIFO→SF8:      read  pkt=0x%03X  sf8_eligible=%b  sf8_fwd_map[0]=%b",
                 $time, uut.main_fifo_dout_in,
                 uut.spike_forwarder.spike_forwarder_inst.eligible,
                 uut.spike_forwarder.spike_forwarder_inst.forwarding_map[0]);
        lv1_cnt = lv1_cnt + 1;
    end
end

// ─── LV2: SF8 writes to SF4[g] port-FIFO ─────────────────────────────────────
//          (8 always blocks, one per group – genvar g is a compile-time constant)
genvar g;
generate
    for (g = 0; g < 8; g = g+1) begin : lv2_mon
        always @(posedge clk) begin
            if (uut.spike_forwarder.spike_forwarder_inst.fifo_wr_en_out[g]) begin
                $display("[%0t] LV2 SF8→SF4[%0d]:    wrote pkt=0x%03X  (src_clu=%0d neu=%0d)",
                         $time, g,
                         uut.spike_forwarder.spike_forwarder_inst.fifo_in_data_out[g*11 +: 11],
                         uut.spike_forwarder.spike_forwarder_inst.fifo_in_data_out[g*11+5 +: 6],
                         uut.spike_forwarder.spike_forwarder_inst.fifo_in_data_out[g*11 +: 5]);
                lv2_cnt = lv2_cnt + 1;
            end
        end
    end
endgenerate

// ─── LV3: SF4[g] reads from SF8 port-FIFO ────────────────────────────────────
generate
    for (g = 0; g < 8; g = g+1) begin : lv3_mon
        always @(posedge clk) begin
            if (uut.gen_spike_forwarder_4[g].spike_forwarder_4_inst.spike_forwarder_inst.main_fifo_rd_en_out) begin
                $display("[%0t] LV3 SF4[%0d]←SF8:    read  pkt=0x%03X  sf4_fwd_map[0]=%b",
                         $time, g,
                         uut.forwarder_8_fifo_out_data_out[g*11 +: 11],
                         uut.gen_spike_forwarder_4[g].spike_forwarder_4_inst.spike_forwarder_inst.forwarding_map[0]);
                lv3_cnt = lv3_cnt + 1;
            end
        end
    end
endgenerate

// ─── LV4: SF4[g] writes to cluster[g][c] FIFO ────────────────────────────────
genvar c;
generate
    for (g = 0; g < 8; g = g+1) begin : lv4_mon_g
        for (c = 0; c < 4; c = c+1) begin : lv4_mon_c
            always @(posedge clk) begin
                if (uut.gen_spike_forwarder_4[g].spike_forwarder_4_inst.spike_forwarder_inst.fifo_wr_en_out[c]) begin
                    $display("[%0t] LV4 SF4[%0d]→CLU[%0d][%0d]: wrote pkt=0x%03X",
                             $time, g, g, c,
                             uut.gen_spike_forwarder_4[g].spike_forwarder_4_inst.spike_forwarder_inst.fifo_in_data_out[c*11 +: 11]);
                    lv4_cnt = lv4_cnt + 1;
                end
            end
        end
    end
endgenerate

// ─── LV5: cluster[g][c] reads packet from its FIFO ───────────────────────────
generate
    for (g = 0; g < 8; g = g+1) begin : lv5_mon_g
        for (c = 0; c < 4; c = c+1) begin : lv5_mon_c
            always @(posedge clk) begin
                if (uut.gen_spike_forwarder_4[g].forwarder_4_fifo_rd_en_out[c] &&
                    !uut.gen_spike_forwarder_4[g].forwarder_4_fifo_empty_out[c]) begin
                    $display("[%0t] LV5 CLU[%0d][%0d]←SF4:   read  pkt=0x%03X  (src_clu=%0d neu=%0d)",
                             $time, g, c,
                             uut.gen_spike_forwarder_4[g].forwarder_4_fifo_out_data_out[c*11 +: 11],
                             uut.gen_spike_forwarder_4[g].forwarder_4_fifo_out_data_out[c*11+5 +: 6],
                             uut.gen_spike_forwarder_4[g].forwarder_4_fifo_out_data_out[c*11 +: 5]);
                    lv5_cnt = lv5_cnt + 1;
                end
            end
        end
    end
endgenerate

// ─── LV6: cluster_done ────────────────────────────────────────────────────────
generate
    for (g = 0; g < 8; g = g+1) begin : lv6_mon_g
        for (c = 0; c < 4; c = c+1) begin : lv6_mon_c
            always @(posedge clk) begin
                if (uut.gen_spike_forwarder_4[g].cluster_done[c])
                    $display("[%0t] LV6 CLU[%0d][%0d] cluster_done=1", $time, g, c);
            end
        end
    end
endgenerate

// ─── accelerator_done & dump_done ────────────────────────────────────────────
always @(posedge clk) begin
    if (accelerator_done && start_inf)
        $display("[%0t] >>> accelerator_done HIGH  (all_clu=%b  all_fwd=%b  mfifo_in_empty=%b  mfifo_out_empty=%b)",
                 $time, uut.dbg_all_clusters_done,
                 uut.all_forwarders_done,
                 uut.main_fifo_empty_in,
                 uut.main_fifo_empty_out);
    if (dump_done)
        $display("[%0t] >>> dump_done  portb_addr=0x%04X  portb_din=0x%08X",
                 $time, portb_addr, portb_din);
end

// ============================================================================
// 9.  INIT DATA PATH MONITORS
//     Shows which router / cluster each init byte reaches.
// ============================================================================
always @(posedge clk) begin
    if (load_data_in && ready_in)
        $display("[%0t] INIT →upper_router:  byte=0x%02X  (idx=%0d)",
                 $time, data_in, init_index - 1);
end

// Upper router routes byte to SF8 (its own forward-table port)
always @(posedge clk) begin
    if (uut.init_router_upper.load_data)
        $display("[%0t] INIT upper→SF8:       byte=0x%02X", $time, uut.init_router_upper.data);
end

// Upper router routes byte down to lower router[g]
generate
    for (g = 0; g < 8; g = g+1) begin : init_up_to_low
        always @(posedge clk) begin
            if (uut.init_router_upper.load_data_lower_out[g])
                $display("[%0t] INIT upper→lower[%0d]:  byte=0x%02X",
                         $time, g, uut.init_router_upper.data_lower_out[g*8 +: 8]);
        end
    end
endgenerate

// Lower router[g] routes byte to SF4[g] (its own forward-table port)
generate
    for (g = 0; g < 8; g = g+1) begin : init_low_to_fwd4
        always @(posedge clk) begin
            if (uut.gen_spike_forwarder_4[g].init_router_lower.load_data)
                $display("[%0t] INIT lower[%0d]→SF4:    byte=0x%02X",
                         $time, g, uut.gen_spike_forwarder_4[g].init_router_lower.data);
        end
    end
endgenerate

// Lower router[g] routes byte to cluster[g][c]
generate
    for (g = 0; g < 8; g = g+1) begin : init_low_to_clu_g
        for (c = 0; c < 4; c = c+1) begin : init_low_to_clu_c
            always @(posedge clk) begin
                if (uut.gen_spike_forwarder_4[g].init_router_lower.load_data_lower_out[c])
                    $display("[%0t] INIT lower[%0d]→CLU[%0d][%0d]: byte=0x%02X",
                             $time, g, g, c,
                             uut.gen_spike_forwarder_4[g].init_router_lower.data_lower_out[c*8 +: 8]);
            end
        end
    end
endgenerate

// ============================================================================
// 10.  HELPER TASKS
// ============================================================================

// print_forwarding_maps
//   Shows the static routing tables loaded during init.
//   Only SF8 and SF4[0] are printed since the others follow the same pattern.
//   !! To see SF4[g] for g>0 replace the literal 0 with a different constant.
task print_forwarding_maps;
    integer ri;
    begin
        $display("");
        $display("============================================================");
        $display("FORWARDING MAPS (loaded during init)");
        $display("------------------------------------------------------------");
        $display("SF8 map (9 rows: row0=from main_fifo, rows1-8=from SF4[0-7])");
        $display("  Each row bits: [8]=back-to-main  [7:0]=to SF4[0]-SF4[7]");
        for (ri = 0; ri <= 8; ri = ri+1)
            $display("  sf8_fwd[%0d] = %09b",
                     ri, uut.spike_forwarder.spike_forwarder_inst.forwarding_map[ri]);
        $display("------------------------------------------------------------");
        $display("SF4[0] map (5 rows: row0=from SF8, rows1-4=from CLU0-CLU3)");
        $display("  Each row bits: [4]=back-to-SF8  [3:0]=to CLU0-CLU3");
        for (ri = 0; ri <= 4; ri = ri+1)
            $display("  sf4[0]_fwd[%0d] = %05b",
                     ri, uut.gen_spike_forwarder_4[0].spike_forwarder_4_inst.spike_forwarder_inst.forwarding_map[ri]);
        $display("============================================================");
        $display("");
    end
endtask

// print_pipeline_status
//   Snapshot of every FIFO occupancy and done flags – call this when stuck.
task print_pipeline_status;
    begin
        $display("");
        $display("============================================================");
        $display("[%0t] PIPELINE STATUS SNAPSHOT", $time);
        $display("  main_fifo_in:  count=%0d  full=%b  empty=%b",
                 uut.main_fifo_count_in,  uut.main_fifo_full_in,  uut.main_fifo_empty_in);
        $display("  main_fifo_out: count=%0d  empty=%b",
                 uut.main_fifo_count_out, uut.main_fifo_empty_out);
        $display("  SF8 port-FIFO empty_out (to SF4): %08b  (bit g = SF4[g])",
                 uut.forwarder_8_fifo_empty_out);
        $display("  SF8 port-FIFO full_in (from SF4): %08b",
                 uut.forwarder_8_fifo_full_in);
        $display("  SF8 done=%b  eligible=%09b  inflight[0]=%0d",
                 uut.forwarder_8_done,
                 uut.spike_forwarder.spike_forwarder_inst.eligible,
                 uut.spike_forwarder.spike_forwarder_inst.inflight_count[0]);
        $display("  SF4 per-group done: %08b", uut.forwarder_4_done);
        $display("  cluster_4_done:     %08b  (bit g = group g all-done)",
                 uut.cluster_4_done);
        $display("  all_clusters_done=%b  all_forwarders_done=%b  resolvers_done=%b",
                 uut.all_clusters_done, uut.all_forwarders_done, uut.resolvers_done);
        $display("  accelerator_done = %b", accelerator_done);
        $display("  --");
        $display("  Packet hop counts:");
        $display("    LV0 TB→FIFO writes:     %0d", lv0_cnt);
        $display("    LV1 SF8 reads:          %0d", lv1_cnt);
        $display("    LV2 SF8→SF4 writes:     %0d", lv2_cnt);
        $display("    LV3 SF4 reads from SF8: %0d", lv3_cnt);
        $display("    LV4 SF4→CLU writes:     %0d", lv4_cnt);
        $display("    LV5 CLU reads from SF4: %0d", lv5_cnt);
        $display("============================================================");
        $display("");
    end
endtask

// diagnose_stuck
//   Called by the watchdog or the final summary to say at which level packets
//   were lost.
task diagnose_stuck;
    begin
        $display("");
        $display("============================================================");
        $display("STUCK-POINT DIAGNOSIS");
        if (lv0_cnt == 0)
            $display("  [!] No packets were injected (lv0=0). Check spike_mem.mem.");
        else if (lv1_cnt == 0)
            $display("  [!] STUCK at LV1: %0d packet(s) written to main_fifo but SF8 never read.", lv0_cnt);
        else if (lv2_cnt == 0)
            $display("  [!] STUCK at LV2: SF8 read %0d packet(s) but never wrote to SF4 port-FIFOs.", lv1_cnt);
        else if (lv3_cnt == 0)
            $display("  [!] STUCK at LV3: %0d writes into SF4 port-FIFOs but SF4 never read.", lv2_cnt);
        else if (lv4_cnt == 0)
            $display("  [!] STUCK at LV4: SF4 read %0d packet(s) but never wrote to cluster FIFOs.", lv3_cnt);
        else if (lv5_cnt == 0)
            $display("  [!] STUCK at LV5: %0d writes to cluster FIFOs but cluster never read.", lv4_cnt);
        else
            $display("  [OK] Packets reached cluster level (%0d reads). Check cluster_done.", lv5_cnt);
        $display("============================================================");
        $display("");
    end
endtask

// ============================================================================
// 11.  GLOBAL TIMEOUT WATCHDOG
// ============================================================================
initial begin
    #(TIMEOUT_CYCLES * 10);   // 10 ns per clock cycle
    $display("[%0t] **** WATCHDOG TIMEOUT after %0d cycles ****", $time, TIMEOUT_CYCLES);
    print_pipeline_status;
    diagnose_stuck;
    $finish;
end

// ============================================================================
// 12.  INIT LOADING FSM
//      Streams data_mem.mem byte-by-byte through load_data_in / data_in.
// ============================================================================
always @(posedge clk) begin
    if (start_init) begin
        if (init_mem[init_index] !== 8'bx) begin
            // Still have bytes to send
            if (ready_in && !load_data_in) begin
                data_in      <= init_mem[init_index];
                load_data_in <= 1;
                init_index   <= init_index + 1;
            end else
                load_data_in <= 0;
        end else begin
            // End-of-init marker reached  (uninitialized = 8'bx means no more data)
            load_data_in <= 0;
            if (ready_in && !load_data_in) begin
                network_mode <= 0;          // switch to spike mode
                start_init   <= 0;
                init_done    <= 1;
                $display("");
                $display("[%0t] [INIT] Complete: %0d bytes sent", $time, init_index);
                print_forwarding_maps;
            end
        end
    end else begin
        load_data_in <= 0;
        if (init_done && accelerator_done) begin
            $display("[%0t] [INIT] Accelerator is ready — starting spike trace", $time);
            start_inf  <= 1;
            inf_state  <= S_INJECT;
            init_done  <= 0;
        end
    end
end

// ============================================================================
// 13.  SPIKE INJECTION + INFERENCE FSM
// ============================================================================
wire [31:0] spike_mem_idx;
assign spike_mem_idx = input_neuron_idx
                     + ts_idx * TRACE_IN_NEURONS
                     + sample_idx * TRACE_TS * TRACE_IN_NEURONS;

always @(posedge clk) begin
    // Auto-clear single-cycle pulses
    if (time_step)     time_step     <= 0;
    if (rst_potential) rst_potential <= 0;
    main_fifo_wr_en_in <= 0;

    if (start_inf) begin
        case (inf_state)

            //------------------------------------------------------------------
            // S_INJECT: push spike_mem entries for this time step into main FIFO
            //------------------------------------------------------------------
            S_INJECT: begin
                if (input_neuron_idx < TRACE_IN_NEURONS) begin
                    if (spike_mem[spike_mem_idx] !== 11'h7FF) begin
                        // Valid spike — write to FIFO if not full
                        if (!main_fifo_full_in) begin
                            main_fifo_din_in   <= spike_mem[spike_mem_idx];
                            main_fifo_wr_en_in <= 1;
                        end else begin
                            $display("[%0t] [WARN] FIFO FULL — dropped pkt=0x%03X  sample=%0d ts=%0d neu=%0d",
                                     $time, spike_mem[spike_mem_idx], sample_idx, ts_idx, input_neuron_idx);
                        end
                    end
                    // Note: 0x7FF = no spike for this neuron this ts (normal)
                    input_neuron_idx <= input_neuron_idx + 1;
                end else begin
                    // All neurons for this time step injected
                    input_neuron_idx <= 0;
                    settle_ctr       <= 0;
                    inf_state        <= S_SETTLE;
                    $display("[%0t] [INJ]  sample=%0d ts=%0d done — injected %0d spike(s) this ts — settling %0d cyc",
                             $time, sample_idx, ts_idx, sample_lv0_cnt, SETTLE_CYCLES);
                end
            end

            //------------------------------------------------------------------
            // S_SETTLE: wait for the network to process
            //------------------------------------------------------------------
            S_SETTLE: begin
                if (settle_ctr >= SETTLE_CYCLES) begin
                    settle_ctr <= 0;
                    inf_state  <= S_FIRE;
                end else
                    settle_ctr <= settle_ctr + 1;
            end

            //------------------------------------------------------------------
            // S_FIRE: pulse time_step and advance to next ts or wait
            //------------------------------------------------------------------
            S_FIRE: begin
                $display("[%0t] [FIRE] Pulsing time_step for ts=%0d", $time, ts_idx);
                print_pipeline_status;
                time_step  <= 1;
                settle_ctr <= 0;
                if (ts_idx + 1 < TRACE_TS) begin
                    ts_idx    <= ts_idx + 1;
                    inf_state <= S_INJECT;
                end else
                    inf_state <= S_WAIT;
            end

            //------------------------------------------------------------------
            // S_WAIT: final settle before declaring the sample done
            //------------------------------------------------------------------
            S_WAIT: begin
                if (settle_ctr >= SETTLE_CYCLES) begin
                    $display("[%0t] [DONE] Sample %0d finished. Total injected this sample: %0d spike(s).",
                             $time, sample_idx, sample_lv0_cnt);
                    if (sample_lv0_cnt == 0)
                        $display("[%0t]       (sample %0d has ALL 0x7FF entries — EXPECTED for XOR input 0,0)",
                                 $time, sample_idx);
                    print_pipeline_status;
                    sample_lv0_cnt = 0;   // reset per-sample counter
                    ts_idx        <= 0;
                    sample_idx    <= sample_idx + 1;
                    rst_potential <= 1;
                    start_inf     <= 0;
                    settle_ctr    <= 0;
                    inf_state     <= S_INJECT;
                end else
                    settle_ctr <= settle_ctr + 1;
            end

            default: inf_state <= S_INJECT;
        endcase
    end
end

// ─── Re-arm for next sample ────────────────────────────────────────────────
always @(posedge clk) begin
    if (rst) begin
        rearm_pending <= 0;
    end else begin
        if (rst_potential)
            rearm_pending <= 1;
        if (rearm_pending && !start_inf) begin
            rearm_pending <= 0;
            if (sample_idx < TRACE_INPUTS) begin
                start_inf <= 1;
                inf_state <= S_INJECT;
            end
        end
    end
end

// ─── Termination ──────────────────────────────────────────────────────────
always @(posedge clk) begin
    if (sample_idx >= TRACE_INPUTS && !start_inf && !rearm_pending) begin
        repeat(100) @(posedge clk);
        $display("");
        $display("============================================================");
        $display("TRACE COMPLETE — %0d sample(s) processed", TRACE_INPUTS);
        $display("Final pipeline hop counts:");
        $display("  LV0  TB→FIFO writes:      %0d", lv0_cnt);
        $display("  LV1  SF8 reads main_fifo:  %0d", lv1_cnt);
        $display("  LV2  SF8→SF4 port writes:  %0d", lv2_cnt);
        $display("  LV3  SF4 reads from SF8:   %0d", lv3_cnt);
        $display("  LV4  SF4→CLU writes:       %0d", lv4_cnt);
        $display("  LV5  CLU reads from SF4:   %0d", lv5_cnt);
        $display("------------------------------------------------------------");
        diagnose_stuck;
        $finish;
    end
end

// ============================================================================
// 14.  INITIAL BLOCK — reset, load memories, start init
// ============================================================================
initial begin
    $display("============================================================");
    $display(" PACKET TRACE TESTBENCH");
    $display("   Clusters: %0d  Groups: %0d  Neurons/cluster: %0d",
             N_CLUSTERS, CLU_GROUPS, NEURONS_PER_CLU);
    $display("   Tracing:  %0d sample(s), %0d time-steps, %0d neurons/ts",
             TRACE_INPUTS, TRACE_TS, TRACE_IN_NEURONS);
    $display("   Settle:   %0d cycles per time-step", SETTLE_CYCLES);
    $display("   Watchdog: %0d cycles", TIMEOUT_CYCLES);
    $display("============================================================");

    // Initialise signals
    clk = 0; rst = 1;
    network_mode = 0; load_data_in = 0;
    rst_potential = 0; data_in = 0; ready_out = 0;
    main_fifo_din_in = 0; main_fifo_wr_en_in = 0; time_step = 0;
    start_init = 0; init_done = 0; init_index = 0;
    start_inf  = 0; sample_idx = 0; ts_idx = 0; input_neuron_idx = 0;
    inf_state  = S_INJECT; settle_ctr = 0; rearm_pending = 0;
    lv0_cnt = 0; lv1_cnt = 0; lv2_cnt = 0;
    lv3_cnt = 0; lv4_cnt = 0; lv5_cnt = 0;
    sample_lv0_cnt = 0;

    // Load data from files used by the standard testbench
    $readmemh("data_mem.mem",  init_mem);
    $readmemh("spike_mem.mem", spike_mem);

    // Release reset and begin initialisation
    #20 rst = 0;
    network_mode = 1;   // config mode while loading weights
    start_init   = 1;
    $display("[%0t] Reset released — beginning init phase", $time);
end

endmodule
