// ============================================================================
// mnist_infertest_tb.v  —  MNIST inference testbench with PASS/FAIL report
// ============================================================================
//
// ╔══════════════════════════════════════════════════════════════════════════╗
// ║          USER CONFIGURATION — CHANGE ONLY THIS BLOCK                   ║
// ╠══════════════════════════════════════════════════════════════════════════╣
// ║                                                                          ║
// ║  Uncomment ONE of the three options below:                               ║
// ║                                                                          ║
// ║  Option A — Python software-trained model (the reference):               ║
// ║    File  : data_mem.mem           (56,855 bytes)                         ║
// ║    Model : 784 → 16 → 10  LIF2 β=0.5  threshold=1.0                    ║
// ║    Output cluster : 1   Expected accuracy : ~90%+                        ║
// ║                                                                          ║
// ║  Option B — C-code trained (hardware-matched, LIF24, 200 hidden):        ║
// ║    File  : data_mem_mnist_new.mem (678,230 bytes)                        ║
// ║    Model : 784 → 200 → 10  LIF24 β=0.75  threshold auto-scaled          ║
// ║    Output cluster : 2   Expected accuracy : TBD (pipeline under test)    ║
// ║    NOTE: spike_mem was generated for LIF2 model — mismatch may reduce    ║
// ║          accuracy; generate a fresh spike_mem with the same encoding     ║
// ║          as backpropD_hw.C (raw-pixel Poisson) to get best results.      ║
// ║                                                                          ║
// ║  Option C — C-code trained model MATCHING Python encoding (recommended): ║
// ║    File  : data_mem_pymatched.mem (generate with backprop_pymatched.C)   ║
// ║    Model : 784 → 16 → 10  LIF2 β=0.5  threshold=1.0                    ║
// ║    Output cluster : 1   Expected accuracy : ~90%+ (same as Option A)     ║
// ║    PURPOSE: validates the C→data_mem pipeline is correct.                ║
// ║    If this matches Option A accuracy, the pipeline is confirmed good.     ║
// ║                                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// ─── SELECT ONE  (comment out the other two) ─────────────────────────────────
//`define WEIGHT_SOURCE_PYTHON          // Option A: Python model (reference)
`define WEIGHT_SOURCE_C_CODE        // Option B: C-code LIF24 200-hidden
//`define WEIGHT_SOURCE_C_PYMATCHED   // Option C: C-code LIF2  16-hidden (validates pipeline)
// ─────────────────────────────────────────────────────────────────────────────

// Auto-derived settings — DO NOT EDIT below (changes automatically with above)
`ifdef WEIGHT_SOURCE_PYTHON
  `define DATA_MEM_FILE     "data_mem.mem"
  `define N_HIDDEN_VAL      16
  `define OUTPUT_CLU_VAL    1
`elsif WEIGHT_SOURCE_C_CODE
  `define DATA_MEM_FILE     "data_mem_mnist_new.mem"
  `define N_HIDDEN_VAL      200
  `define OUTPUT_CLU_VAL    2
`elsif WEIGHT_SOURCE_C_PYMATCHED
  `define DATA_MEM_FILE     "data_mem_pymatched.mem"
  `define N_HIDDEN_VAL      16
  `define OUTPUT_CLU_VAL    1
`else
  // Fallback: treat as Python model
  `define DATA_MEM_FILE     "data_mem.mem"
  `define N_HIDDEN_VAL      16
  `define OUTPUT_CLU_VAL    1
`endif

// ============================================================================
// COMPILE (VCS on neumann):
//   cd inference_accelarator/neuron_accelerator
//   vcs -full64 -sverilog -debug_access+all +v2k mnist_infertest_tb.v \
//       -o simv_mnist_inf
//
// RUN (first 10 samples — quick accuracy check):
//   ./simv_mnist_inf +input_count=10
//
// RUN (all 320 samples — full accuracy report):
//   ./simv_mnist_inf
// ============================================================================

`include "neuron_accelerator.v"
`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns / 100ps

module mnist_infertest_tb;

// ============================================================================
// 1.  PARAMETERS  (auto-set by WEIGHT_SOURCE define above)
// ============================================================================
parameter PACKET_W         = 11;
parameter MAIN_FIFO_D      = 32;
parameter FWD8_FIFO_D      = 16;
parameter FWD4_FIFO_D      = 8;

// number_of_clusters MUST be 64 (not 32) — needed for 6-bit virtual cluster IDs
parameter N_CLUSTERS       = 64;
parameter NEURONS_PER_CLU  = 32;
parameter INC_WEIGHT_ROWS  = 1024;
parameter MAX_WEIGHT_ROWS  = 4096;
parameter FLIT_SZ          = 8;
parameter CLU_GROUPS       = 8;

// MNIST test set dimensions (same for all weight sources)
parameter N_SAMPLES        = 320;   // samples in spike_mem_mnist.mem / test_labels.txt
parameter N_TS             = 16;    // timesteps per sample
parameter N_INPUT_NEURONS  = 784;   // input neurons (28×28)
parameter N_LAYERS         = 2;     // propagation fires after last timestep

// ── Architecture — driven by WEIGHT_SOURCE define ────────────────────────────
// N_HIDDEN_DUMP : how many hidden neuron spikes to dump to hw_activations.csv
// OUTPUT_CLU_IDX: physical cluster ID of the output layer (Neuron_Mapper result)
//   Python model  (16 hidden) → OUTPUT_CLU_IDX = 1
//   C-code model (200 hidden) → OUTPUT_CLU_IDX = 2
parameter N_HIDDEN_DUMP    = `N_HIDDEN_VAL;   // set by `define above
parameter OUTPUT_CLU_IDX   = `OUTPUT_CLU_VAL; // set by `define above
parameter OUTPUT_NEURONS   = 10;

