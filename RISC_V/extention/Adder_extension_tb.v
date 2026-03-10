`timescale 1ns / 1ps

module customCalculation_tb;
    reg clk, rst_n, enable,load_new_weight;
    reg signed [31:0] error_term, gradient_val, weight;
    wire signed [31:0] Updated_weight;

    customCalculation uut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .error_term(error_term), .gradient_val(gradient_val),
        .weight(weight), .load_new_weight(load_new_weight), .Updated_weight(Updated_weight)
    );

    always #5 clk = ~clk;


    initial begin
        $dumpfile("pipeline_sim.vcd");
        $dumpvars(0, customCalculation_tb);

        clk = 0; rst_n = 0; enable = 1; load_new_weight = 0;
        weight = 1000;
        
        #10 rst_n = 1;
        load_new_weight = 1;  // Load initial weight value
        enable =1;
        #10;
        load_new_weight = 0;  // Start calculations
        // Feed data continuously to test the pipeline
        error_term = 1024;  gradient_val = 256; #10; // Delta: 256
        error_term = 2048;  gradient_val = 256; #10; // Delta: 512
        error_term = 4096;  gradient_val = 256; #10; // Delta: 1024
        
        #20 $finish;
    end
endmodule