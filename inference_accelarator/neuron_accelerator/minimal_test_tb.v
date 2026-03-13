// minimal_test_tb.v — Hand-crafted LIF verification testbench
// ============================================================
// Network: external spikes → cluster 1 neuron 0 (weight=100, threshold=50)
// If cluster 1 neuron 0 fires, the accelerator is working correctly.
//
// Compile: vcs -full64 -sverilog -debug_access+all +v2k minimal_test_tb.v -o simv_test
// Run:     ./simv_test +time_step_window=4 +input_neurons=2 +nn_layers=1 +input_count=2

`include "neuron_accelerator.v"
`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns / 100ps

module minimal_test_tb;

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

    reg clk, rst;
    reg network_mode, time_step, load_data_in, rst_potential;
    reg [flit_size-1:0] data_in;
    wire ready_in;
    wire [flit_size-1:0] data_out;
    wire load_data_out;
    reg  ready_out;

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

    reg [7:0]  init_mem  [0:10000];
    reg [10:0] spike_mem [0:10000];

    integer runtime_time_step_window;
    integer runtime_input_neurons;
    integer runtime_nn_layers;
    integer runtime_input_count;

    reg  start_init, init_done, start_inf;
    reg  [31:0] init_index;
    reg  [31:0] input_neuron_index;
    reg  [31:0] time_step_index;
    reg  [31:0] input_index;
    integer file;

    localparam S_INJECT = 2'd0;
    localparam S_SETTLE = 2'd1;
    localparam S_FIRE   = 2'd2;
    localparam S_WAIT   = 2'd3;
    localparam SETTLE   = 12'd1500;

    reg [1:0]  inf_state;
    reg [11:0] settle_ctr;
    reg        rearm_pending;

    localparam SMEM_WB_BASE = 32'h2000_0000;
    localparam SMEM_DEPTH   = 49152;

    // ── Track spikes found ──
    integer spikes_found;

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

    always #5 clk = ~clk;
    assign main_fifo_rd_en_out = ~main_fifo_empty_out;

    // ── Output FIFO capture (main output) ──
    always @(posedge clk) begin
        if (!main_fifo_empty_out && start_inf) begin
            $display("[FIFO-OUT] sample=%0d t=%0d packet=0x%03h (cluster=%0d neuron=%0d)",
                     input_index, time_step_index,
                     main_fifo_dout_out,
                     main_fifo_dout_out[10:5], main_fifo_dout_out[4:0]);
            spikes_found = spikes_found + 1;
        end
    end

    // ── Port B spike dump capture ──
    always @(posedge clk) begin
        if (portb_we && portb_en && portb_addr >= 16'hB000 && start_inf) begin
            if (portb_din != 0) begin
                $fwrite(file, "sample=%0d ts=%0d addr=0x%04h spikes=%032b\n",
                        input_index, time_step_index, portb_addr, portb_din);
                $display("[DUMP-SPIKE] sample=%0d ts=%0d addr=0x%04h spikes=%032b",
                         input_index, time_step_index, portb_addr, portb_din);
            end
        end
    end

    // ── Direct hierarchical snoop on cluster 1 spikes ──
    wire [31:0] cluster1_spikes;
    assign cluster1_spikes = uut.all_spikes[1*neurons_per_cluster +: neurons_per_cluster];

    reg accel_done_prev;
    always @(posedge clk) begin
        accel_done_prev <= accelerator_done;
        if (accelerator_done && !accel_done_prev && start_inf) begin
            if (cluster1_spikes != 0) begin
                $display("[SNOOP] sample=%0d t=%0d cluster1_spikes=%032b",
                         input_index, time_step_index, cluster1_spikes);
            end
        end
    end

    // ── Debug: watch accumulator & potential of cluster 1, neuron 0 ──
    // Hierarchical path: gen_spike_forwarder_4[0].gen_neuron_cluster[1].neuron_cluster_inst
    wire [31:0] c1n0_v_pre_spike;
    wire c1n0_spike, c1n0_done;
    assign c1n0_v_pre_spike = uut.gen_spike_forwarder_4[0].gen_neuron_cluster[1].neuron_cluster_inst.neuron_layer_inst.neuron_gen[0].neuron_inst.v_pre_spike_out;
    assign c1n0_spike = uut.gen_spike_forwarder_4[0].gen_neuron_cluster[1].neuron_cluster_inst.neuron_layer_inst.neuron_gen[0].neuron_inst.spike;
    assign c1n0_done = uut.gen_spike_forwarder_4[0].gen_neuron_cluster[1].neuron_cluster_inst.neuron_layer_inst.neuron_gen[0].neuron_inst.done;

    // ── Deep debug probes ──
    // Cluster 1: group 0, cluster port 1
    // Hierarchical prefix for cluster 1
    `define C1 uut.gen_spike_forwarder_4[0].gen_neuron_cluster[1].neuron_cluster_inst

    wire [31:0] c1_enable_neuron;
    wire [2:0]  c1n0_decay_mode;
    wire [31:0] c1n0_v_threshold;
    wire [31:0] c1n0_accumulated;
    wire        c1_cluster_en;
    wire        c1_internal_clk;
    wire [1:0]  c1n0_reset_mode;

    assign c1_enable_neuron  = `C1.neuron_layer_inst.enable_neuron;
    assign c1n0_decay_mode   = `C1.neuron_layer_inst.neuron_gen[0].neuron_inst.decay_mode;
    assign c1n0_v_threshold  = `C1.neuron_layer_inst.neuron_gen[0].neuron_inst.adder.v_threshold;
    assign c1n0_accumulated  = `C1.neuron_layer_inst.neuron_gen[0].neuron_inst.acc.accumulated_out;
    assign c1_cluster_en     = `C1.controller.cluster_en;
    assign c1_internal_clk   = `C1.internal_clk;
    assign c1n0_reset_mode   = `C1.neuron_layer_inst.neuron_gen[0].neuron_inst.reset_mode;

    // Weight resolver probes (group 0)
    `define WR uut.gen_spike_forwarder_4[0].weight_resolver_inst
    wire [31:0] wr_weight_n0_row0;
    assign wr_weight_n0_row0 = `WR.weight_memory_inst.weight_mem[0][31:0]; // neuron 0 weight at addr 0

    // Incoming forwarder probes (cluster 1)
    `define IF1 `C1.incoming_forwarder
    wire [5:0] if1_cluster_table_0;
    wire [15:0] if1_base_addr;
    assign if1_cluster_table_0 = `IF1.cluster_id_table[0];
    assign if1_base_addr       = `IF1.base_weight_addr;

    // Forwarder 4 forwarding map
    `define FWD4 uut.gen_spike_forwarder_4[0].spike_forwarder_4_inst.spike_forwarder_inst
    wire [4:0] fwd4_map0, fwd4_map1, fwd4_map2;
    assign fwd4_map0 = `FWD4.forwarding_map[0];
    assign fwd4_map1 = `FWD4.forwarding_map[1];
    assign fwd4_map2 = `FWD4.forwarding_map[2];

    // Monitor neuron state on time_step and during settle
    reg prev_ts;
    reg init_probe_done;
    always @(posedge clk) begin
        prev_ts <= time_step;

        // Probe once after init completes — dump all config values
        if (start_inf && !init_probe_done) begin
            init_probe_done <= 1;
            $display("=== POST-INIT CONFIG DUMP ===");
            $display("  c1_cluster_en     = %b", c1_cluster_en);
            $display("  c1_enable_neuron  = %032b", c1_enable_neuron);
            $display("  c1n0_decay_mode   = %0d (LIF8=3)", c1n0_decay_mode);
            $display("  c1n0_v_threshold  = %0d", $signed(c1n0_v_threshold));
            $display("  c1n0_reset_mode   = %0d", c1n0_reset_mode);
            $display("  wr_weight_n0_row0 = %0d", $signed(wr_weight_n0_row0));
            $display("  if1_cluster_tab[0]= %0d", if1_cluster_table_0);
            $display("  if1_base_addr     = %0d", if1_base_addr);
            $display("  fwd4_map[0]       = %05b", fwd4_map0);
            $display("  fwd4_map[1]       = %05b", fwd4_map1);
            $display("  fwd4_map[2]       = %05b", fwd4_map2);
            $display("=============================");
        end

        // On time_step rising edge, show key neuron state
        if (time_step && !prev_ts && start_inf) begin
            $display("[TS-EDGE] sample=%0d t=%0d accumulated=%0d decayed=%0d v_thr=%0d enable=%b",
                     input_index, time_step_index,
                     $signed(c1n0_accumulated),
                     $signed(`C1.neuron_layer_inst.neuron_gen[0].neuron_inst.output_potential_decay),
                     $signed(c1n0_v_threshold),
                     c1_enable_neuron[0]);
        end

        // Neuron done output
        if (c1n0_done && start_inf) begin
            $display("[NEURON-DBG] sample=%0d t=%0d c1n0: v_pre=%0d spike=%b done=%b",
                     input_index, time_step_index,
                     $signed(c1n0_v_pre_spike), c1n0_spike, c1n0_done);
        end
    end

    // ── Init ──
    initial begin
        if (!$value$plusargs("time_step_window=%d", runtime_time_step_window))
            runtime_time_step_window = 4;
        if (!$value$plusargs("input_neurons=%d",    runtime_input_neurons))
            runtime_input_neurons = 2;
        if (!$value$plusargs("nn_layers=%d",        runtime_nn_layers))
            runtime_nn_layers = 1;
        if (!$value$plusargs("input_count=%d",      runtime_input_count))
            runtime_input_count = 2;

        $display("==============================================");
        $display("MINIMAL LIF VERIFICATION TESTBENCH");
        $display("  time_step_window = %0d", runtime_time_step_window);
        $display("  input_neurons    = %0d", runtime_input_neurons);
        $display("  nn_layers        = %0d", runtime_nn_layers);
        $display("  input_count      = %0d", runtime_input_count);
        $display("  Network: external→cluster1 neuron0, w=100, thr=50");
        $display("==============================================");

        clk = 0; rst = 1;
        network_mode = 0; load_data_in = 0;
        rst_potential = 0; data_in = 0; ready_out = 0;
        main_fifo_din_in = 0; main_fifo_wr_en_in = 0; time_step = 0;
        start_init = 0; init_done = 0; init_index = 0;
        start_inf = 0; input_index = 0; time_step_index = 0; input_neuron_index = 0;
        inf_state = S_INJECT; settle_ctr = 0; rearm_pending = 0;
        spikes_found = 0; accel_done_prev = 0; prev_ts = 0; init_probe_done = 0;

        $readmemh("data_mem_test.mem",  init_mem);
        $readmemh("spike_mem_test.mem", spike_mem);

        file = $fopen("output.txt", "w");
        if (!file) begin $display("ERROR: cannot open output.txt"); $finish; end

        #10 rst = 0;
        network_mode = 1;
        start_init   = 1;
    end

    // ── Init loading FSM ──
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
                    $display("[INIT] Complete at byte %0d", init_index);
                end
            end
        end else begin
            load_data_in <= 0;
            if (init_done && accelerator_done) begin
                $display("[INIT] Accelerator ready. Starting inference.");
                start_inf <= 1;
                inf_state <= S_INJECT;
                init_done <= 0;
            end
        end
    end

    // ── Spike index ──
    wire [31:0] spike_packet_index;
    assign spike_packet_index = input_neuron_index
                              + time_step_index    * runtime_input_neurons
                              + input_index        * runtime_time_step_window * runtime_input_neurons;

    // ── Inference FSM ──
    always @(posedge clk) begin
        if (time_step)     time_step     <= 0;
        if (rst_potential) rst_potential <= 0;
        main_fifo_wr_en_in <= 0;

        if (start_inf) begin
            case (inf_state)
                S_INJECT: begin
                    if (input_neuron_index < runtime_input_neurons) begin
                        if (spike_mem[spike_packet_index] != 11'h7FF && !main_fifo_full_in) begin
                            main_fifo_din_in   <= spike_mem[spike_packet_index];
                            main_fifo_wr_en_in <= 1;
                            $display("[INJECT] sample=%0d t=%0d neuron=%0d packet=0x%03h",
                                     input_index, time_step_index,
                                     input_neuron_index, spike_mem[spike_packet_index]);
                        end else if (spike_mem[spike_packet_index] == 11'h7FF) begin
                            $display("[INJECT] sample=%0d t=%0d neuron=%0d SKIP (no spike)",
                                     input_index, time_step_index, input_neuron_index);
                        end
                        input_neuron_index <= input_neuron_index + 1;
                    end else begin
                        input_neuron_index <= 0;
                        settle_ctr <= 0;
                        inf_state  <= S_SETTLE;
                    end
                end

                S_SETTLE: begin
                    if (settle_ctr >= SETTLE) begin
                        settle_ctr <= 0;
                        inf_state  <= S_FIRE;
                    end else
                        settle_ctr <= settle_ctr + 1;
                end

                S_FIRE: begin
                    time_step  <= 1;
                    settle_ctr <= 0;
                    $display("[FIRE] sample=%0d time_step %0d", input_index, time_step_index);
                    if (time_step_index + 1 < runtime_time_step_window) begin
                        time_step_index <= time_step_index + 1;
                        inf_state       <= S_INJECT;
                    end else
                        inf_state <= S_WAIT;
                end

                S_WAIT: begin
                    if (settle_ctr >= SETTLE) begin
                        $display("[INF] Sample %0d complete. spikes_found=%0d", input_index, spikes_found);
                        time_step_index <= 0;
                        input_index     <= input_index + 1;
                        rst_potential   <= 1;
                        start_inf       <= 0;
                        settle_ctr      <= 0;
                        inf_state       <= S_INJECT;
                    end else
                        settle_ctr <= settle_ctr + 1;
                end

                default: inf_state <= S_INJECT;
            endcase
        end
    end

    // ── Re-arm for next sample ──
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

    // ── Termination ──
    always @(posedge clk) begin
        if (input_index >= runtime_input_count && !start_inf && !rearm_pending) begin
            repeat(50) @(posedge clk);
            $display("==============================================");
            if (spikes_found > 0)
                $display("TEST PASSED: %0d output spikes detected!", spikes_found);
            else
                $display("TEST FAILED: NO output spikes detected!");
            $display("SIMULATION COMPLETE — %0d samples", runtime_input_count);
            $display("output.txt written.");
            $display("==============================================");
            $fclose(file);
            $finish;
        end
    end

    // Safety timeout
    initial begin
        #50_000_000;
        $display("TIMEOUT reached — aborting");
        $fclose(file);
        $finish;
    end

endmodule