// ── Shared memory dump layout ───────────────────────────────────────────
// All neurons (input, hidden, output) are LIF in this architecture.
// Hardware accelerator only has physical clusters for hidden+output;
// input vmem must be reconstructed by the CPU from input spikes.
// The dump stores enough for CPU-side BPTT:
//   Input spikes  : 0x9000 region  (CPU reconstructs input vmem from these)
//   Hidden+output vmem : 0xA000 region  (from accelerator all_pre_spike)
//   Hidden+output spikes : 0xB000 region  (from accelerator all_spikes)
parameter N_ACTIVE_NEURONS    = N_HIDDEN_DUMP + OUTPUT_NEURONS;  // hidden+output for vmem dump
parameter SPIKE_WORDS_PER_TS  = (N_ACTIVE_NEURONS + 31) / 32;   // hidden+output spike words
parameter INPUT_SPK_WORDS_PER_TS = (N_INPUT_NEURONS + 31) / 32; // input spike words (25 for 784)

// Watchdog: 200M cycles (covers 678KB init + 200-hidden inference per sample)
parameter TIMEOUT_CYCLES   = 200000000;

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
reg  [3:0]  wb_sel_i = 4'hF;
reg  wb_we_i=0, wb_stb_i=0, wb_cyc_i=0;
wire wb_ack_o;

// ── Per-sample memory base addresses (calculated dynamically) ─────────────────
// Each sample N gets memory region starting at: N * WORDS_PER_SAMPLE
// Within region: input_base=0, vmem_base=input_words*4, spike_base=vmem_words*4
reg [31:0] sample_mem_offset;
reg [15:0] sample_input_base, sample_vmem_base, sample_spike_base;

// ============================================================================
// 3.  MEMORY ARRAYS
// ============================================================================
// init_mem: holds weight packets loaded from DATA_MEM_FILE.
//   700001 slots covers both Python (56,855) and C-code (678,230) models.
reg [7:0]  init_mem  [0:700000];
// spike_mem: 320 × 16 × 784 = 4,014,080         entries (11-bit spike packets)
reg [10:0] spike_mem [0:4100000];
// test_labels: one digit label per sample
reg [7:0]  true_labels [0:N_SAMPLES-1];

// ============================================================================
// 3b. CONTROL REGISTERS  (declared early so DUT port and snoop blocks can use them)
// ============================================================================
reg start_init, init_done, start_inf;
reg [31:0] init_index;
reg [31:0] in_neuron_idx;
reg [31:0] ts_idx;
reg [31:0] sample_idx;
reg        rearm_pending;
integer    runtime_input_count;

// Inference FSM states
localparam S_IDLE       = 3'd0;
localparam S_INJECT     = 3'd1;
localparam S_FIRE       = 3'd2;
localparam S_WAIT_DONE  = 3'd3;   // wait for accelerator_done LOW→HIGH
localparam S_PROPAGATE  = 3'd4;   // extra time_step for hidden→output
localparam S_DONE_PRINT = 3'd5;   // print result, reset, next sample

reg [2:0]  inf_state;
reg [3:0]  prop_fire_cnt;
reg        saw_done_low;    // set once accel_done goes LOW after a FIRE
reg        done_latch_pend; // set on accel_done rising; read all_spikes next cycle

// Accuracy counters
integer total_correct;
integer total_unclassified;
integer correct_per_digit [0:OUTPUT_NEURONS-1];
integer total_per_digit   [0:OUTPUT_NEURONS-1];

// Activation dump to hw_activations.txt
integer hw_act_fd;
reg [4:0] dump_ts_cnt;    // counts done_latch_pend events per sample

// Per-digit spike accumulator for the current sample
reg [31:0] digit_spike_cnt [0:OUTPUT_NEURONS-1];

