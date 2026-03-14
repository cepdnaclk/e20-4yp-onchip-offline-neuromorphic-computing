// neuron_accelerator_tb.v — XOR inference testbench
// Modeled after mnist_inference_tb.v (settle-counter FSM, portb spike capture)
//
// Compile (VCS):
//   vcs -full64 -sverilog -debug_access+all +v2k neuron_accelerator_tb.v -o simv_xor
// Run:
//   ./simv_xor +time_step_window=10 +input_neurons=2 +nn_layers=1 +input_count=4

`include "neuron_accelerator.v"
`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns / 100ps

module neuron_accelerator_tb;

    parameter packet_width             = 11;
    parameter main_fifo_depth          = 32;
    parameter forwarder_8_fifo_depth   = 16;
    parameter forwarder_4_fifo_depth   = 8;
    parameter number_of_clusters       = 64;  // must be 64: $clog2(64)=6 bits needed for external cluster ID 62
    parameter neurons_per_cluster      = 32;
    parameter incoming_weight_table_rows = 1024;
    parameter max_weight_table_rows    = 4096;
    parameter flit_size                = 8;
    parameter cluster_group_count      = 8;

    parameter time_step_window = 10;
    parameter input_neurons    = 2;
    parameter nn_layers        = 1;
    parameter input_count      = 4;

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

    // ─── Write spike dumps to output.txt ──────────────────────────────────
    always @(posedge clk) begin
        if (portb_we && portb_en && portb_addr >= 16'hB000 && start_inf) begin
            if (portb_din != 0) begin
                $fwrite(file, "input=%0d ts=%0d cluster=%0d spikes=%032b\n",
                        input_index, time_step_index,
                        portb_addr - 16'hB000, portb_din);
                $display("[OUT] input=%0d ts=%0d cluster=%0d spikes=%032b",
                         input_index, time_step_index,
                         portb_addr - 16'hB000, portb_din);
            end
        end
    end

    // ─── Init ─────────────────────────────────────────────────────────────
    initial begin
        if (!$value$plusargs("time_step_window=%d", runtime_time_step_window))
            runtime_time_step_window = time_step_window;
        if (!$value$plusargs("input_neurons=%d",    runtime_input_neurons))
            runtime_input_neurons = input_neurons;
        if (!$value$plusargs("nn_layers=%d",        runtime_nn_layers))
            runtime_nn_layers = nn_layers;
        if (!$value$plusargs("input_count=%d",      runtime_input_count))
            runtime_input_count = input_count;

        $display("==============================================");
        $display("XOR Inference Testbench");
        $display("  time_step_window = %0d", runtime_time_step_window);
        $display("  input_neurons    = %0d", runtime_input_neurons);
        $display("  nn_layers        = %0d", runtime_nn_layers);
        $display("  input_count      = %0d", runtime_input_count);
        $display("==============================================");

        clk = 0; rst = 1;
        network_mode = 0; load_data_in = 0;
        rst_potential = 0; data_in = 0; ready_out = 0;
        main_fifo_din_in = 0; main_fifo_wr_en_in = 0; time_step = 0;
        start_init = 0; init_done = 0; init_index = 0;
        start_inf = 0; input_index = 0; time_step_index = 0; input_neuron_index = 0;
        inf_state = S_INJECT; settle_ctr = 0; rearm_pending = 0;

        $readmemh("data_mem.mem",  init_mem);
        $readmemh("spike_mem.mem", spike_mem);

        file = $fopen("output.txt", "w");
        if (!file) begin $display("ERROR: cannot open output.txt"); $finish; end

        #10 rst = 0;
        network_mode = 1;
        start_init   = 1;
    end

    // ─── Init loading FSM ─────────────────────────────────────────────────
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

    // ─── Spike index ──────────────────────────────────────────────────────
    wire [31:0] spike_packet_index;
    assign spike_packet_index = input_neuron_index
                              + time_step_index    * runtime_input_neurons
                              + input_index        * runtime_time_step_window * runtime_input_neurons;

    // ─── Inference FSM ────────────────────────────────────────────────────
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
                    if (time_step_index + 1 < runtime_time_step_window) begin
                        time_step_index <= time_step_index + 1;
                        inf_state       <= S_INJECT;
                    end else
                        inf_state <= S_WAIT;
                end

                S_WAIT: begin
                    if (settle_ctr >= SETTLE) begin
                        $display("[INF] Sample %0d complete.", input_index);
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

    // ─── Re-arm for next sample ───────────────────────────────────────────
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
        if (input_index >= runtime_input_count && !start_inf && !rearm_pending) begin
            repeat(50) @(posedge clk);
            $display("==============================================");
            $display("SIMULATION COMPLETE — %0d samples processed", runtime_input_count);
            $display("output.txt written.");
            $display("==============================================");
            $fclose(file);
            $finish;
        end
    end

endmodule
