`timescale 1ns/1ps
`include "./incoming_forwarder.v"
`include "../../FIFO/fifo.v"

module incoming_forwarder_tb;

    // Parameters
    parameter NUM_OF_NEURONS = 32;
    parameter WEIGHT_TABLE_ROWS = 32;
    localparam WEIGHT_WIDTH = 32 * NUM_OF_NEURONS;
    parameter FIFO_WIDTH = 11;
    parameter FIFO_DEPTH = 8;
    
    // Clock and reset
    reg clk;
    reg rst;
    
    // DUT inputs
    wire [5:0] cluster_id;
    wire [4:0] neuron_id;
    reg forwarder_mode;
    reg [WEIGHT_WIDTH-1:0] weight_in;
    reg load_weight_in;
    reg load_spike;
    reg [$clog2(WEIGHT_TABLE_ROWS)-1:0] row_index;

    reg [5:0] cluster_id_init;
    reg [4:0] neuron_id_init;

    // FIFO control signals
    wire empty;
    wire rd_en;
    wire full;
    wire [3:0] count;
    wire [FIFO_WIDTH-1:0] data_out;
    reg [FIFO_WIDTH-1:0] data_in;
    reg wr_en;


    // DUT outputs
    wire [WEIGHT_WIDTH-1:0] weight_out;
    wire load_weight;

    integer i; // Loop variable
    
    // Instantiate DUT
    incoming_forwarder #(
        .num_of_neurons(NUM_OF_NEURONS),
        .weight_table_rows(WEIGHT_TABLE_ROWS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .cluster_id(cluster_id),
        .neuron_id(neuron_id),
        .weight_out(weight_out),
        .load_weight(load_weight),
        .forwarder_mode(forwarder_mode),
        .weight_in(weight_in),
        .load_weight_in(load_weight_in),
        .row_index(row_index),
        .empty(empty),
        .rd_en(rd_en)
    );

    fifo #(
        .WIDTH(FIFO_WIDTH),
        .DEPTH(FIFO_DEPTH)
    ) fifo_inst (
        .clk(clk),
        .rst(rst),
        .wr_en(wr_en),
        .din(data_in),
        .rd_en(rd_en),
        .dout(data_out),
        .full(full),
        .empty(empty),
        .count(count)
    );

    assign cluster_id = forwarder_mode ? cluster_id_init : data_out[10:5];
    assign neuron_id = forwarder_mode ? neuron_id_init : data_out[4:0];
    
    // Clock generation
    always #5 clk = ~clk;
    
    // Test stimulus
    initial begin
        $dumpfile("incoming_forwarder_tb.vcd");
        $dumpvars(0, incoming_forwarder_tb);

        // Initialize signals
        clk = 0;
        rst = 0;
        cluster_id_init = 0;
        neuron_id_init = 0;
        forwarder_mode = 0;
        weight_in = 0;
        load_weight_in = 0;
        row_index = 0;
        load_spike = 0;
        wr_en = 0;
        data_in = 0;

        
        // Reset sequence
        rst = 1;
        #20 rst = 0;
        #10;
        
        // Test 1: Store weights in different rows
        forwarder_mode = 1; // Storage mode
        
        // Store weight pattern 1 (all 32 words = 0x00000001)
        row_index = 0;
        cluster_id_init = 6'h0A;
        neuron_id_init = 5'h01;
        weight_in = {NUM_OF_NEURONS{32'h00000001}};
        load_weight_in = 1;
        #10;
        load_weight_in = 0;
        #10;
        
        // Store weight pattern 2 (incrementing pattern)
        row_index = 1;
        cluster_id_init = 6'h0B;
        neuron_id_init = 5'h02;
        for (i = 0; i < NUM_OF_NEURONS; i = i + 1) begin
            weight_in[i*32 +: 32] = 32'h00000002 + i;
        end
        load_weight_in = 1;
        #10;
        load_weight_in = 0;
        #10;
        
        // Store weight pattern 3 (alternating pattern)
        row_index = 2;
        cluster_id_init = 6'h0A; // Same cluster as first pattern
        neuron_id_init = 5'h03;
        for (i = 0; i < NUM_OF_NEURONS; i = i + 1) begin
            weight_in[i*32 +: 32] = (i % 2) ? 32'hAAAAAAAA : 32'h55555555;
        end
        load_weight_in = 1;
        #10;
        load_weight_in = 0;
        #20;
        
        // Test 2: Retrieve stored weights
        forwarder_mode = 0; // Forwarding mode
        
        // Retrieve first weight set
        #10 data_in = {6'h0A, 5'h01};
        wr_en = 1;
        #10 wr_en = 0;
        
        // Retrieve second weight set
        #10 data_in = {6'h0B, 5'h02};
        wr_en = 1;
        #10 wr_en = 0;

        // Retrieve third weight set
        #10 data_in = {6'h0A, 5'h03};
        wr_en = 1;
        #10 wr_en = 0;

        // Retrieve non-existent weight set
        #10 data_in = {6'h0C, 5'h04}; // Non-existent cluster/neuron ID
        wr_en = 1;
        #10 wr_en = 0;
        
        #150;
        $finish;
    end
    
endmodule