// ============================================================================
// 4.  SHARED MEMORY
// ============================================================================
localparam SMEM_WB_BASE = 32'h2000_0000;
// Expanded to hold all 320 samples: 320 samples × 1360 words/sample = 435,200 words minimum
// Using 512K (524,288 words) for power-of-2 alignment
localparam SMEM_DEPTH   = 524288;  // Expanded from 49152 to hold all samples
// Words per sample = N_TS × (input_words + vmem_words + spike_words)
localparam WORDS_PER_SAMPLE = (((N_INPUT_NEURONS + 31) / 32) + ((N_ACTIVE_NEURONS + 3) / 4) + ((N_ACTIVE_NEURONS + 31) / 32)) * N_TS;

// ── Shared memory snapshot for CPU testbench (full 320-sample dump) ────────
// After all 320 inference samples complete, writes smem_snapshot.mem
// containing FULL vmem/spikes dump in per-sample layout loadable by $readmemh.
// All neurons (input, hidden, output) are LIF. Per-sample layout:
//   Sample N offset = N * WORDS_PER_SAMPLE
//   Within each sample, per-timestep:
//     Input spikes:  word[offset + ts*INPUT_SPK_WPT + w]  — 32 input spike bits packed
//     V_mem:         word[offset + ts*N_ACTIVE + n]        — 8-bit LUT index (hidden+output)
//     HO spikes:     word[offset + ts*SPIKE_WPT + w]       — 32 spike bits packed (hidden+output)
// CPU reconstructs input vmem from input spikes using LIF dynamics.
reg [31:0] smem_image [0:SMEM_DEPTH-1];
integer dump_target_sample;
integer smem_snap_fd;

// Per-timestep input spike buffer (captured during S_INJECT)
reg [N_INPUT_NEURONS-1:0] ts_input_spikes;

snn_shared_memory_wb #(
    .MEM_DEPTH(SMEM_DEPTH),
    .BASE_ADDR(SMEM_WB_BASE)
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
// 5.  DUT
// ============================================================================
neuron_accelerator #(
    .packet_width(PACKET_W),
    .main_fifo_depth(MAIN_FIFO_D),
    .forwarder_8_fifo_depth(FWD8_FIFO_D),
    .forwarder_4_fifo_depth(FWD4_FIFO_D),
    .number_of_clusters(N_CLUSTERS),
    .neurons_per_cluster(NEURONS_PER_CLU),
    .incoming_weight_table_rows(INC_WEIGHT_ROWS),
    .max_weight_table_rows(MAX_WEIGHT_ROWS),
    .cluster_group_count(CLU_GROUPS),
    .flit_size(FLIT_SZ)
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
    .vmem_base_addr(sample_vmem_base),      // Dynamic per-sample base address
    .spike_base_addr(sample_spike_base),    // Dynamic per-sample base address
    .current_timestep(ts_idx[3:0])
);

// ============================================================================
// 6.  CLOCK
// ============================================================================
always #5 clk = ~clk;

// Drain output FIFO continuously so accelerator_done can assert
assign main_fifo_rd_en_out = ~main_fifo_empty_out;

// ============================================================================
// 7.  SPIKE CAPTURE — done inside the inference FSM (section 14) so that
//     the one-cycle latch delay is respected and all-cluster diagnostics
//     can be printed in the same pass.  No separate always block needed.
// ============================================================================

// ============================================================================
// 8.  (declarations moved to section 3b above)
// 9.

// ============================================================================
// 10.  PRINT TASKS
// ============================================================================

// ── print_sample_result ──────────────────────────────────────────────────────
//   Shows per-digit spike counts, predicted digit, true label, PASS/FAIL.
task print_sample_result;
    input [31:0] sample;
    input [7:0]  true_lbl;
    integer d, max_cnt, pred_digit, total_out_spikes;
    begin
        // Find predicted digit = argmax over digit_spike_cnt
        max_cnt         = 0;
        pred_digit      = -1;
        total_out_spikes = 0;
        for (d = 0; d < OUTPUT_NEURONS; d = d + 1) begin
            total_out_spikes = total_out_spikes + digit_spike_cnt[d];
            if (digit_spike_cnt[d] > max_cnt) begin
                max_cnt    = digit_spike_cnt[d];
                pred_digit = d;
            end
        end

        $display("============================================================");
        $display("SAMPLE %4d  |  true=%0d  |  pred=%0d  |  %s",
                 sample, true_lbl,
                 (pred_digit == -1) ? 10 : pred_digit,
                 (pred_digit == -1)     ? "UNCLASSIFIED" :
                 (pred_digit == true_lbl) ? "PASS" : "FAIL");
        $write("  spikes:");
        for (d = 0; d < OUTPUT_NEURONS; d = d + 1)
            $write(" %0d:%0d", d, digit_spike_cnt[d]);
        $display("");
        $display("============================================================");

        // Update accuracy counters
        total_per_digit[true_lbl] = total_per_digit[true_lbl] + 1;
        if (pred_digit == -1) begin
            total_unclassified = total_unclassified + 1;
        end else if (pred_digit == true_lbl) begin
            total_correct               = total_correct + 1;
            correct_per_digit[true_lbl] = correct_per_digit[true_lbl] + 1;
        end
    end
