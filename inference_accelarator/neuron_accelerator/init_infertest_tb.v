// ============================================================================
// init_infertest_tb.v  —  Dual-purpose diagnostic testbench
// ============================================================================
//
// PHASE 1 — INIT VERIFICATION
//   Counts how many config bytes each cluster port receives during the init
//   phase.  If a cluster shows 0 bytes it was never initialised → that is
//   where the data_mem path is broken.
//
// PHASE 2 — INFERENCE + OUTPUT CHECK
//   Runs all 4 XOR samples and captures neuron spikes per cluster per
//   time-step.  At the end of every sample it prints a table:
//
//     CLU_id  spike_count   ← any cluster with spikes is an "output" cluster
//
//   Also monitors the accelerator output FIFO to catch packets that exit the
//   spike network (output-layer neurons routing back out).
//   Finally compares the firing pattern to the XOR truth table and prints a
//   PASS/FAIL verdict for each sample.
//
// COMPILE & RUN
//   cd inference_accelarator/neuron_accelerator
//   vcs -full64 -sverilog -debug_access+all +v2k init_infertest_tb.v -o simv_init_inf
//   ./simv_init_inf
// ============================================================================

`include "neuron_accelerator.v"
`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns / 100ps

module init_infertest_tb;

// ============================================================================
// 1.  PARAMETERS  (must match data_mem.mem / spike_mem.mem)
// ============================================================================
parameter PACKET_W         = 11;
parameter MAIN_FIFO_D      = 32;
parameter FWD8_FIFO_D      = 16;
parameter FWD4_FIFO_D      = 8;
// number_of_clusters MUST be 64 (not 32) so that $clog2(number_of_clusters)=6 bits,
// which lets cluster_controller store EXTERNAL_INPUT_CLUSTER_ID=62 without truncation.
// With number_of_clusters=32 the 6th bit is dropped: 62 → 30, incoming_forwarder
// never matches the spike source, no weights are fetched, neurons never fire.
parameter N_CLUSTERS       = 64;
parameter NEURONS_PER_CLU  = 32;
parameter INC_WEIGHT_ROWS  = 1024;
parameter MAX_WEIGHT_ROWS  = 4096;
parameter FLIT_SZ          = 8;
parameter CLU_GROUPS       = 8;

// The XOR network topology (from generate_xor_test.py):
//   CLU_0 = hidden layer  (neuron 0=H0/OR, neuron 1=H1/AND)
//   CLU_1 = output layer  (neuron 0=XOR output)
// Decision rule: CLU_1 total spikes across all time-steps:
//   >0  → predicted class 1
//    0  → predicted class 0
// Sample 0 (input 0,0): no input spikes at all → nothing fires → class 0 ✓
parameter OUTPUT_CLUSTER_ID = 1;  // which cluster encodes the output
parameter N_SAMPLES        = 4;
parameter N_TS             = 10;
parameter N_INPUT_NEURONS  = 2;
parameter SETTLE_PRE       = 100;   // cycles before firing time_step
parameter SETTLE_POST      = 500;   // max cycles to wait for accelerator_done
parameter TIMEOUT_CYCLES   = 500000;

// ============================================================================
// 2.  DUT SIGNALS
// ============================================================================
reg  clk, rst;
reg  network_mode, time_step, load_data_in, rst_potential;
reg  [FLIT_SZ-1:0]   data_in;
wire                  ready_in;
wire [FLIT_SZ-1:0]   data_out;
wire                  load_data_out;
reg                   ready_out;

reg  [PACKET_W-1:0]  main_fifo_din_in;
reg                  main_fifo_wr_en_in;
wire                 main_fifo_full_in;
wire [PACKET_W-1:0]  main_fifo_dout_out;
wire                 main_fifo_rd_en_out;
wire                 main_fifo_empty_out;

wire accelerator_done, dbg_all_clusters_done, dump_done;

wire [15:0] portb_addr;
wire [31:0] portb_din;
wire        portb_we, portb_en;
wire [31:0] portb_dout;
wire        collision_det;

