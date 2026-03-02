// Save this as: neuron_accelerator_dump_tb.v
// Run: iverilog -o dump_tb.vvp neuron_accelerator_dump_tb.v && vvp dump_tb.vvp

`include "neuron_accelerator.v"
`timescale 1ns/100ps

module neuron_accelerator_dump_tb;

    // ── Small parameters for fast simulation ──
    parameter number_of_clusters  = 4;   // only 4 clusters
    parameter neurons_per_cluster = 4;   // only 4 neurons each
    parameter cluster_group_count = 1;   // 1 group of 4
    parameter packet_width  = 11;
    parameter flit_size     = 8;
    parameter main_fifo_depth         = 8;
    parameter forwarder_8_fifo_depth  = 8;
    parameter forwarder_4_fifo_depth  = 4;
    parameter incoming_weight_table_rows = 4;
    parameter max_weight_table_rows      = 4;

    // ── DUT signals ──
    reg clk, rst;
    reg network_mode, time_step, rst_potential;
    reg load_data_in;
    reg [7:0] data_in;
    reg ready_out;
    reg [packet_width-1:0] main_fifo_din_in;
    reg main_fifo_wr_en_in;

    wire ready_in;
    wire [7:0] data_out;
    wire load_data_out, data_out_done;
    wire main_fifo_full_in, main_fifo_empty_out;
    wire [packet_width-1:0] main_fifo_dout_out;
    wire main_fifo_rd_en_out;
    wire accelerator_done;

    // ── Port B (dump) signals ──
    wire [15:0] portb_addr;
    wire [31:0] portb_din;
    wire        portb_we, portb_en;
    wire        dbg_all_clusters_done;  // debug visibility

    // ── DUT instantiation ──
    neuron_accelerator #(
        .packet_width(packet_width),
        .main_fifo_depth(main_fifo_depth),
        .forwarder_8_fifo_depth(forwarder_8_fifo_depth),
        .forwarder_4_fifo_depth(forwarder_4_fifo_depth),
        .number_of_clusters(number_of_clusters),
        .neurons_per_cluster(neurons_per_cluster),
        .incoming_weight_table_rows(incoming_weight_table_rows),
        .max_weight_table_rows(max_weight_table_rows),
        .flit_size(flit_size),
        .cluster_group_count(cluster_group_count)
    ) dut (
        .clk(clk), .rst(rst),
        .network_mode(network_mode),
        .time_step(time_step),
        .rst_potential(rst_potential),
        .load_data_in(load_data_in),
        .data_in(data_in),
        .ready_in(ready_in),
        .data_out(data_out),
        .load_data_out(load_data_out),
        .data_out_done(data_out_done),
        .ready_out(ready_out),
        .main_fifo_din_in(main_fifo_din_in),
        .main_fifo_wr_en_in(main_fifo_wr_en_in),
        .main_fifo_full_in(main_fifo_full_in),
        .main_fifo_dout_out(main_fifo_dout_out),
        .main_fifo_rd_en_out(main_fifo_rd_en_out),
        .main_fifo_empty_out(main_fifo_empty_out),
        .accelerator_done(accelerator_done),
        // debug
        .dbg_all_clusters_done(dbg_all_clusters_done),
        // New dump ports
        .portb_addr(portb_addr),
        .portb_din(portb_din),
        .portb_we(portb_we),
        .portb_en(portb_en),
        .vmem_base_addr(16'hA000),
        .spike_base_addr(16'hB000),
        .current_timestep(4'd0)   // timestep 0 for this test
    );

    // ── Clock ──
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Monitor: all_clusters_done ──
    always @(posedge clk) begin
        if (dbg_all_clusters_done)
            $display("[all_clusters_done=1] t=%0t", $time);
    end

    // ── Monitor: print every Port B write ──
    integer vmem_count = 0;
    integer spike_count = 0;
    always @(posedge clk) begin
        if (portb_we && portb_en) begin
            if (portb_addr >= 16'hA000 && portb_addr < 16'hB000) begin
                $display("[DUMP V_MEM ] addr=0x%04h  data=0x%08h", portb_addr, portb_din);
                vmem_count = vmem_count + 1;
            end else begin
                $display("[DUMP SPIKE ] addr=0x%04h  data=0x%08h", portb_addr, portb_din);
                spike_count = spike_count + 1;
            end
        end
    end

    // ── Timeout watchdog ──
    initial begin
        #100000;
        $display("TIMEOUT - dump FSM never triggered");
        $display("V_mem count so far: %0d, Spike count: %0d", vmem_count, spike_count);
        $finish;
    end

    // ── Main test ──
    initial begin
        $dumpfile("dump_test.vcd");
        $dumpvars(0, neuron_accelerator_dump_tb);

        rst = 1; network_mode = 0; time_step = 0;
        rst_potential = 0; load_data_in = 0;
        ready_out = 1; main_fifo_wr_en_in = 0;

        repeat(10) @(posedge clk);
        rst = 0;
        network_mode = 0;   // spike mode

        // Wait enough cycles for clusters to reach 'done' 
        // and for dump FSM to run (N_TOTAL=16 + N_SPIKE_W=1 + margins)
        repeat(300) @(posedge clk);

        $display("=== Checking dump results ===");
        $display("V_mem words written : %0d (expected %0d)", vmem_count, number_of_clusters*neurons_per_cluster);
        $display("Spike words written : %0d (expected %0d)", spike_count, (number_of_clusters*neurons_per_cluster+31)/32);

        if (vmem_count == number_of_clusters*neurons_per_cluster &&
            spike_count == (number_of_clusters*neurons_per_cluster+31)/32)
            $display("*** PASS: Correct number of words dumped ***");
        else
            $display("*** FAIL: Wrong word counts (dump FSM may not have triggered) ***");

        $finish;
    end


endmodule
