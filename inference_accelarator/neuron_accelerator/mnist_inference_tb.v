// mnist_inference_tb.v  (v4 — FIFO output capture)
// =========================================
// FIXES vs v3:
//   1. Fixed memory files: data_mem_mnist.mem / spike_mem_mnist.mem (was XOR data)
//   2. Output capture via FIFO instead of portb dump (dump FSM edge never triggered)
//   3. Output format matches decoder: {sample}:{hex_packet} (was {sample}:{digit})
//   4. Propagation phase and settle FSM unchanged from v3
//
// Cluster mapping:
//   Input  : clusters  0-24  (784 neurons)
//   Hidden : clusters 25-30  (192 neurons)
//   Output : cluster  31     (10 neurons)
//   Output packet for digit k = (31<<5)|k = 0x3E0|k
//
// Compile (VCS):
//   vcs -full64 -sverilog -debug_access+all +v2k mnist_inference_tb.v -o simv_mnist
// Run:
//   ./simv_mnist +time_step_window=16 +input_neurons=784 +nn_layers=2 +input_count=100 -l sim_mnist.log
//
// Decode:
//   python3 ../../tools/decoder/decode_output.py --verbose
//
// Quick test (5 samples):
//   ./simv_mnist +time_step_window=16 +input_neurons=784 +nn_layers=2 +input_count=5 -l sim_quick.log

`include "neuron_accelerator.v"
`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns / 100ps