endtask

// ── print_accuracy_report ────────────────────────────────────────────────────
task print_accuracy_report;
    integer d, denom;
    begin
        denom = runtime_input_count;
        $display("");
        $display("====================================================");
        $display("  MNIST INFERENCE ACCURACY REPORT");
        $display("====================================================");
        $display("  Samples evaluated  : %4d", denom);
        $display("  Correct            : %4d", total_correct);
        $display("  Unclassified       : %4d", total_unclassified);
        if (denom > 0)
            $display("  Accuracy           : %0d.%02d%%",
                     (total_correct * 10000 / denom) / 100,
                     (total_correct * 10000 / denom) % 100);
        $display("----------------------------------------------------");
        $display("  Digit  Correct   Total   Acc%%");
        $display("  -----  -------   -----   ----");
        for (d = 0; d < OUTPUT_NEURONS; d = d + 1) begin
            if (total_per_digit[d] > 0)
                $display("    %0d      %3d      %3d     %0d.%01d%%",
                         d,
                         correct_per_digit[d],
                         total_per_digit[d],
                         (correct_per_digit[d] * 1000 / total_per_digit[d]) / 10,
                         (correct_per_digit[d] * 1000 / total_per_digit[d]) % 10);
            else
                $display("    %0d      ---      ---      N/A", d);
        end
        $display("====================================================");
    end
endtask

// ============================================================================
// 11.  INITIALISATION
// ============================================================================
initial begin
    if (!$value$plusargs("input_count=%d", runtime_input_count))
        runtime_input_count = N_SAMPLES;
    if (runtime_input_count > N_SAMPLES)
        runtime_input_count = N_SAMPLES;

    $display("============================================================");
    $display("  MNIST INFERENCE TESTBENCH");
    $display("  Weight source file = %s", `DATA_MEM_FILE);
    $display("  Hidden neurons     = %0d", N_HIDDEN_DUMP);
    $display("  Output cluster     = %0d", OUTPUT_CLU_IDX);
    $display("  number_of_clusters = %0d", N_CLUSTERS);
    $display("  Samples to run     = %0d / %0d", runtime_input_count, N_SAMPLES);
    $display("  Timestep window    = %0d", N_TS);
    $display("  Input neurons      = %0d", N_INPUT_NEURONS);
    $display("============================================================");

    clk = 0; rst = 1;
    network_mode = 0; load_data_in = 0;
    rst_potential = 0; data_in = 0; ready_out = 0;
    main_fifo_din_in = 0; main_fifo_wr_en_in = 0;
    time_step = 0;
    start_init = 0; init_done = 0; init_index = 0;
    start_inf = 0; rearm_pending = 0;
    in_neuron_idx = 0; ts_idx = 0; sample_idx = 0;
    inf_state = S_IDLE; prop_fire_cnt = 0;
    saw_done_low = 0; done_latch_pend = 0;
    total_correct = 0; total_unclassified = 0;
    ts_input_spikes = {N_INPUT_NEURONS{1'b0}};

    begin : init_counters
        integer ci;
        for (ci = 0; ci < OUTPUT_NEURONS; ci = ci + 1) begin
            digit_spike_cnt[ci]   = 0;
            correct_per_digit[ci] = 0;
            total_per_digit[ci]   = 0;
        end
    end

    // ── Initialize shared memory snapshot ──
    if (!$value$plusargs("dump_sample=%d", dump_target_sample))
        dump_target_sample = 0;
    begin : init_smem_img
        integer si;
        for (si = 0; si < SMEM_DEPTH; si = si + 1)
            smem_image[si] = 32'h0;
    end

    $readmemh(`DATA_MEM_FILE,  init_mem);
    $readmemh("spike_mem_mnist.mem", spike_mem);
    $readmemh("test_labels.txt",     true_labels);

    // Open activation dump file (CSV format)
    // Dump formatted like smem outputs for ML analysis
    hw_act_fd = $fopen("smem_all_samples.csv", "w");
    dump_ts_cnt = 0;
    begin : write_csv_header
        integer ci;
        $fwrite(hw_act_fd, "sample,ts");
        for (ci = 0; ci < N_INPUT_NEURONS; ci = ci + 1)
            $fwrite(hw_act_fd, ",inp_%0d", ci);
        for (ci = 0; ci < N_HIDDEN_DUMP; ci = ci + 1)
            $fwrite(hw_act_fd, ",spike_h%0d", ci);
        for (ci = 0; ci < OUTPUT_NEURONS; ci = ci + 1)
            $fwrite(hw_act_fd, ",spike_o%0d", ci);
        for (ci = 0; ci < N_HIDDEN_DUMP; ci = ci + 1)
            $fwrite(hw_act_fd, ",vmem_h%0d", ci);
        for (ci = 0; ci < OUTPUT_NEURONS; ci = ci + 1)
            $fwrite(hw_act_fd, ",vmem_o%0d", ci);
        $fdisplay(hw_act_fd, "");
    end

    #100 rst = 0;
    network_mode = 1;
    start_init   = 1;
    $display("[%0t] Reset released — init phase started", $time);
