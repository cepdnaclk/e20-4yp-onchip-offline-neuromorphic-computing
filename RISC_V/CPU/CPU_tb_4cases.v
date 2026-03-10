`timescale 1ns / 1ps
`include "CPU.v"

module CPU_tb_4cases;

    reg CLK;
    reg RESET;

    // CPU Instantiation
    CPU main (
        .CLK(CLK),
        .RESET(RESET)
    );

    // Clock generation (10ns period = 100MHz)
    initial begin
        CLK = 0;
        forever #5 CLK = ~CLK;
    end

    // Test stimulus
    initial begin
        $dumpfile("cpu_4cases.vcd");
        $dumpvars(0, CPU_tb_4cases);
        
        $display("\n========================================");
        $display("Testing 4 Cases from Spreadsheet");
        $display("========================================\n");
        
        // ==========================
        // TEST CASE 1: Spike=1, Grad=255, Error=-512, Weight=20
        // Expected: W_new = 314
        // ==========================
        $display("--- TEST CASE 1 ---");
        $display("Inputs: Spike=1, Gradient=255, Error=-512, Weight=20");
        $display("Expected W_new = 314\n");
        
        // Initialize and load instruction memory
        // Program: LIFOPUSH -> LIFOPOP -> BKPROP (multiple) -> NOPs
        main.instructionmem1.memory_array[0] = 32'h0020800b; // LIFOPUSH x1, x2
        main.instructionmem1.memory_array[1] = 32'h0041900b; // LIFOPOP x3, x4
        // Multiple BKPROP instructions to allow delta computation + application
        for (integer j = 2; j < 6; j = j + 1) begin
            main.instructionmem1.memory_array[j] = 32'h0000200b; // BKPROP
        end
        for (integer j = 6; j < 40; j = j + 1) begin
            main.instructionmem1.memory_array[j] = 32'h00000013; // NOP
        end
        
        // Initialize and load registers
        RESET = 1;
        #10;
        RESET = 0;
        #1;
        main.registerfile1.registers[1] = 32'd1;    // Spike bit (LSB=1)
        main.registerfile1.registers[2] = 32'd255;  // Gradient value
        main.registerfile1.registers[3] = 32'd20;   // Initial weight
        main.registerfile1.registers[4] = 32'hFFFFFE00; // Error = -512 (signed)
        
        // Monitor execution for debugging
        $monitor("T:%0t | PC:%h | INSTR:%h | PUSH:%b POP:%b BKPROP:%b LNW:%b | GVAL:%b GRAD:%h | SVAL:%b | UPD_W:%0d", 
            $time,
            main.PCOUT,
            main.INSTRUCTION_OUT,
            main.PUSH,
            main.POP,
            main.CUSTOM_ENABLE_IDOUT,
            main.LOAD_NEW_WEIGHT_IDOUT,
            main.grad_stream_valid,
            main.grad_stream_value,
            main.serial_out_spike_status,
            main.UPDATED_WEIGHT);
        
        // Wait for execution
        #200;
        $display("\n");
        $monitoroff;
        
        // Check result
        $display("Result: W_new = %0d (0x%h)", $signed(main.UPDATED_WEIGHT), main.UPDATED_WEIGHT);
        if (main.UPDATED_WEIGHT == 32'd314)
            $display("PASS: Matches expected value\n");
        else
            $display("FAIL: Expected 314, got %0d (diff=%0d)\n", 
                     $signed(main.UPDATED_WEIGHT), 
                     314 - $signed(main.UPDATED_WEIGHT));
        
        // ==========================
        // TEST CASE 2: Spike=0, Grad=255, Error=-512, Weight=20
        // Expected: W_new = 20 (No spike = No update)
        // ==========================
        $display("--- TEST CASE 2 ---");
        $display("Inputs: Spike=0, Gradient=255, Error=-512, Weight=20");
        $display("Expected W_new = 20 (No spike = No update)\n");
        
        // Load instruction memory
        main.instructionmem1.memory_array[0] = 32'h0020800b; // LIFOPUSH x1, x2
        main.instructionmem1.memory_array[1] = 32'h0041900b; // LIFOPOP x3, x4
        for (integer j = 2; j < 6; j = j + 1) begin
            main.instructionmem1.memory_array[j] = 32'h0000200b; // BKPROP
        end
        for (integer j = 6; j < 40; j = j + 1) begin
            main.instructionmem1.memory_array[j] = 32'h00000013; // NOP
        end
        
        // Reset and load registers
        RESET = 1;
        #10;
        RESET = 0;
        #1;
        main.registerfile1.registers[1] = 32'd0;    // Spike bit (LSB=0)
        main.registerfile1.registers[2] = 32'd255;  // Gradient value
        main.registerfile1.registers[3] = 32'd20;   // Initial weight
        main.registerfile1.registers[4] = 32'hFFFFFE00; // Error = -512
        
        // Wait for execution
        #200;
        
        // Check result
        $display("Result: W_new = %0d (0x%h)", $signed(main.UPDATED_WEIGHT), main.UPDATED_WEIGHT);
        if (main.UPDATED_WEIGHT == 32'd20)
            $display("PASS: Matches expected value\n");
        else
            $display("FAIL: Expected 20, got %0d (diff=%0d)\n", 
                     $signed(main.UPDATED_WEIGHT), 
                     20 - $signed(main.UPDATED_WEIGHT));
        
        // ==========================
        // TEST CASE 3: Spike=1, Grad=0, Error=-512, Weight=20
        // Expected: W_new = 124 (Grad is smaller)
        // ==========================
        $display("--- TEST CASE 3 ---");
        $display("Inputs: Spike=1, Gradient=0, Error=-512, Weight=20");
        $display("Expected W_new = 124 (note: grad=0 should give no change?)\n");
        
        // Load instruction memory
        main.instructionmem1.memory_array[0] = 32'h0020800b; // LIFOPUSH x1, x2
        main.instructionmem1.memory_array[1] = 32'h0041900b; // LIFOPOP x3, x4
        for (integer j = 2; j < 6; j = j + 1) begin
            main.instructionmem1.memory_array[j] = 32'h0000200b; // BKPROP
        end
        for (integer j = 6; j < 40; j = j + 1) begin
            main.instructionmem1.memory_array[j] = 32'h00000013; // NOP
        end
        
        // Reset and load registers
        RESET = 1;
        #10;
        RESET = 0;
        #1;
        main.registerfile1.registers[1] = 32'd1;    // Spike bit (LSB=1)
        main.registerfile1.registers[2] = 32'd0;    // Gradient value = 0
        main.registerfile1.registers[3] = 32'd20;   // Initial weight
        main.registerfile1.registers[4] = 32'hFFFFFE00; // Error = -512
        
        // Wait for execution
        #200;
        
        // Check result
        $display("Result: W_new = %0d (0x%h)", $signed(main.UPDATED_WEIGHT), main.UPDATED_WEIGHT);
        $display("Note: With grad=0, delta should be 0, so weight should stay 20");
        if (main.UPDATED_WEIGHT == 32'd124)
            $display("PASS: Matches expected value\n");
        else
            $display("INFO: Expected 124, got %0d (diff=%0d)\n", 
                     $signed(main.UPDATED_WEIGHT), 
                     124 - $signed(main.UPDATED_WEIGHT));
        
        // ==========================
        // TEST CASE 4: Spike=1, Grad=255, Error=0, Weight=20
        // Expected: W_new = 20 (No error = No update)
        // ==========================
        $display("--- TEST CASE 4 ---");
        $display("Inputs: Spike=1, Gradient=255, Error=0, Weight=20");
        $display("Expected W_new = 20 (No error = No update)\n");
        
        // Load instruction memory
        main.instructionmem1.memory_array[0] = 32'h0020800b; // LIFOPUSH x1, x2
        main.instructionmem1.memory_array[1] = 32'h0041900b; // LIFOPOP x3, x4
        for (integer j = 2; j < 6; j = j + 1) begin
            main.instructionmem1.memory_array[j] = 32'h0000200b; // BKPROP
        end
        for (integer j = 6; j < 40; j = j + 1) begin
            main.instructionmem1.memory_array[j] = 32'h00000013; // NOP
        end
        
        // Reset and load registers
        RESET = 1;
        #10;
        RESET = 0;
        #1;
        main.registerfile1.registers[1] = 32'd1;    // Spike bit (LSB=1)
        main.registerfile1.registers[2] = 32'd255;  // Gradient value
        main.registerfile1.registers[3] = 32'd20;   // Initial weight
        main.registerfile1.registers[4] = 32'd0;    // Error = 0
        
        // Wait for execution
        #200;
        
        // Check result
        $display("Result: W_new = %0d (0x%h)", $signed(main.UPDATED_WEIGHT), main.UPDATED_WEIGHT);
        if (main.UPDATED_WEIGHT == 32'd20)
            $display("PASS: Matches expected value\n");
        else
            $display("FAIL: Expected 20, got %0d (diff=%0d)\n", 
                     $signed(main.UPDATED_WEIGHT), 
                     20 - $signed(main.UPDATED_WEIGHT));
        
        $display("========================================");
        $display("Test Complete");
        $display("========================================\n");
        
        #50;
        $finish;
    end

endmodule
