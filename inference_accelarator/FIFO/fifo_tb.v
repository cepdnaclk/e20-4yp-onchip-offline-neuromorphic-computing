`timescale 1ns/1ps
`include "./fifo.v"

module fifo_tb;

    // Parameters
    parameter WIDTH = 11;
    parameter DEPTH = 8;
    
    // Signals
    reg clk;
    reg rst;
    reg wr_en;
    reg [WIDTH-1:0] din;
    reg rd_en;
    wire [WIDTH-1:0] dout;
    wire full;
    wire empty;
    wire [3:0] count;

    integer i;  // Loop variable for testing
    
    // Instantiate FIFO
    fifo #(
        .WIDTH(WIDTH),
        .DEPTH(DEPTH)
    ) uut (
        .clk(clk),
        .rst(rst),
        .wr_en(wr_en),
        .din(din),
        .rd_en(rd_en),
        .dout(dout),
        .full(full),
        .empty(empty),
        .count(count)
    );
    
    // Clock generation (100MHz)
    always #5 clk = ~clk;
    
    // Test stimulus
    initial begin
        $dumpfile("fifo_tb.vcd");
        $dumpvars(0, fifo_tb);

        // Initialize
        clk = 0;
        rst = 1;  // Start with reset active
        wr_en = 0;
        din = 0;
        rd_en = 0;
        
        // Reset sequence
        #20;
        rst = 0;  // Deassert reset
        #10;
        
        // Test 1: Basic write and read
        $display("Test 1: Basic write and read");
        wr_en = 1;
        din = 11'h123;
        #10;
        wr_en = 0;
        #10;
        rd_en = 1;
        #10;
        if (dout !== 11'h123)
            $error("Read data mismatch! Expected 123, got %h", dout);
        rd_en = 0;
        #20;
        
        // Test 2: Fill the FIFO
        $display("Test 2: Fill the FIFO");
        for (i = 0; i < DEPTH; i = i + 1) begin
            wr_en = 1;
            din = 11'h100 + i;
            #10;
        end
        wr_en = 0;
        if (!full)
            $error("FIFO should be full!");
        #20;
        
        // Test 3: Reset test
        $display("Test 3: Reset test");
        rst = 1;
        #10;
        if (!empty || count != 0)
            $error("FIFO not properly reset!");
        rst = 0;
        #20;
        
        // Test 4: Simultaneous read and write
        $display("Test 4: Simultaneous read and write");
        // First write some data
        wr_en = 1;
        din = 11'h200;
        #10;
        din = 11'h201;
        #10;
        wr_en = 0;
        #10;
        // Then do simultaneous operations
        wr_en = 1;
        rd_en = 1;
        din = 11'h202;
        #10;
        if (dout !== 11'h200)
            $error("Read during simultaneous op mismatch! Expected 200, got %h", dout);
        wr_en = 0;
        rd_en = 0;
        #20;
        
        $display("All tests completed");
        $finish;
    end
    
    // Monitor
    always @(posedge clk) begin
        $display("[%0t] Rst: %b, WrEn: %b, Din: %h, RdEn: %b, Dout: %h, Full: %b, Empty: %b, Count: %0d",
                $time, rst, wr_en, din, rd_en, dout, full, empty, count);
    end
    
endmodule