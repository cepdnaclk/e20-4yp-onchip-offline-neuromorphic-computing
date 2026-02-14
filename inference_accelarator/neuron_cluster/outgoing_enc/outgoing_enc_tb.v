`include "./outgoing_enc.v"
`include "../../FIFO/fifo.v"
`timescale 1ns/1ps

module outgoing_enc_tb;
    // Parameters
    parameter neurons_can_handle = 32;  // Configurable network size
    parameter packet_width = 11;
    parameter cluster_id = 0;
    parameter packet_size = 8; // Size of the packet in bits
    parameter fifo_depth = 8; // Depth of the FIFO buffer
    
    // Inputs
    reg clk;
    reg rst;
    reg spikes_done;                          // Indicates spike vector is valid
    reg [neurons_can_handle-1:0] spikes;  // Spike vector from neurons
    reg [neurons_can_handle-1:0] neuron_mask_in;
    reg load_neuron_mask;
    reg chip_mode;

    // fifo
    wire fifo_full; // FIFO full signal
    wire [$clog2(fifo_depth):0] fifo_count; // FIFO count signal
    wire [packet_width-1:0] fifo_dout; // FIFO output data (not used in this test)
    wire fifo_empty; // FIFO empty signal
    reg fifo_rd_en; // FIFO read enable (not used in this test)


    // Outputs
    wire [packet_width-1:0] packet;
    wire fifo_wr_en;

    fifo #(
        .WIDTH(packet_width),
        .DEPTH(fifo_depth) // Example depth, can be adjusted
    ) fifo_inst (
        .clk(clk),
        .rst(rst),
        .wr_en(fifo_wr_en),
        .din(packet),
        .rd_en(fifo_rd_en), // Read enable not used in this test
        .dout(fifo_dout), // Not used in this test
        .full(fifo_full),
        .empty(fifo_empty),
        .count(fifo_count)
    );

    // Instantiate the Unit Under Test (UUT)
    outgoing_enc #(
        .neurons_can_handle(neurons_can_handle),
        .packet_width(packet_width),
        .cluster_id(cluster_id)
    ) uut (
        .clk(clk),
        .rst(rst),
        .neuron_mask_in(neuron_mask_in),
        .load_neuron_mask(load_neuron_mask),
        .chip_mode(chip_mode),
        .fifo_full(fifo_full), 
        .spikes_done(spikes_done),
        .spikes(spikes),
        .packet(packet),
        .wr_en(fifo_wr_en)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 10 ns clock period
    end

    // Testbench stimulus
    initial begin
        $dumpfile("outgoing_enc_tb.vcd");
        $dumpvars(0, outgoing_enc_tb);

        // Initialize inputs
        rst = 1;
        spikes_done = 0;
        spikes = 0;
        neuron_mask_in = 0;
        load_neuron_mask = 0;
        chip_mode = 0;
        fifo_rd_en = 0; // Initially disable FIFO read

        #10 rst = 0; // Release reset

        chip_mode = 1; // Enable chip mode
        #10
        neuron_mask_in = 32'b0000_0000_0101_1111_0001_1111_0001_1111;
        load_neuron_mask = 1; // Load neuron mask
        #10 load_neuron_mask = 0; // Clear load_neuron_mask

        #20 chip_mode = 0; // Disable chip mode

        // Test case 1: Send a spike vector
        #10 spikes = 32'b0000_0000_0001_0000_0000_0000_0000_0001; // First neuron spikes
        spikes_done = 1; // Indicate spikes are valid
        #10 spikes_done = 0; // Clear spikes_done

        #500;
        #10 spikes = 32'b1111_1111_1111_1111_1111_1111_1111_1111; // Second neuron spikes
        spikes_done = 1; // Indicate spikes are valid
        #10 spikes_done = 0; // Clear spikes_done

        #1000
        $finish; // End simulation
    end

    always @(*) begin
        if (fifo_full) begin
            #50 fifo_rd_en = 1; // Enable FIFO read if full
        end
    end

endmodule