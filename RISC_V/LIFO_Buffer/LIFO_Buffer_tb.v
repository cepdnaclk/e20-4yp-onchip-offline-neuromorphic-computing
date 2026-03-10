`timescale 1ns / 1ps

module PISO_LIFO_tb;
    reg clk, rst_n;
    reg push, pop_trigger;
    reg [31:0] data_in;
    wire serial_out, busy;

    // Instantiate only the buffer
    PISO_LIFO uut (
        .clk(clk), .rst_n(rst_n),
        .push(push), .pop_trigger(pop_trigger),
        .data_in(data_in),
        .serial_out(serial_out),
        .busy(busy)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("buffer_test.vcd");
        $dumpvars(0, PISO_LIFO_tb);

        // Initialization
        clk = 0; rst_n = 0; push = 0; pop_trigger = 0;
        data_in = 0;
        #10 rst_n = 1;

        // 1. Push data into the stack
        data_in = 32'hA5A5A5A5; // 10100101...
        push = 1; #20;
        push = 0; #10;

        // 2. Trigger serialization
        pop_trigger = 1; #10;
        pop_trigger = 0;

        // 3. Observe the serial output
        // The 'busy' signal will stay high for 32 clock cycles
        wait(!busy); 

        #20 $finish;
    end
endmodule