reg  [31:0] wb_adr_i=0, wb_dat_i=0;
wire [31:0] wb_dat_o;
reg  [3:0]  wb_sel_i=4'hF;
reg         wb_we_i=0, wb_stb_i=0, wb_cyc_i=0;
wire        wb_ack_o;

// ============================================================================
// 3.  MEMORIES
// ============================================================================
reg [7:0]  init_mem  [0:20000];
reg [10:0] spike_mem [0:1000];

// ============================================================================
// 4.  TEST FSM CONTROL
// ============================================================================
reg  start_init, init_done, start_inf;
reg  [31:0] init_index;
reg  [31:0] in_neuron_idx, ts_idx, sample_idx;

localparam S_INJECT    = 3'd0;
localparam S_SETTLE    = 3'd1;
localparam S_FIRE      = 3'd2;
localparam S_WAIT_DONE = 3'd3;
localparam S_NEXT_TS   = 3'd4;
localparam S_DONE_SMPL = 3'd5;

reg [2:0]  inf_state;
reg [11:0] settle_ctr;
reg        rearm_pending;

// ============================================================================
// 5.  COUNTERS  (using genvar-indexed generate blocks → compile-time constant)
// ============================================================================

// ── Init: count load_data pulses received per cluster ───────────────────────
integer clu_init_cnt [0:31];   // index = group*4 + cluster_in_group

genvar gd, cd;
generate
    for (gd = 0; gd < 8; gd = gd+1) begin : init_cnt_g
        for (cd = 0; cd < 4; cd = cd+1) begin : init_cnt_c
            always @(posedge clk) begin
                if (!rst &&
                    uut.gen_spike_forwarder_4[gd].gen_neuron_cluster[cd]
                        .neuron_cluster_inst.load_data) begin
                    clu_init_cnt[gd*4+cd] = clu_init_cnt[gd*4+cd] + 1;
                end
            end
        end
    end
endgenerate

// ── Inference: accumulate spikes per cluster when accelerator_done rises ────
integer clu_spike_cnt [0:31];  // reset each sample
reg     capture_spikes;        // 1-cycle pulse on rising edge of accelerator_done
reg     prev_acc_done;

// Rising-edge detection for accelerator_done
always @(posedge clk) begin
    if (rst) begin
        prev_acc_done  <= 0;
        capture_spikes <= 0;
    end else begin
        capture_spikes <= accelerator_done && !prev_acc_done && start_inf;
        prev_acc_done  <= accelerator_done;
    end
end

// Accumulate spikes for all 32 clusters in a flat loop
// (variable part-select [idx*32 +: 32] is legal Verilog-2001)
integer sp_ci;
always @(posedge clk) begin
    if (capture_spikes) begin
        for (sp_ci = 0; sp_ci < 32; sp_ci = sp_ci + 1)
            clu_spike_cnt[sp_ci] = clu_spike_cnt[sp_ci] +
                $countones(uut.all_spikes[sp_ci*32 +: 32]);
    end
end

// Per-sample total spike count used for verdict
integer sample_total_spikes;

// Output-packet counter (packets leaving the accelerator via main_fifo_out)
integer out_pkt_cnt;
integer out_pkt_per_sample;

// ============================================================================
// 6.  SHARED MEMORY
// ============================================================================
localparam SMEM_BASE  = 32'h2000_0000;
localparam SMEM_DEPTH = 49152;