module mnist_inference_tb;

    // ─── Testbench parameters ──────────────────────────────────────────────
    parameter packet_width             = 11;
    parameter main_fifo_depth          = 32;
    parameter forwarder_8_fifo_depth   = 16;
    parameter forwarder_4_fifo_depth   = 8;
    parameter number_of_clusters       = 32;
    parameter neurons_per_cluster      = 32;
    parameter incoming_weight_table_rows = 1024;
    parameter max_weight_table_rows    = 4096;
    parameter flit_size                = 8;
    parameter cluster_group_count      = 8;

    // MNIST defaults — MUST match spike_mem.mem generation (--timesteps 16)
    parameter time_step_window = 16;   // *** FIXED: was 25, file has 16 ***
    parameter input_neurons    = 784;
    parameter nn_layers        = 2;    // 784→200→10 : 2 layers after input
    parameter input_count      = 100;

    // ─── Signals ──────────────────────────────────────────────────────────
    reg clk, rst;
    reg network_mode, time_step, load_data_in, rst_potential;
    reg [flit_size-1:0] data_in;
    wire ready_in;
    wire [flit_size-1:0] data_out;
    wire load_data_out;
    reg  ready_out;
    wire data_out_done;

    reg  [packet_width-1:0] main_fifo_din_in;
    reg  main_fifo_wr_en_in;
    wire main_fifo_full_in;
    wire [packet_width-1:0] main_fifo_dout_out;
    wire main_fifo_rd_en_out;
    wire main_fifo_empty_out;

    wire accelerator_done, dbg_all_clusters_done, dump_done;

    wire [15:0] portb_addr;
    wire [31:0] portb_din;
    wire        portb_we, portb_en;
    wire [31:0] portb_dout;
    wire        collision_det;

    reg  [31:0] wb_adr_i = 0, wb_dat_i = 0;
    wire [31:0] wb_dat_o;
    reg  [3:0]  wb_sel_i = 4'hF;
    reg  wb_we_i = 0, wb_stb_i = 0, wb_cyc_i = 0;
    wire wb_ack_o;

    // ─── Memory arrays ────────────────────────────────────────────────────
    // init_mem: 800 000 bytes covers data_mem.mem (668 774 bytes for MNIST)
    reg [7:0]  init_mem  [0:800000];
    // spike_mem: 100 × 16 × 784 = 1,254,400 entries (add small margin)
    reg [10:0] spike_mem [0:1300000];

    // ─── Runtime parameters ───────────────────────────────────────────────
    integer runtime_time_step_window;
    integer runtime_input_neurons;
    integer runtime_nn_layers;
    integer runtime_input_count;

    // ─── Control registers ────────────────────────────────────────────────
    reg  start_init, init_done, start_inf;
    reg  [31:0] init_index;
    reg  [31:0] input_neuron_index;
    reg  [31:0] time_step_index;
    reg  [31:0] input_index;
    reg  waiting_for_data;
    integer file;

    // ─── Inference FSM states ─────────────────────────────────────────────
    localparam S_IDLE       = 3'd0;
    localparam S_INJECT     = 3'd1;  // stream all input spikes for this timestep
    localparam S_WAIT_DUMP  = 3'd2;  // fixed settle wait after injection
    localparam S_FIRE       = 3'd3;  // assert time_step pulse
    localparam S_NEXT_TS    = 3'd4;  // fixed settle wait after time_step
    localparam S_PROPAGATE  = 3'd5;  // extra fire cycles for deeper layers
    localparam S_DONE_WAIT  = 3'd6;  // fixed final settle wait before next sample

    reg [2:0] inf_state;
    reg [11:0] settle_ctr;  // 12-bit: needs >1056 cycles (dump FSM)
    reg [3:0] prop_fire_count;  // count propagation fires
    localparam SETTLE = 12'd1500;

    // ─── Shared memory ────────────────────────────────────────────────────
    localparam SMEM_WB_BASE = 32'h2000_0000;
    localparam SMEM_DEPTH   = 49152;

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
        .portb_din(portb_din),
        .portb_dout(portb_dout),
        .portb_we(portb_we),
        .portb_en(portb_en),
        .collision_detect(collision_det)
    );

    // ─── DUT ──────────────────────────────────────────────────────────────
    neuron_accelerator #(
        .packet_width(packet_width),
        .main_fifo_depth(main_fifo_depth),
        .forwarder_8_fifo_depth(forwarder_8_fifo_depth),
        .forwarder_4_fifo_depth(forwarder_4_fifo_depth),
        .number_of_clusters(number_of_clusters),
        .neurons_per_cluster(neurons_per_cluster),
        .incoming_weight_table_rows(incoming_weight_table_rows),
        .max_weight_table_rows(max_weight_table_rows),
        .cluster_group_count(cluster_group_count),
        .flit_size(flit_size)
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
        .current_timestep(time_step_index[3:0])
    );

    // ─── Clock ────────────────────────────────────────────────────────────
    always #5 clk = ~clk;

    // ─── Always drain the output FIFO ─────────────────────────────────────
    // Required so accelerator_done can go high after neuron firing.
    assign main_fifo_rd_en_out = ~main_fifo_empty_out;

    // ─── Direct snoop on cluster 31 spikes → output.txt ──────────────────
    // The spike forwarder's forwarding_map may not route output cluster spikes
    // to the main output FIFO, and the dump FSM's rising-edge trigger may not
    // fire reliably. Instead, we directly read the raw spike bits from the
    // accelerator's all_spikes bus — the same bus the dump FSM uses.
    //
    // Cluster 31 occupies all_spikes[1023:992] (= cluster_31 * 32 neurons).
    // Neurons 0-9 are the output digits.
    //
    // We detect when accelerator_done rises (same trigger as the dump FSM)
    // and sample cluster 31's spike bits at that moment.
    //
    // Output format for decoder: "{sample_index}:{packet_hex}"
    //   packet = (31 << 5) | neuron_id = 0x3E0 + digit

    // Cluster 31's raw spikes: bits [31*32 +: 32] of all_spikes
    wire [31:0] cluster31_spikes = uut.all_spikes[31*neurons_per_cluster +: neurons_per_cluster];

    // Edge detection on accelerator_done for snoop capture
    reg prev_accel_done_snoop;
    always @(posedge clk) begin
        if (rst)
            prev_accel_done_snoop <= 1'b0;
        else
            prev_accel_done_snoop <= accelerator_done;
    end

    // Capture on rising edge of accelerator_done (same as dump FSM trigger)
    always @(posedge clk) begin
        if (!rst && start_inf && accelerator_done && !prev_accel_done_snoop) begin
            // Rising edge of accelerator_done detected — neurons just finished
            if (|cluster31_spikes[9:0]) begin
                begin : snoop_capture
                    integer d;
                    for (d = 0; d < 10; d = d + 1) begin
                        if (cluster31_spikes[d]) begin
                            $fwrite(file, "%0d:%03h\n", input_index, (31 << 5) | d);
                            $display("[SNOOP] Sample %0d ts=%0d → digit %0d spiked (pkt=0x%03h)",
                                     input_index, time_step_index, d, (31 << 5) | d);
                        end
                    end
                end
            end
        end
    end

    // ─── Also capture from output FIFO (backup, in case forwarding_map routes here) ──
    always @(posedge clk) begin
        if (start_inf && !main_fifo_empty_out) begin
            begin : fifo_capture
                reg [5:0] cap_cluster;
                reg [4:0] cap_neuron;
                cap_cluster = main_fifo_dout_out[10:5];
                cap_neuron  = main_fifo_dout_out[4:0];
                if (cap_cluster == 6'd31 && cap_neuron < 5'd10) begin
                    // Don't double-write to file — snoop already does it
                    $display("[FIFO-OUT] Sample %0d → digit %0d (pkt=0x%03h)",
                             input_index, cap_neuron, main_fifo_dout_out[10:0]);
                end
            end
        end
    end

    // ─── Debug: log accelerator_done transitions ─────────────────────────
    reg prev_accel_done_dbg;
    always @(posedge clk) begin
        if (rst)
            prev_accel_done_dbg <= 1'b0;
        else begin
            if (start_inf && accelerator_done != prev_accel_done_dbg) begin
                if (accelerator_done)
                    $display("[ACCEL-DBG] accelerator_done ROSE at t=%0d sample=%0d time=%0t",
                             time_step_index, input_index, $time);
                else
                    $display("[ACCEL-DBG] accelerator_done FELL at t=%0d sample=%0d time=%0t",
                             time_step_index, input_index, $time);
            end
            prev_accel_done_dbg <= accelerator_done;
        end
    end

    // ─── Debug: log portb dump activity ──────────────────────────────────
    always @(posedge clk) begin
        if (portb_we && portb_en && start_inf && portb_addr >= 16'hB000) begin
            $display("[DUMP-DBG] t=%0d sample=%0d addr=0x%04h spikes=%b",
                     time_step_index, input_index, portb_addr, portb_din);
        end
    end

    // ─── Initialisation ───────────────────────────────────────────────────
    initial begin
        if (!$value$plusargs("time_step_window=%d", runtime_time_step_window))
            runtime_time_step_window = time_step_window;
        if (!$value$plusargs("input_neurons=%d", runtime_input_neurons))
            runtime_input_neurons = input_neurons;
        if (!$value$plusargs("nn_layers=%d", runtime_nn_layers))
            runtime_nn_layers = nn_layers;
        if (!$value$plusargs("input_count=%d", runtime_input_count))
            runtime_input_count = input_count;

        $display("==============================================");
        $display("MNIST Inference Testbench v4");
        $display("  time_step_window = %0d", runtime_time_step_window);
        $display("  input_neurons    = %0d", runtime_input_neurons);
        $display("  nn_layers        = %0d", runtime_nn_layers);
        $display("  input_count      = %0d", runtime_input_count);
        $display("  Cluster map: input=0-24, hidden=25-30, output=31");
        $display("==============================================");

        clk = 0; rst = 1;
        network_mode = 0; load_data_in = 0;
        rst_potential = 0; data_in = 0;
        ready_out = 0;
        main_fifo_din_in = 0; main_fifo_wr_en_in = 0;
        time_step = 0;
        start_init = 0; init_done = 0; init_index = 0;
        start_inf = 0;
        input_index = 0; time_step_index = 0; input_neuron_index = 0;
        waiting_for_data = 0;
        inf_state  = S_IDLE;
        settle_ctr = 0;
        prop_fire_count = 0;

        $readmemh("data_mem_mnist.mem",  init_mem);
        $readmemh("spike_mem_mnist.mem", spike_mem);

        file = $fopen("output.txt", "w");
        if (!file) begin $display("ERROR: cannot open output.txt"); $finish; end

        #10 rst = 0;
        network_mode = 1;
        start_init   = 1;
    end

    // ─── Init loading FSM ─────────────────────────────────────────────────
    always @(posedge clk) begin
        if (start_init) begin
            if (init_index < 800000) begin
                if (init_mem[init_index] !== 8'bx) begin
                    if (ready_in && !load_data_in) begin
                        data_in      <= init_mem[init_index];
                        load_data_in <= 1;
                        init_index   <= init_index + 1;
                        if (init_index % 50000 == 0)
                            $display("[INIT] byte %0d / ~668774", init_index);
                    end else begin
                        load_data_in <= 0;
                    end
                end else begin
                    load_data_in <= 0;
                    if (ready_in && !load_data_in) begin
                        network_mode <= 0;
                        start_init   <= 0;
                        init_done    <= 1;
                        $display("[INIT] Loading complete at byte %0d", init_index);
                    end
                end
            end
        end else begin
            load_data_in <= 0;
            if (init_done && accelerator_done) begin
                $display("[INIT] Accelerator ready. Starting inference.");
                start_inf  <= 1;
                inf_state  <= S_INJECT;
                init_done  <= 0;
            end
        end
    end

    // ─── Spike packet index ───────────────────────────────────────────────
    // spike_mem layout: [sample][timestep][neuron]
    //   index = sample * T * N + timestep * N + neuron
    wire [31:0] spike_packet_index;
    assign spike_packet_index = input_neuron_index
                              + time_step_index    * runtime_input_neurons
                              + input_index        * runtime_time_step_window * runtime_input_neurons;

    // ─── Inference FSM ────────────────────────────────────────────────────
    always @(posedge clk) begin
        // Clear single-cycle signals every clock
        if (time_step)     time_step     <= 0;
        if (rst_potential) rst_potential <= 0;
        main_fifo_wr_en_in <= 0;

        if (start_inf) begin
            case (inf_state)

                // ── Inject all input spikes for current timestep ──────────
                S_INJECT: begin
                    if (input_neuron_index < runtime_input_neurons) begin
                        if (spike_mem[spike_packet_index] != 11'h7FF &&
                            !main_fifo_full_in) begin
                            main_fifo_din_in   <= spike_mem[spike_packet_index];
                            main_fifo_wr_en_in <= 1;
                        end
                        input_neuron_index <= input_neuron_index + 1;
                    end else begin
                        // Done injecting; give hardware a few cycles to settle
                        input_neuron_index <= 0;
                        settle_ctr         <= 0;
                        inf_state          <= S_WAIT_DUMP;
                    end
                end

                // ── Fixed settle wait after injection ─────────────────────
                S_WAIT_DUMP: begin
                    if (settle_ctr >= SETTLE) begin
                        settle_ctr <= 0;
                        inf_state  <= S_FIRE;
                    end else
                        settle_ctr <= settle_ctr + 1;
                end

                // ── Assert time_step for 1 cycle to trigger neuron firing ─
                S_FIRE: begin
                    time_step  <= 1;
                    settle_ctr <= 0;   // reset so S_NEXT_TS actually waits
                    inf_state  <= S_NEXT_TS;
                end

                // ── Fixed settle wait post-fire, then advance timestep ────
                S_NEXT_TS: begin
                    if (settle_ctr >= SETTLE) begin
                        settle_ctr <= 0;
                        if (time_step_index + 1 < runtime_time_step_window) begin
                            time_step_index <= time_step_index + 1;
                            inf_state       <= S_INJECT;
                        end else begin
                            // All input timesteps done.
                            // nn_layers > 1 means we need (nn_layers-1) extra
                            // propagation cycles for spikes to reach output.
                            // DO NOT increment time_step_index here!
                            prop_fire_count <= 0;  // reset propagation counter
                            if (runtime_nn_layers > 1)
                                inf_state <= S_PROPAGATE;
                            else
                                inf_state <= S_DONE_WAIT;
                        end
                    end
                    else
                        settle_ctr <= settle_ctr + 1;
                end

                // ── Extra propagation cycles: fire once per extra layer ───
                // For 784→200→10 (nn_layers=2): one extra fire cycle
                // time_step_index stays at 16 during ALL propagation cycles
                S_PROPAGATE: begin
                    if (settle_ctr >= SETTLE) begin
                        settle_ctr <= 0;
                        time_step <= 1;  // Fire this cycle
                        prop_fire_count <= prop_fire_count + 1;
                        if (prop_fire_count + 1 >= runtime_nn_layers - 1) begin
                            // All propagation cycles done
                            inf_state <= S_DONE_WAIT;
                        end
                        // else stay in PROPAGATE for next fire
                    end
                    else
                        settle_ctr <= settle_ctr + 1;
                end

                // ── Fixed final settle wait, then end this sample ─────────
                S_DONE_WAIT: begin
                    if (settle_ctr >= SETTLE) begin
                        $display("[INF] Sample %0d complete. (total_ts=%0d)",
                                 input_index, runtime_time_step_window);
                        time_step_index <= 0;
                        input_index     <= input_index + 1;
                        rst_potential   <= 1;
                        start_inf       <= 0;
                        settle_ctr      <= 0;
                        inf_state       <= S_IDLE;
                    end
                    else
                        settle_ctr <= settle_ctr + 1;
                end

                default: ;

            endcase
        end
    end

    // ─── Re-arm inference for next sample after potential reset ──────────
    // rst_potential is asserted for 1 cycle inside the FSM (S_DONE_WAIT).
    // One cycle later the hardware has reset potentials; we can start the
    // next sample.  Use a registered "pending" flag to avoid $past().
    reg rearm_pending;
    always @(posedge clk) begin
        if (rst) begin
            rearm_pending <= 0;
        end else begin
            if (rst_potential)
                rearm_pending <= 1;
            if (rearm_pending && !start_inf) begin
                rearm_pending <= 0;
                if (input_index < runtime_input_count) begin
                    start_inf <= 1;
                    inf_state <= S_INJECT;
                end
            end
        end
    end

    // ─── Termination ──────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (input_index >= runtime_input_count && inf_state == S_IDLE && !start_inf) begin
            repeat(50) @(posedge clk);
            $display("==============================================");
            $display("SIMULATION COMPLETE");
            $display("  Processed %0d samples", runtime_input_count);
            $display("  output.txt written.");
            $display("  Decode with: python3 tools/decoder/decode_output.py");
            $display("==============================================");
            $fclose(file);
            $finish;
        end
    end

endmodule
