`timescale 1ns / 1ps

module custom_backprop_unit_tb;

    // --- 1. Signal Declarations ---
    reg         clk;
    reg         rst_n;
    reg         enable;
    reg  signed [31:0] error_term;
    reg  signed [31:0] gradient_val;
    wire signed [31:0] delta_out;

    // --- 2. Instantiate the Unit Under Test (UUT) ---
    custom_backprop_unit uut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .error_term(error_term),
        .gradient_val(gradient_val),
        .delta_out(delta_out)
    );

    // --- 3. Clock Generation (10ns period = 100MHz) ---
    always #5 clk = ~clk;

    // --- 4. Stimulus Block ---
    initial begin
        // Initialize Signals
        clk = 0;
        rst_n = 0;
        enable = 0;
        error_term = 0;
        gradient_val = 0;

        // Setup GTKWave Dumping
        $dumpfile("backprop_sim.vcd");
        $dumpvars(0, custom_backprop_unit_tb);

        // Reset Sequence
        #20 rst_n = 1;
        #10 enable = 1;

        // Test Case 1: Simple Positive Values
        // (1024 >> 2) * 256 >> 8  =>  256 * 256 >> 8 = 256
        error_term = 32'd1024; 
        gradient_val = 32'd256;
        #10; 
        $display("Time: %t | Error: %d | Grad: %d | Delta: %d", $time, error_term, gradient_val, delta_out);

        // Test Case 2: Negative Error (Testing Arithmetic Shift)
        // (-1024 >> 2) * 256 >> 8 => -256 * 256 >> 8 = -256
        error_term = -32'd1024;
        gradient_val = 32'd256;
        #10;
        $display("Time: %t | Error: %d | Grad: %d | Delta: %d", $time, error_term, gradient_val, delta_out);

        // Test Case 3: Large Product (Testing 64-bit internal width)
        error_term = 32'd40000;
        gradient_val = 32'd20000;
        #10;
        $display("Time: %t | Error: %d | Grad: %d | Delta: %d", $time, error_term, gradient_val, delta_out);

        // Test Case 4: Disable signal (Output should not change)
        enable = 0;
        error_term = 32'd0;
        #10;
        $display("Time: %t | (Disabled) Error: %d | Delta: %d", $time, error_term, delta_out);

        #50;
        $finish;
    end

endmodule