snn_shared_memory_wb #(.MEM_DEPTH(SMEM_DEPTH), .BASE_ADDR(SMEM_BASE)) shared_mem (
    .clk(clk), .rst(rst),
    .wb_adr_i(wb_adr_i), .wb_dat_i(wb_dat_i), .wb_dat_o(wb_dat_o),
    .wb_sel_i(wb_sel_i), .wb_we_i(wb_we_i), .wb_stb_i(wb_stb_i),
    .wb_cyc_i(wb_cyc_i), .wb_ack_o(wb_ack_o),
    .portb_addr(portb_addr[14:2]), .portb_din(portb_din),
    .portb_dout(portb_dout), .portb_we(portb_we), .portb_en(portb_en),
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
    .network_mode(network_mode),  .time_step(time_step),
    .load_data_in(load_data_in),  .rst_potential(rst_potential),
    .data_in(data_in),            .ready_in(ready_in),
    .data_out(data_out),          .load_data_out(load_data_out),
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
    .portb_addr(portb_addr), .portb_din(portb_din),
    .portb_we(portb_we),     .portb_en(portb_en),
    .vmem_base_addr(16'hA000), .spike_base_addr(16'hB000),
    .current_timestep(ts_idx[3:0])
);

always #5 clk = ~clk;
assign main_fifo_rd_en_out = ~main_fifo_empty_out;

// ============================================================================
// 8.  OUTPUT-PACKET MONITOR
//     Packets that leave the spike network back out to main_fifo_out come
//     from output-layer clusters routing spikes upstream.
// ============================================================================
always @(posedge clk) begin
    if (!rst && uut.main_fifo_wr_en_out && start_inf) begin
        $display("[%0t] [OUT-PKT] sample=%0d ts=%0d  packet=0x%03X  (src_cluster=%0d  neuron=%0d)",
                 $time, sample_idx, ts_idx,
                 uut.main_fifo_din_out,
                 uut.main_fifo_din_out[10:5],
                 uut.main_fifo_din_out[4:0]);
        out_pkt_cnt        = out_pkt_cnt + 1;
        out_pkt_per_sample = out_pkt_per_sample + 1;
    end
end

// ============================================================================
// 9.  SPIKE CAPTURE VERBOSE LOGGER
//     Every time accelerator_done rises during inference, log which clusters
//     fired (so we can see it per time-step, not just per sample).
// ============================================================================
integer log_ci;
always @(posedge clk) begin
    if (capture_spikes) begin
        $display("[%0t] [SPIKE-CAPTURE] sample=%0d ts=%0d  accelerator_done rose",
                 $time, sample_idx, ts_idx);
        for (log_ci = 0; log_ci < 32; log_ci = log_ci + 1) begin
            if (|uut.all_spikes[log_ci*32 +: 32])
                $display("         CLU_%0d fired: %032b  (%0d neurons fired)",
                         log_ci,
                         uut.all_spikes[log_ci*32 +: 32],
                         $countones(uut.all_spikes[log_ci*32 +: 32]));
        end
    end
end

// ============================================================================
// 10.  TASKS
// ============================================================================

// ── print_init_summary ───────────────────────────────────────────────────────
task print_init_summary;
    integer pi, total_init;
    begin
        total_init = 0;
        $display("");
        $display("============================================================");
        $display("PHASE 1 — INIT DELIVERY SUMMARY");
        $display("  Cluster       load_data pulses received");
        $display("------------------------------------------------------------");
        for (pi = 0; pi < 32; pi = pi + 1) begin
            if (clu_init_cnt[pi] == 0)
                $display("  CLU_%0d [grp=%0d slot=%0d]  [!!! 0 bytes — NOT INITIALISED !!!]",
                         pi, pi/4, pi%4);
            else begin
                $display("  CLU_%0d [grp=%0d slot=%0d]  %0d bytes",
                         pi, pi/4, pi%4, clu_init_cnt[pi]);
                total_init = total_init + clu_init_cnt[pi];
            end
        end
        $display("------------------------------------------------------------");
        $display("  Total bytes delivered to clusters: %0d", total_init);
        if (total_init == 0)
            $display("  [!!!] ZERO bytes reached any cluster — init routing is broken");
        $display("============================================================");
        $display("");
    end
endtask