end

// ============================================================================
// 12.  WATCHDOG
// ============================================================================
// Use repeat(@posedge clk) to avoid any ns-multiplication overflow.
initial begin
    repeat(TIMEOUT_CYCLES) @(posedge clk);
    $display("[%0t] **** WATCHDOG — simulation timed out after %0d cycles ****",
             $time, TIMEOUT_CYCLES);
    print_accuracy_report;
    $fflush(hw_act_fd);
    $fclose(hw_act_fd);
    $finish;
end

// ============================================================================
// 13.  INIT FSM  (serial byte-stream loader via data_in interface)
// ============================================================================
always @(posedge clk) begin
    if (start_init) begin
        if (init_mem[init_index] !== 8'bx) begin
            if (ready_in && !load_data_in) begin
                data_in      <= init_mem[init_index];
                load_data_in <= 1;
                init_index   <= init_index + 1;
                if (init_index % 10000 == 0)
                    $display("[%0t] [INIT] byte %0d", $time, init_index);
            end else
                load_data_in <= 0;
        end else begin
            load_data_in <= 0;
            if (ready_in && !load_data_in) begin
                network_mode <= 0;
                start_init   <= 0;
                init_done    <= 1;
                $display("[%0t] [INIT] Complete — %0d bytes sent", $time, init_index);
            end
        end
    end else begin
        load_data_in <= 0;
        if (init_done && accelerator_done) begin
            $display("[%0t] [INIT] Accelerator ready → starting inference", $time);
            start_inf  <= 1;
            inf_state  <= S_INJECT;
            init_done  <= 0;
        end
    end
end

// ============================================================================
// 14.  INFERENCE FSM  — accel_done-based synchronisation
// ============================================================================
wire [31:0] spike_addr;
assign spike_addr = in_neuron_idx
                  + ts_idx        * N_INPUT_NEURONS
                  + sample_idx    * N_TS * N_INPUT_NEURONS;

always @(posedge clk) begin
    if (time_step)     time_step     <= 0;
    if (rst_potential) rst_potential <= 0;
    main_fifo_wr_en_in <= 0;

    if (start_inf) begin
        case (inf_state)

            // ── Inject all input spikes for this timestep ─────────────────
            // Also capture input spikes for shared memory dump (all samples).
            // All neurons including inputs are LIF — input vmem is reconstructed
            // by the CPU from these spike flags using LIF dynamics.
            S_INJECT: begin
                // Calculate per-sample memory offsets on first neuron of first timestep
                if (in_neuron_idx == 0 && ts_idx == 0) begin
                    // Each sample gets WORDS_PER_SAMPLE words of shared memory
                    integer words_per_ts;
                    integer vmem_region_offset, spike_region_offset;
                    
                    words_per_ts = ((N_INPUT_NEURONS + 31) / 32) + 
                                  ((N_ACTIVE_NEURONS + 3) / 4) +
                                  ((N_ACTIVE_NEURONS + 31) / 32);
                    
                    sample_mem_offset = sample_idx * (words_per_ts * N_TS);
                    
                    // Within sample region:
                    // [0 : INPUT_SPK_WORDS_PER_TS*N_TS)        — input spikes
                    // [INPUT_SPK_WORDS_PER_TS*N_TS : ... + N_ACTIVE*N_TS)  — vmem
                    // [... + N_ACTIVE*N_TS : ...)              — spikes
                    vmem_region_offset = sample_mem_offset + (INPUT_SPK_WORDS_PER_TS * N_TS);
                    spike_region_offset = vmem_region_offset + (N_ACTIVE_NEURONS * N_TS);
                    
                    sample_input_base = sample_mem_offset[15:0];
                    sample_vmem_base  = vmem_region_offset[15:0];
                    sample_spike_base = spike_region_offset[15:0];
                end
                
                if (in_neuron_idx < N_INPUT_NEURONS) begin
                    // 0xFFF sentinel truncates to 11'h7FF in 11-bit array → skip
                    if (spike_mem[spike_addr] != 11'h7FF && !main_fifo_full_in) begin
                        main_fifo_din_in   <= spike_mem[spike_addr];
                        main_fifo_wr_en_in <= 1;
                        // Record this neuron spiked (for shared memory dump to ALL samples)
                        ts_input_spikes[in_neuron_idx] <= 1'b1;
                    end
                    in_neuron_idx <= in_neuron_idx + 1;
                end else begin
                    // ── All input spikes injected: store input spikes to smem image for ALL samples ──
                    begin : smem_inp
                        integer iw, ib, inp_addr;
                        reg [31:0] inp_word;
                        for (iw = 0; iw < INPUT_SPK_WORDS_PER_TS; iw = iw + 1) begin
                            inp_word = 32'h0;
                            for (ib = 0; ib < 32; ib = ib + 1) begin
                                if (iw * 32 + ib < N_INPUT_NEURONS)
                                    inp_word[ib] = ts_input_spikes[iw * 32 + ib];
                            end
                            // Use per-sample base address + offset
                            inp_addr = sample_mem_offset + ts_idx * INPUT_SPK_WORDS_PER_TS + iw;
                            if (inp_addr < SMEM_DEPTH)
                                smem_image[inp_addr] = inp_word;
                        end
                        // Do NOT clear ts_input_spikes here! It is needed for CSV dump in S_WAIT_DONE.
                        // It will be cleared after dumping.
                    end
                    in_neuron_idx   <= 0;
                    saw_done_low    <= 0;
                    done_latch_pend <= 0;
                    inf_state       <= S_FIRE;
                end
            end

            // ── Assert time_step for exactly 1 clock ─────────────────────
            S_FIRE: begin
                time_step       <= 1;
                saw_done_low    <= 0;
                done_latch_pend <= 0;
                inf_state       <= S_WAIT_DONE;
            end

            // ── Wait for accelerator_done to cycle LOW → HIGH ─────────────
            // The weight-resolver may take thousands of cycles per timestep
            // for MNIST (25 virtual source clusters × ~128-byte weight rows).
            // We must NOT advance until accel_done goes HIGH — otherwise the
            // next time_step fires before accumulation finishes.
            //
            // Two-phase latch (mirrors internal dump FSM):
            //   Phase 1 (accel_done rising): set done_latch_pend
            //   Phase 2 (next posedge):       read all_spikes (NB assigns settled)
            S_WAIT_DONE: begin
                // Phase 0: track when accel_done goes low (processing started)
                if (!accelerator_done)
                    saw_done_low <= 1;

                // Phase 1: rising edge of accel_done with saw_done_low confirmed
                if (accelerator_done && saw_done_low && !done_latch_pend) begin
                    done_latch_pend <= 1;
                    saw_done_low    <= 0;
                end

                // Phase 2: one cycle after rising edge — all_spikes is stable
                if (done_latch_pend) begin
                    done_latch_pend <= 0;

                    // ── Spike capture: ALL clusters (diagnostic + output) ──
                    begin : cap_all
                        integer ca;
                        for (ca = 0; ca < 32; ca = ca + 1) begin
                            // Detect any spike in clusters 0..31
                            if (|uut.all_spikes[ca*NEURONS_PER_CLU +: NEURONS_PER_CLU]) begin
                                if (sample_idx < 3)   // diagnostic: first 3 samples only
                                    $display("  [SPIKE] sample=%0d ts=%0d  CLU_%0d fired: %b",
                                             sample_idx, ts_idx,
                                             ca, uut.all_spikes[ca*NEURONS_PER_CLU +: NEURONS_PER_CLU]);
                                if (ca == OUTPUT_CLU_IDX) begin
                                    // Accumulate output digit counts
                                    begin : cap_out
                                        integer co;
                                        for (co = 0; co < OUTPUT_NEURONS; co = co + 1) begin
                                            if (uut.all_spikes[OUTPUT_CLU_IDX*NEURONS_PER_CLU + co])
                                                digit_spike_cnt[co] = digit_spike_cnt[co] + 1;
                                        end
                                    end
                                end
                            end
                        end
                    end

                    // ── Dump raw hardware state to smem_all_samples.csv ───
                    // Includes: input spikes, hidden/out spikes, and 8-bit vmem (LUT index)
                    begin : dump_act
                        integer dh;
                        integer h_bit;  // physical bit index for hidden neuron dh
                        $fwrite(hw_act_fd, "%0d,%0d", sample_idx, ts_idx);
                        
                        // Input spikes
                        for (dh = 0; dh < N_INPUT_NEURONS; dh = dh + 1) begin
                            $fwrite(hw_act_fd, ",%b", ts_input_spikes[dh]);
                        end

                        // Hidden spikes — corrected bit index
                        for (dh = 0; dh < N_HIDDEN_DUMP; dh = dh + 1) begin
                            h_bit = dh + (dh/64)*64;
                            $fwrite(hw_act_fd, ",%b", uut.all_spikes[h_bit]);
                        end
                        // Output spikes
                        for (dh = 0; dh < OUTPUT_NEURONS; dh = dh + 1) begin
                            $fwrite(hw_act_fd, ",%b", uut.all_spikes[OUTPUT_CLU_IDX*NEURONS_PER_CLU + dh]);
                        end
                        // Hidden vmem (8-bit LUT index)
                        for (dh = 0; dh < N_HIDDEN_DUMP; dh = dh + 1) begin
                            h_bit = dh + (dh/64)*64;
                            $fwrite(hw_act_fd, ",%0d", uut.all_pre_spike[h_bit*32 + 23 -: 8]);
                        end
                        // Output vmem (8-bit LUT index)
                        for (dh = 0; dh < OUTPUT_NEURONS; dh = dh + 1) begin
                            $fwrite(hw_act_fd, ",%0d", uut.all_pre_spike[(OUTPUT_CLU_IDX*NEURONS_PER_CLU+dh)*32 + 23 -: 8]);
                        end
                        $fdisplay(hw_act_fd, "");
                        dump_ts_cnt <= dump_ts_cnt + 1;
                        
                        // Clear input spikes for the next timestep
                        ts_input_spikes <= {N_INPUT_NEURONS{1'b0}};
                    end

                    // ── Capture vmem/spikes into shared memory image ─────────
                    // Dump vmem and spikes to smem for ALL samples (per-sample offsets)
                    begin : smem_cap
                        integer sn, phys_bit, smem_addr;
                        integer vmem_base_offset, spike_base_offset;
                        reg [31:0] spk_word;
                        reg [7:0] lut_idx_byte;
                        
                        // Calculate vmem base offset within this sample's region
                        // After input spikes region: N_TS * INPUT_SPK_WORDS_PER_TS words
                        vmem_base_offset = sample_mem_offset + (N_TS * INPUT_SPK_WORDS_PER_TS);
                        
                        // Hidden neuron vmem — store ONLY 8-bit LUT index (bits[23:16] of Q16.16)
                        for (sn = 0; sn < N_HIDDEN_DUMP; sn = sn + 1) begin
                            phys_bit  = sn + (sn / 64) * 64;
                            lut_idx_byte = uut.all_pre_spike[phys_bit*32 + 23 -: 8];  // bits[23:16]
                            smem_addr = vmem_base_offset + ts_idx * N_ACTIVE_NEURONS + sn;
                            if (smem_addr < SMEM_DEPTH)
                                smem_image[smem_addr] = {24'h0, lut_idx_byte};  // pad to 32-bit
                        end
                        
                        // Output neuron vmem — store ONLY 8-bit LUT index
                        for (sn = 0; sn < OUTPUT_NEURONS; sn = sn + 1) begin
                            phys_bit  = OUTPUT_CLU_IDX * NEURONS_PER_CLU + sn;
                            lut_idx_byte = uut.all_pre_spike[phys_bit*32 + 23 -: 8];  // bits[23:16]
                            smem_addr = vmem_base_offset + ts_idx * N_ACTIVE_NEURONS + N_HIDDEN_DUMP + sn;
                            if (smem_addr < SMEM_DEPTH)
                                smem_image[smem_addr] = {24'h0, lut_idx_byte};  // pad to 32-bit
                        end
                        
                        // Calculate spike base offset within this sample's region
                        // After vmem region: N_TS * N_ACTIVE_NEURONS words
                        spike_base_offset = vmem_base_offset + (N_TS * N_ACTIVE_NEURONS);
                        
                        // Pack and store spike words for ALL samples
                        begin : smem_spk
                            integer sw, sb, nlin;
                            for (sw = 0; sw < SPIKE_WORDS_PER_TS; sw = sw + 1) begin
                                spk_word = 32'h0;
                                for (sb = 0; sb < 32; sb = sb + 1) begin
                                    nlin = sw * 32 + sb;
                                    if (nlin < N_ACTIVE_NEURONS) begin
                                        if (nlin < N_HIDDEN_DUMP)
                                            phys_bit = nlin + (nlin / 64) * 64;
                                        else
                                            phys_bit = OUTPUT_CLU_IDX * NEURONS_PER_CLU + (nlin - N_HIDDEN_DUMP);
                                        spk_word[sb] = uut.all_spikes[phys_bit];
                                    end
                                end
                                smem_addr = spike_base_offset + ts_idx * SPIKE_WORDS_PER_TS + sw;
                                if (smem_addr < SMEM_DEPTH)
                                    smem_image[smem_addr] = spk_word;
                            end
                        end
                    end

                    // ── Console verification (first 3 samples, last timestep only) ──
                    if (sample_idx < 3 && ts_idx == N_TS-1) begin : verify_vmem
                        integer dv;
                        $write("[VMEM-OUT] s=%0d ts=%0d  vmem(Q28):", sample_idx, ts_idx);
                        for (dv = 0; dv < OUTPUT_NEURONS; dv = dv + 1)
                            $write(" d%0d=%0d", dv,
                                $signed(uut.all_pre_spike[(OUTPUT_CLU_IDX*NEURONS_PER_CLU+dv)*32 +: 32]));
                        $display("");
                        $write("[SPIKE-OUT] s=%0d ts=%0d  spikes:", sample_idx, ts_idx);
                        for (dv = 0; dv < OUTPUT_NEURONS; dv = dv + 1)
                            $write(" d%0d=%b", dv,
                                uut.all_spikes[OUTPUT_CLU_IDX*NEURONS_PER_CLU + dv]);
                        $display("");
                    end

                    // ── Advance FSM ───────────────────────────────────────
                    if (ts_idx + 1 < N_TS) begin
                        // More input timesteps to process
                        ts_idx    <= ts_idx + 1;
                        inf_state <= S_INJECT;
                    end else if (prop_fire_cnt < N_LAYERS - 1) begin
                        // Need hidden→output propagation fire(s)
                        prop_fire_cnt <= prop_fire_cnt + 1;
                        inf_state     <= S_PROPAGATE;
                    end else begin
                        // All timesteps + propagation done
                        inf_state <= S_DONE_PRINT;
                    end
                end
            end

            // ── Extra time_step for hidden→output propagation ─────────────
            S_PROPAGATE: begin
                time_step       <= 1;
                saw_done_low    <= 0;
                done_latch_pend <= 0;
                inf_state       <= S_WAIT_DONE;
            end

            // ── Print result and reset for next sample ────────────────────
            S_DONE_PRINT: begin
                print_sample_result(sample_idx, true_labels[sample_idx]);

                // ── Write shared memory snapshot after ALL samples complete ──────
                // (This is now written at final termination below, not per-sample)


                begin : reset_cnt
                    integer ri;
                    for (ri = 0; ri < OUTPUT_NEURONS; ri = ri + 1)
                        digit_spike_cnt[ri] = 0;
                end

                ts_idx        <= 0;
                prop_fire_cnt <= 0;
                dump_ts_cnt   <= 0;
                sample_idx    <= sample_idx + 1;
                rst_potential <= 1;
                start_inf     <= 0;
                inf_state     <= S_IDLE;
            end

            default: ;
        endcase
    end
end

// ============================================================================
// 15.  RE-ARM for next sample
// ============================================================================
always @(posedge clk) begin
    if (rst) begin
        rearm_pending <= 0;
    end else begin
        if (rst_potential)
            rearm_pending <= 1;
        if (rearm_pending && !start_inf) begin
            rearm_pending <= 0;
            if (sample_idx < runtime_input_count) begin
                start_inf <= 1;
                inf_state <= S_INJECT;
            end
        end
    end
end

// ============================================================================
// 16.  TERMINATION
// ============================================================================
always @(posedge clk) begin
    if (sample_idx >= runtime_input_count && !start_inf && !rearm_pending &&
        inf_state == S_IDLE) begin
        repeat(200) @(posedge clk);
        print_accuracy_report;
        
        // ── Write full shared memory snapshot (all 320 samples) ──────────────
        begin : write_full_smem
            integer wi;
            smem_snap_fd = $fopen("smem_snapshot.mem", "w");
            $fdisplay(smem_snap_fd, "// Shared memory snapshot — ALL %0d samples (full replica dump)", runtime_input_count);
            $fdisplay(smem_snap_fd, "// %0d words total, one 32-bit hex value per line", SMEM_DEPTH);
            $fdisplay(smem_snap_fd, "// All neurons (input, hidden, output) are LIF.");
            $fdisplay(smem_snap_fd, "// Per-sample layout (each sample = %0d words):", WORDS_PER_SAMPLE);
            $fdisplay(smem_snap_fd, "//   Input spikes:  word[sample_offset + ts*%0d + w]  (32 bits packed, %0d neurons)",
                      INPUT_SPK_WORDS_PER_TS, N_INPUT_NEURONS);
            $fdisplay(smem_snap_fd, "//   Vmem (LUT idx): word[sample_offset + %0d*N_TS + ts*%0d + n]  (8-bit unsigned, 0..255)",
                      INPUT_SPK_WORDS_PER_TS, N_ACTIVE_NEURONS);
            $fdisplay(smem_snap_fd, "//   Spikes:        word[sample_offset + (%0d+%0d*N_TS)*N_TS + ts*%0d + w]  (32 bits packed)",
                      INPUT_SPK_WORDS_PER_TS, N_ACTIVE_NEURONS, SPIKE_WORDS_PER_TS);
            $fdisplay(smem_snap_fd, "// CPU reconstructs input vmem from input spikes using LIF dynamics.");
            $fdisplay(smem_snap_fd, "// Mapping: LUT idx 0..127 = v_mem +0..+127;  128..255 = v_mem -128..-1");
            $fdisplay(smem_snap_fd, "// Load: $readmemh(\"smem_snapshot.mem\", smem);");
            
            for (wi = 0; wi < SMEM_DEPTH; wi = wi + 1)
                $fdisplay(smem_snap_fd, "%08h", smem_image[wi]);
            $fclose(smem_snap_fd);
            $display("[DUMP] Full shared memory snapshot written to smem_snapshot.mem (%0d samples, %0d words)",
                     runtime_input_count, SMEM_DEPTH);
        end
        
        $fflush(hw_act_fd);
        $fclose(hw_act_fd);
        $finish;
    end
end

endmodule
