// mnist_inference_tb.v
// =====================
// MNIST inference testbench for the neuron accelerator.
// Identical logic to neuron_accelerator_tb.v but with:
//   - $display removed from the init-loading loop (critical for speed)
//   - init_mem sized for 800K bytes (covers 668K weight init stream)
//   - spike_mem sized for 4M entries  (covers ~100 samples × 25T × 784)
//   - Default parameters set for MNIST (784 inputs, 25 timesteps, 100 samples)
//   - Progress prints only at sample boundaries
//   - Output: output.txt  format unchanged: "{sample}:{hex_packet}"
//
// Cluster mapping:
//   Input  : clusters  0-24  (784 neurons)
//   Hidden : clusters 25-30  (192 neurons)
//   Output : cluster  31     (10 neurons)
//   Output packet for digit k = (31 << 5) | k = 0x3E0 | k
//
// Compile:
//   iverilog -g2012 -o mnist_sim.vvp mnist_inference_tb.v
//
// Run:
//   vvp mnist_sim.vvp +time_step_window=25 +input_neurons=784 \
//       +nn_layers=2 +input_count=100

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

    // MNIST defaults (overridden by +args)
    parameter time_step_window = 25;
    parameter input_neurons    = 784;
    parameter nn_layers        = 2;
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
    // spike_mem: 4 000 000 entries covers 100 samples × 25T × 784 inputs
    reg [10:0] spike_mem [0:4000000];

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

    // ─── Initialisation ───────────────────────────────────────────────────
    initial begin
        // Read runtime +args (fall back to module defaults)
        if (!$value$plusargs("time_step_window=%d", runtime_time_step_window))
            runtime_time_step_window = time_step_window;
        if (!$value$plusargs("input_neurons=%d", runtime_input_neurons))
            runtime_input_neurons = input_neurons;
        if (!$value$plusargs("nn_layers=%d", runtime_nn_layers))
            runtime_nn_layers = nn_layers;
        if (!$value$plusargs("input_count=%d", runtime_input_count))
            runtime_input_count = input_count;

        $display("==============================================");
        $display("MNIST Inference Testbench");
        $display("  time_step_window = %0d", runtime_time_step_window);
        $display("  input_neurons    = %0d", runtime_input_neurons);
        $display("  nn_layers        = %0d", runtime_nn_layers);
        $display("  input_count      = %0d", runtime_input_count);
        $display("  Cluster map: input=0-24, hidden=25-30, output=31");
        $display("==============================================");

        // Initialise signals
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

        // Load memory files
        $readmemh("data_mem.mem",  init_mem);
        $readmemh("spike_mem.mem", spike_mem);

        // Open output file
        file = $fopen("output.txt", "w");
        if (!file) begin $display("ERROR: cannot open output.txt"); $finish; end

        // Release reset
        #10 rst = 0;
        network_mode = 1;   // init mode
        start_init   = 1;
    end

    // ─── Init loading FSM (NO $display per byte — critical for speed) ────
    always @(posedge clk) begin
        if (start_init) begin
            if (init_index < 800000) begin
                if (init_mem[init_index] !== 8'bx) begin
                    if (ready_in && !load_data_in) begin
                        data_in      <= init_mem[init_index];
                        load_data_in <= 1;
                        init_index   <= init_index + 1;
                        // Progress report every 50000 bytes
                        if (init_index % 50 == 0)
                            $display("[INIT] byte %0d / ~668774", init_index);
                    end else begin
                        load_data_in <= 0;
                    end
                end else begin
                    // Hit undefined (end of valid data)
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
                $display("[INIT] Accelerator init handshake done. Starting inference.");
                start_inf <= 1;
                init_done <= 0;
            end
        end
    end

    // ─── Spike packet index ───────────────────────────────────────────────
    wire [31:0] spike_packet_index;
    assign spike_packet_index = input_neuron_index
                              + time_step_index * runtime_input_neurons
                              + input_index * runtime_time_step_window * runtime_input_neurons;

    // ─── Inference FSM ────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (start_inf) begin
            if (time_step_index < runtime_time_step_window) begin
                // Inject spike for current neuron
                if (input_neuron_index < runtime_input_neurons) begin
                    input_neuron_index <= input_neuron_index + 1;
                    if (spike_mem[spike_packet_index] != 11'h7FF) begin
                        main_fifo_din_in   <= spike_mem[spike_packet_index];
                        main_fifo_wr_en_in <= 1;
                    end else begin
                        main_fifo_din_in   <= 0;
                        main_fifo_wr_en_in <= 0;
                    end
                end else begin
                    main_fifo_din_in   <= 0;
                    main_fifo_wr_en_in <= 0;
                    // Advance timestep after dump completes
                    if (dump_done) begin
                        input_neuron_index <= 0;
                        time_step_index    <= time_step_index + 1;
                        time_step          <= 1;
                    end
                end
            end else if (time_step_index < (runtime_time_step_window + runtime_nn_layers - 1)) begin
                // No-input propagation phase
                if (accelerator_done) begin
                    time_step_index <= time_step_index + 1;
                end
            end else begin
                // Sample done — wait for final dump then reset
                if (dump_done) begin
                    $display("[INF] Sample %0d complete.", input_index);
                    time_step_index    <= 0;
                    input_index        <= input_index + 1;
                    rst_potential      <= 1;
                    start_inf          <= 0;
                end
            end
        end
    end

    // ─── Capture output spikes (main FIFO out) ────────────────────────────
    assign main_fifo_rd_en_out = ~main_fifo_empty_out;

    always @(posedge clk) begin
        waiting_for_data <= main_fifo_rd_en_out;
        if (waiting_for_data)
            $fwrite(file, "%0d:%h \n", input_index, main_fifo_dout_out);
    end

    // ─── time_step / rst_potential pulse (one cycle) ──────────────────────
    always @(posedge clk) begin
        if (time_step)     time_step     <= 0;
        if (rst_potential) begin
            rst_potential <= 0;
            start_inf     <= 1;   // resume for next sample
        end
    end

    // ─── Termination ──────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (input_index >= runtime_input_count) begin
            repeat(20) @(posedge clk);
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