// ── print_sample_result ──────────────────────────────────────────────────────
//   Prints all cluster activity and decides class by checking OUTPUT_CLUSTER_ID.
task print_sample_result;
    input [31:0] sample;
    input [31:0] expected_class;
    output [31:0] predicted_class;
    integer sc, total_fired;
    begin
        $display("");
        $display("============================================================");
        $display("SAMPLE %0d  input=(%0d,%0d)  expected_class=%0d",
                 sample,
                 (sample==1 || sample==3) ? 1 : 0,   // A bit
                 (sample==2 || sample==3) ? 1 : 0,   // B bit
                 expected_class);
        $display("  Output packets that exited accelerator this sample: %0d", out_pkt_per_sample);
        $display("  Cluster spike table (non-zero clusters only):");
        total_fired = 0;
        for (sc = 0; sc < 32; sc = sc + 1) begin
            if (clu_spike_cnt[sc] > 0) begin
                if (sc == OUTPUT_CLUSTER_ID)
                    $display("    CLU_%0d  [OUTPUT]  total_spikes=%0d ← decision cluster",
                             sc, clu_spike_cnt[sc]);
                else
                    $display("    CLU_%0d  [hidden]  total_spikes=%0d",
                             sc, clu_spike_cnt[sc]);
                total_fired = total_fired + clu_spike_cnt[sc];
            end
        end
        if (total_fired == 0)
            $display("    (no cluster fired — consistent with zero input spikes)");
        // Decision: output cluster fires at all → class 1, else class 0
        if (clu_spike_cnt[OUTPUT_CLUSTER_ID] > 0)
            predicted_class = 1;
        else
            predicted_class = 0;
        $display("  Predicted class: %0d  (CLU_%0d fired %0d spikes)",
                 predicted_class, OUTPUT_CLUSTER_ID, clu_spike_cnt[OUTPUT_CLUSTER_ID]);
        $display("  Expected  class: %0d  → %s",
                 expected_class,
                 (predicted_class == expected_class) ? "PASS ✓" : "FAIL ✗");
        $display("============================================================");
        $display("");
    end
endtask

// ── print_xor_verdict ────────────────────────────────────────────────────────
task print_xor_verdict;
    input [31:0] p00, p10, p01, p11;   // predicted class (0 or 1) per sample
    integer pass_cnt;
    begin
        pass_cnt = 0;
        $display("====================================================");
        $display("XOR INFERENCE VERDICT");
        $display("  (Decision: CLU_%0d fires → class 1, silent → class 0)",
                 OUTPUT_CLUSTER_ID);
        $display("----------------------------------------------------");
        $display("  Input(0,0) pred=%0d expect=0  %s", p00, (p00==0) ? "PASS" : "FAIL");
        $display("  Input(1,0) pred=%0d expect=1  %s", p10, (p10==1) ? "PASS" : "FAIL");
        $display("  Input(0,1) pred=%0d expect=1  %s", p01, (p01==1) ? "PASS" : "FAIL");
        $display("  Input(1,1) pred=%0d expect=0  %s", p11, (p11==0) ? "PASS" : "FAIL");
        if (p00==0) pass_cnt = pass_cnt + 1;
        if (p10==1) pass_cnt = pass_cnt + 1;
        if (p01==1) pass_cnt = pass_cnt + 1;
        if (p11==0) pass_cnt = pass_cnt + 1;
        $display("----------------------------------------------------");
        $display("  Score: %0d / 4", pass_cnt);
        if      (pass_cnt == 4) $display("  >>> OVERALL PASS — XOR inference is CORRECT <<<");
        else if (pass_cnt == 3) $display("  >>> 3/4 correct — hardware works, check weight tuning for the failing case");
        else                    $display("  >>> %0d/4 — significant inference errors", pass_cnt);
        $display("====================================================");
    end
endtask

// ============================================================================
// 11.  WATCHDOG
// ============================================================================
initial begin
    #(TIMEOUT_CYCLES * 10);
    $display("[%0t] **** WATCHDOG — sim stopped after %0d cycles ****",
             $time, TIMEOUT_CYCLES);
    print_init_summary;
    $finish;
end

