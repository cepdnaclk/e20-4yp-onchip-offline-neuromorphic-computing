`timescale 1ns/1ps

module soc_tb;
    reg clk;
    reg rst;
    wire accelerator_done;

    soc_top uut (
        .clk(clk),
        .rst(rst),
        .accelerator_done(accelerator_done)
    );

    // Clock
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Test Sequence
    initial begin
        $dumpfile("soc_tb.vcd");
        $dumpvars(0, soc_tb);
        
        // Initialize Memory with Firmware
        // We will generate a hex file 'firmware.hex' using the assembler
        $readmemh("firmware.hex", uut.ram);
        
        rst = 1;
        #20;
        rst = 0;
        
        $display("Simulation Started...");
        
        // Wait for some time or condition
        #50000;
        
        $display("Simulation Timeout.");
        $finish;
    end
    
endmodule
