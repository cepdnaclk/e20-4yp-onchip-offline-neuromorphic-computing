`timescale 1ns / 1ps

module LIFO_Integration_tb;
    reg CLK, RESET;
    reg [31:0] DATA1, DATA2;
    wire serial_out1, busy1;
    wire serial_out2, busy2;

    // Instantiate the LIFO Buffers as they appear in your CPU
    // We use the same hardcoded PUSH=1'b1 as your CPU
    PISO_LIFO LIFO_Buffer_spike_status(
        .clk(CLK), .rst_n(!RESET), 
        .push(1'b1), .pop_trigger(1'b0), // Testing capture, so keep pop low
        .data_in(DATA1), .serial_out(serial_out1), .busy(busy1)
    );

    PISO_LIFO LIFO_Buffer_grad_value(
        .clk(CLK), .rst_n(!RESET), 
        .push(1'b1), .pop_trigger(1'b0), 
        .data_in(DATA2), .serial_out(serial_out2), .busy(busy2)
    );

    always #5 CLK = ~CLK;

    initial begin
        $dumpfile("lifo_capture_test.vcd");
        $dumpvars(0, LIFO_Integration_tb);

        // Initialization
        CLK = 0; RESET = 1; 
        DATA1 = 0; DATA2 = 0;
        #15 RESET = 0; // Release reset

        // Simulate Register File data changes
        repeat(5) begin
            DATA1 = $random;
            DATA2 = $random;
            #10; // Wait for one clock cycle capture
        end

        // Check if data was captured by triggering a pop
        // (You may need to force these ports if not externally accessible)
        $display("Data capture test complete. Check .vcd file to verify data_in matches internal stack storage.");
        #20 $finish;
    end
endmodule