// ============================================================================
// 12.  INIT FSM
// ============================================================================
always @(posedge clk) begin
    if (start_init) begin
        if (init_mem[init_index] !== 8'bx) begin
            if (ready_in && !load_data_in) begin
                data_in      <= init_mem[init_index];
                load_data_in <= 1;
                init_index   <= init_index + 1;
            end else
                load_data_in <= 0;
        end else begin
            load_data_in <= 0;
            if (ready_in && !load_data_in) begin
                network_mode <= 0;
                start_init   <= 0;
                init_done    <= 1;
                $display("[%0t] [INIT] Complete: %0d bytes sent", $time, init_index);
            end
        end
    end else begin
        load_data_in <= 0;
        if (init_done && accelerator_done) begin
            $display("[%0t] [INIT] Accelerator ready → starting inference", $time);
            print_init_summary;
            start_inf  <= 1;
            inf_state  <= S_INJECT;
            init_done  <= 0;
        end
    end
end

// ============================================================================
// 13.  INFERENCE FSM
// ============================================================================
wire [31:0] spike_mem_addr;
assign spike_mem_addr = in_neuron_idx
                      + ts_idx          * N_INPUT_NEURONS
                      + sample_idx      * N_TS * N_INPUT_NEURONS;

// Predicted cluster per sample (filled in by print_sample_result task)
reg [31:0] pred_clu [0:3];

// Keep track of per-ts accelerator_done state for this sample
integer done_count_this_ts;

always @(posedge clk) begin
    if (time_step)     time_step     <= 0;
    if (rst_potential) rst_potential <= 0;
    main_fifo_wr_en_in <= 0;

    if (start_inf) begin
        case (inf_state)

            // ─────────────────────────────────────────────────────────────
            // S_INJECT: load spikes for this time-step into main_fifo
            // ─────────────────────────────────────────────────────────────
            S_INJECT: begin
                if (in_neuron_idx < N_INPUT_NEURONS) begin
                    if (spike_mem[spike_mem_addr] !== 11'h7FF) begin
                        if (!main_fifo_full_in) begin
                            main_fifo_din_in   <= spike_mem[spike_mem_addr];
                            main_fifo_wr_en_in <= 1;
                        end else
                            $display("[%0t] [WARN] FIFO FULL sample=%0d ts=%0d",
                                     $time, sample_idx, ts_idx);
                    end
                    in_neuron_idx <= in_neuron_idx + 1;
                end else begin
                    in_neuron_idx <= 0;
                    settle_ctr    <= 0;
                    inf_state     <= S_SETTLE;
                end
            end

            // ─────────────────────────────────────────────────────────────
            // S_SETTLE: small pre-fire settle
            // ─────────────────────────────────────────────────────────────
            S_SETTLE: begin
                if (settle_ctr >= SETTLE_PRE) begin
                    settle_ctr <= 0;
                    inf_state  <= S_FIRE;
                end else
                    settle_ctr <= settle_ctr + 1;
            end

            // ─────────────────────────────────────────────────────────────
            // S_FIRE: pulse time_step then wait for accelerator_done
            // ─────────────────────────────────────────────────────────────
            S_FIRE: begin
                $display("[%0t] [FIRE] time_step pulse → sample=%0d ts=%0d",
                         $time, sample_idx, ts_idx);
                time_step  <= 1;
                settle_ctr <= 0;
                inf_state  <= S_WAIT_DONE;
            end

            // ─────────────────────────────────────────────────────────────
            // S_WAIT_DONE: wait for accelerator_done (or timeout)
            // ─────────────────────────────────────────────────────────────
            S_WAIT_DONE: begin
                if (accelerator_done) begin
                    // Spike capture happens in the separate always block above.
                    // Move on.
                    settle_ctr <= 0;
                    inf_state  <= S_NEXT_TS;
                end else if (settle_ctr >= SETTLE_POST) begin
                    $display("[%0t] [WARN] accelerator_done never rose after time_step! sample=%0d ts=%0d",
                             $time, sample_idx, ts_idx);
                    $display("       all_clusters_done=%b  all_forwarders=%b  main_empty_in=%b  main_empty_out=%b",
                             uut.dbg_all_clusters_done, uut.all_forwarders_done,
                             uut.main_fifo_empty_in,    uut.main_fifo_empty_out);
                    settle_ctr <= 0;
                    inf_state  <= S_NEXT_TS;
                end else
                    settle_ctr <= settle_ctr + 1;
            end

            // ─────────────────────────────────────────────────────────────
            // S_NEXT_TS: advance time-step counter or wrap up sample
            // ─────────────────────────────────────────────────────────────
            S_NEXT_TS: begin
                if (ts_idx + 1 < N_TS) begin
                    ts_idx    <= ts_idx + 1;
                    inf_state <= S_INJECT;
                end else begin
                    inf_state <= S_DONE_SMPL;
                end
            end

            // ─────────────────────────────────────────────────────────────
            // S_DONE_SMPL: print result, reset for next sample
            // ─────────────────────────────────────────────────────────────
            S_DONE_SMPL: begin
                // Print and get predicted cluster
                // (blocking task call — fine in simulation)
                begin : call_result
                    reg [31:0] pred;
                    // XOR expected: 0→0, 1→1, 2→1, 3→0
                    reg [31:0] expected;
                    expected = (sample_idx==0 || sample_idx==3) ? 0 : 1;
                    print_sample_result(sample_idx, expected, pred);
                    pred_clu[sample_idx] = pred;
                end

                // Reset per-sample counters
                begin : reset_sp
                    integer ri;
                    for (ri = 0; ri < 32; ri = ri + 1)
                        clu_spike_cnt[ri] = 0;
                    out_pkt_per_sample = 0;
                end

                ts_idx        <= 0;
                sample_idx    <= sample_idx + 1;
                rst_potential <= 1;
                start_inf     <= 0;
                settle_ctr    <= 0;
                inf_state     <= S_INJECT;
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
            if (sample_idx < N_SAMPLES) begin
                start_inf <= 1;
                inf_state <= S_INJECT;
            end
        end
    end
end

// ============================================================================
// 14.  TERMINATION  — print XOR verdict after all samples done
// ============================================================================
always @(posedge clk) begin
    if (sample_idx >= N_SAMPLES && !start_inf && !rearm_pending) begin
        repeat(200) @(posedge clk);

        $display("");
        $display("============================================================");
        $display("FINAL SUMMARY");
        $display("  Total output packets exit accelerator: %0d", out_pkt_cnt);
        $display("");

        // Print XOR verdict using the per-sample predicted clusters
        print_xor_verdict(pred_clu[0], pred_clu[1], pred_clu[2], pred_clu[3]);

        $finish;
    end
end

// ============================================================================
// 15.  INITIALISATION
// ============================================================================
initial begin
    integer k;

    $display("============================================================");
    $display(" INIT + INFERENCE DEBUG TESTBENCH");
    $display("   Check 1: Does data_mem init reach every cluster?");
    $display("   Check 2: Do neurons fire for the XOR inputs?");
    $display("   Check 3: Is the XOR result correct?");
    $display("============================================================");

    clk = 0; rst = 1;
    network_mode = 0; load_data_in = 0;
    rst_potential = 0; data_in = 0; ready_out = 0;
    main_fifo_din_in = 0; main_fifo_wr_en_in = 0; time_step = 0;
    start_init = 0; init_done = 0; init_index = 0;
    start_inf  = 0; sample_idx = 0; ts_idx = 0; in_neuron_idx = 0;
    inf_state  = S_INJECT; settle_ctr = 0; rearm_pending = 0;
    out_pkt_cnt = 0; out_pkt_per_sample = 0;
    sample_total_spikes = 0;

    for (k = 0; k < 32; k = k + 1) begin
        clu_init_cnt[k]  = 0;
        clu_spike_cnt[k] = 0;
        pred_clu[k]      = 32'hFFFF_FFFF;
    end

    $readmemh("data_mem.mem",  init_mem);
    $readmemh("spike_mem.mem", spike_mem);

    #20 rst = 0;
    network_mode = 1;   // config mode
    start_init   = 1;
    $display("[%0t] Reset released — init phase started", $time);
end

endmodule
