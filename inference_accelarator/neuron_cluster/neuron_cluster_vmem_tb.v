// =============================================================================
//  neuron_cluster_vmem_tb.v — Bottom-up test for v_mem_out and spikes_out_raw
//  Tests that the new output ports are correctly wired through neuron_cluster
// =============================================================================
// Run from neuron_cluster/ folder:
//   iverilog -o vmem_tb.vvp neuron_cluster_vmem_tb.v && vvp vmem_tb.vvp

`define NEURON_CLUSTER
`define NEURON_INCLUDE   // prevents neuron.v from re-including its own deps
`include "../neuron_integer/neuron_int_lif/utils/encording.v"
`include "../neuron_integer/neuron_int_lif/decay/potential_decay.v"
`include "../neuron_integer/neuron_int_lif/adder/potential_adder.v"
`include "../neuron_integer/neuron_int_lif/accumulator/accumulator.v"
`include "../neuron_integer/neuron_int_lif/neuron/controller.v"
`include "../neuron_integer/neuron_int_lif/neuron/neuron.v"
`include "./neuron_layer/neuron_layer.v"
`include "./incoming_forwarder/incoming_forwarder.v"
`include "./cluster_controller/cluster_controller.v"
`include "./outgoing_enc/outgoing_enc.v"
`include "../FIFO/fifo.v"
`include "neuron_cluster.v"

`timescale 1ns/100ps

module neuron_cluster_vmem_tb;

    // ── Small size for fast sim ──
    localparam NPC = 4;   // neurons_per_cluster
    localparam MWT = 4;   // max_weight_table_rows

    // ── Inputs ──
    reg clk, rst, time_step, chip_mode, rst_potential;
    reg [10:0] packet_in;
    reg        fifo_empty, fifo_full;
    reg        load_data;
    reg  [7:0] data;
    reg        load_weight_in;
    reg  [2:0] address_buffer_count;   // 3 bits for depth=8
    reg [32*NPC-1:0] weights_in;

    // ── Outputs ──
    wire [10:0]              packet_out;
    wire                     fifo_rd_en, fifo_wr_en, cluster_done;
    wire [$clog2(MWT)-1:0]   weight_address_out;
    wire                     address_buffer_wr_en;
    wire [32*NPC-1:0]        v_mem_out;        // NEW — what we're testing
    wire [NPC-1:0]           spikes_out_raw;   // NEW

    // ── DUT ──
    neuron_cluster #(
        .packet_width(11),
        .cluster_id(6'd0),
        .number_of_clusters(4),
        .neurons_per_cluster(NPC),
        .incoming_weight_table_rows(MWT),
        .max_weight_table_rows(MWT)
    ) dut (
        .clk(clk),
        .rst(rst),
        .time_step(time_step),
        .chip_mode(chip_mode),
        .rst_potential(rst_potential),
        .packet_in(packet_in),
        .packet_out(packet_out),
        .fifo_empty(fifo_empty),
        .fifo_full(fifo_full),
        .fifo_rd_en(fifo_rd_en),
        .fifo_wr_en(fifo_wr_en),
        .cluster_done(cluster_done),
        .load_data(load_data),
        .data(data),
        .weight_address_out(weight_address_out),
        .address_buffer_wr_en(address_buffer_wr_en),
        .weights_in(weights_in),
        .load_weight_in(load_weight_in),
        .address_buffer_count(address_buffer_count),
        .v_mem_out(v_mem_out),         // NEW port under test
        .spikes_out_raw(spikes_out_raw) // NEW port under test
    );

    // ── Clock ──
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Watchdog ──
    initial begin
        #5000;
        $display("TIMEOUT");
        $finish;
    end

    // ── Test ──
    integer i;
    integer pass_count;
    integer fail_count;

    initial begin
        $dumpfile("vmem_tb.vcd");
        $dumpvars(0, neuron_cluster_vmem_tb);

        pass_count = 0;
        fail_count = 0;

        // Init all inputs
        rst=1; chip_mode=0; time_step=0; rst_potential=0;
        load_data=0; data=0;
        load_weight_in=0; weights_in=0;
        fifo_empty=1; fifo_full=0;
        address_buffer_count=0;
        packet_in=0;

        // Hold reset
        repeat(5) @(posedge clk);
        rst = 0;
        // Wait a few cycles for signals to settle
        repeat(10) @(posedge clk);

        // ─── TEST 1: Check v_mem_out is connected (not X) ───
        $display("\n--- Test 1: v_mem_out port connectivity ---");
        if (^v_mem_out === 1'bx) begin
            $display("  FAIL: v_mem_out is X — port not connected to neuron_layer!");
            fail_count = fail_count + 1;
        end else begin
            $display("  PASS: v_mem_out is driven (not X)");
            pass_count = pass_count + 1;
        end

        // ─── TEST 2: Check spikes_out_raw is connected (not X) ───
        $display("\n--- Test 2: spikes_out_raw port connectivity ---");
        if (^spikes_out_raw === 1'bx) begin
            $display("  FAIL: spikes_out_raw is X — port not connected!");
            fail_count = fail_count + 1;
        end else begin
            $display("  PASS: spikes_out_raw is driven (not X)");
            pass_count = pass_count + 1;
        end

        // ─── TEST 3: After reset, v_mem should be 0 (no computation) ───
        $display("\n--- Test 3: All V_mem = 0 after reset (no input) ---");
        if (v_mem_out == {(32*NPC){1'b0}}) begin
            $display("  PASS: All v_mem_out = 0x00000000 after reset");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: v_mem_out non-zero after reset = 0x%h", v_mem_out);
            fail_count = fail_count + 1;
        end

        // ─── TEST 4: After reset, spikes should be 0 ───
        $display("\n--- Test 4: All spikes = 0 after reset ---");
        if (spikes_out_raw == {NPC{1'b0}}) begin
            $display("  PASS: All spikes_out_raw = 0 after reset");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: spikes_out_raw non-zero = %b", spikes_out_raw);
            fail_count = fail_count + 1;
        end

        // ─── Print all neuron values ───
        $display("\n--- Neuron dump ---");
        for (i = 0; i < NPC; i = i + 1)
            $display("  neuron[%0d]  v_mem=0x%08h  spike=%b",
                     i, v_mem_out[i*32 +: 32], spikes_out_raw[i]);

        // ─── Summary ───
        $display("\n==============================================");
        $display(" Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("==============================================");
        if (fail_count == 0)
            $display(" *** ALL TESTS PASSED — v_mem_out wiring is correct ***");
        else
            $display(" *** SOME TESTS FAILED ***");

        $finish;
    end

endmodule
