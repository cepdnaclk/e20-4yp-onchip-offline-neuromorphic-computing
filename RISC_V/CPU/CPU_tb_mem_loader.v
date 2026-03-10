`timescale 1ns/100ps
`include "CPU.v"

module CPU_tb_mem_loader;

    reg CLK, RESET;
    
    // Instantiate CPU
    CPU main(CLK, RESET);
    
    integer i;
    
    // Clock generation
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end
    
    // Initialize memory with gradient and spike data
    initial begin
        // Initialize instruction memory with test program
        for (i = 0; i < 256; i = i + 1) begin
            main.instructionmem1.memory_array[i] = 32'h0000_0013; // NOP (addi x0, x0, 0)
        end
        
        // Initialize data memory with test patterns
        // Data memory is byte-addressed (8-bit entries)
        
        // Memory region 0x100-0x13F: 16 gradient values (16-bit signed, stored as 32-bit words little-endian)
        // Using pattern: [255, 128, 0, -128, 100, 50, 25, 12, 6, 3, 1, 0, -50, -100, 200, 150]
        // Address 0x100 = word index 64 = byte indices 256-259
        main.datamemory1.memory_array[256] = 8'd255;  // grad[0] LSB
        main.datamemory1.memory_array[257] = 8'd0;    // grad[0] byte1
       main.datamemory1.memory_array[258] = 8'd0;    // grad[0] byte2
        main.datamemory1.memory_array[259] = 8'd0;    // grad[0] MSB
        
        main.datamemory1.memory_array[260] = 8'd128;  // grad[1]
        main.datamemory1.memory_array[261] = 8'd0;
        main.datamemory1.memory_array[262] = 8'd0;
        main.datamemory1.memory_array[263] = 8'd0;
        
        main.datamemory1.memory_array[264] = 8'd0;    // grad[2]
        main.datamemory1.memory_array[265] = 8'd0;
        main.datamemory1.memory_array[266] = 8'd0;
        main.datamemory1.memory_array[267] = 8'd0;
        
        main.datamemory1.memory_array[268] = 8'd128;  // grad[3] = -128 (two's complement)
        main.datamemory1.memory_array[269] = 8'd255;
        main.datamemory1.memory_array[270] = 8'd255;
        main.datamemory1.memory_array[271] = 8'd255;
        
        main.datamemory1.memory_array[272] = 8'd100;  // grad[4]
        main.datamemory1.memory_array[273] = 8'd0;
        main.datamemory1.memory_array[274] = 8'd0;
        main.datamemory1.memory_array[275] = 8'd0;
        
        main.datamemory1.memory_array[276] = 8'd50;   // grad[5]
        main.datamemory1.memory_array[277] = 8'd0;
        main.datamemory1.memory_array[278] = 8'd0;
        main.datamemory1.memory_array[279] = 8'd0;
        
        main.datamemory1.memory_array[280] = 8'd25;   // grad[6]
        main.datamemory1.memory_array[281] = 8'd0;
        main.datamemory1.memory_array[282] = 8'd0;
        main.datamemory1.memory_array[283] = 8'd0;
        
        main.datamemory1.memory_array[284] = 8'd12;   // grad[7]
        main.datamemory1.memory_array[285] = 8'd0;
        main.datamemory1.memory_array[286] = 8'd0;
        main.datamemory1.memory_array[287] = 8'd0;
        
        main.datamemory1.memory_array[288] = 8'd6;    // grad[8]
        main.datamemory1.memory_array[289] = 8'd0;
        main.datamemory1.memory_array[290] = 8'd0;
        main.datamemory1.memory_array[291] = 8'd0;
        
        main.datamemory1.memory_array[292] = 8'd3;    // grad[9]
        main.datamemory1.memory_array[293] = 8'd0;
        main.datamemory1.memory_array[294] = 8'd0;
        main.datamemory1.memory_array[295] = 8'd0;
        
        main.datamemory1.memory_array[296] = 8'd1;    // grad[10]
        main.datamemory1.memory_array[297] = 8'd0;
        main.datamemory1.memory_array[298] = 8'd0;
        main.datamemory1.memory_array[299] = 8'd0;
        
        main.datamemory1.memory_array[300] = 8'd0;    // grad[11]
        main.datamemory1.memory_array[301] = 8'd0;
        main.datamemory1.memory_array[302] = 8'd0;
        main.datamemory1.memory_array[303] = 8'd0;
        
        main.datamemory1.memory_array[304] = 8'd206;  // grad[12] = -50 (two's complement)
        main.datamemory1.memory_array[305] = 8'd255;
        main.datamemory1.memory_array[306] = 8'd255;
        main.datamemory1.memory_array[307] = 8'd255;
        
        main.datamemory1.memory_array[308] = 8'd156;  // grad[13] = -100 (two's complement)
        main.datamemory1.memory_array[309] = 8'd255;
        main.datamemory1.memory_array[310] = 8'd255;
        main.datamemory1.memory_array[311] = 8'd255;
        
        main.datamemory1.memory_array[312] = 8'd200;  // grad[14]
        main.datamemory1.memory_array[313] = 8'd0;
        main.datamemory1.memory_array[314] = 8'd0;
        main.datamemory1.memory_array[315] = 8'd0;
        
        main.datamemory1.memory_array[316] = 8'd150;  // grad[15]
        main.datamemory1.memory_array[317] = 8'd0;
        main.datamemory1.memory_array[318] = 8'd0;
        main.datamemory1.memory_array[319] = 8'd0;
        
        // Memory region 0x200-0x23F: 16 spike words (each 32-bit word represents spike status)
        // Address 0x200 = word index 128 = byte indices 512-515
        // Pattern: alternating 1s and 0s, then all 1s, then all 0s
        main.datamemory1.memory_array[512] = 8'd1;    // spike[0] = 1
        main.datamemory1.memory_array[513] = 8'd0;
        main.datamemory1.memory_array[514] = 8'd0;
        main.datamemory1.memory_array[515] = 8'd0;
        
        main.datamemory1.memory_array[516] = 8'd0;    // spike[1] = 0
        main.datamemory1.memory_array[517] = 8'd0;
        main.datamemory1.memory_array[518] = 8'd0;
        main.datamemory1.memory_array[519] = 8'd0;
        
        main.datamemory1.memory_array[520] = 8'd1;    // spike[2] = 1
        main.datamemory1.memory_array[521] = 8'd0;
        main.datamemory1.memory_array[522] = 8'd0;
        main.datamemory1.memory_array[523] = 8'd0;
        
        main.datamemory1.memory_array[524] = 8'd0;    // spike[3] = 0
        main.datamemory1.memory_array[525] = 8'd0;
        main.datamemory1.memory_array[526] = 8'd0;
        main.datamemory1.memory_array[527] = 8'd0;
        
        main.datamemory1.memory_array[528] = 8'd1;    // spike[4] = 1
        main.datamemory1.memory_array[529] = 8'd0;
        main.datamemory1.memory_array[530] = 8'd0;
        main.datamemory1.memory_array[531] = 8'd0;
        
        main.datamemory1.memory_array[532] = 8'd1;    // spike[5] = 1
        main.datamemory1.memory_array[533] = 8'd0;
        main.datamemory1.memory_array[534] = 8'd0;
        main.datamemory1.memory_array[535] = 8'd0;
        
        main.datamemory1.memory_array[536] = 8'd1;    // spike[6] = 1
        main.datamemory1.memory_array[537] = 8'd0;
        main.datamemory1.memory_array[538] = 8'd0;
        main.datamemory1.memory_array[539] = 8'd0;
        
        main.datamemory1.memory_array[540] = 8'd1;    // spike[7] = 1
        main.datamemory1.memory_array[541] = 8'd0;
        main.datamemory1.memory_array[542] = 8'd0;
        main.datamemory1.memory_array[543] = 8'd0;
        
        main.datamemory1.memory_array[544] = 8'd0;    // spike[8] = 0
        main.datamemory1.memory_array[545] = 8'd0;
        main.datamemory1.memory_array[546] = 8'd0;
        main.datamemory1.memory_array[547] = 8'd0;
        
        main.datamemory1.memory_array[548] = 8'd0;    // spike[9] = 0
        main.datamemory1.memory_array[549] = 8'd0;
        main.datamemory1.memory_array[550] = 8'd0;
        main.datamemory1.memory_array[551] = 8'd0;
        
        main.datamemory1.memory_array[552] = 8'd0;    // spike[10] = 0
        main.datamemory1.memory_array[553] = 8'd0;
        main.datamemory1.memory_array[554] = 8'd0;
        main.datamemory1.memory_array[555] = 8'd0;
        
        main.datamemory1.memory_array[556] = 8'd0;    // spike[11] = 0
        main.datamemory1.memory_array[557] = 8'd0;
        main.datamemory1.memory_array[558] = 8'd0;
        main.datamemory1.memory_array[559] = 8'd0;
        
        main.datamemory1.memory_array[560] = 8'd1;    // spike[12] = 1
        main.datamemory1.memory_array[561] = 8'd0;
        main.datamemory1.memory_array[562] = 8'd0;
        main.datamemory1.memory_array[563] = 8'd0;
        
        main.datamemory1.memory_array[564] = 8'd1;    // spike[13] = 1
        main.datamemory1.memory_array[565] = 8'd0;
        main.datamemory1.memory_array[566] = 8'd0;
        main.datamemory1.memory_array[567] = 8'd0;
        
        main.datamemory1.memory_array[568] = 8'd0;    // spike[14] = 0
        main.datamemory1.memory_array[569] = 8'd0;
        main.datamemory1.memory_array[570] = 8'd0;
        main.datamemory1.memory_array[571] = 8'd0;
        
        main.datamemory1.memory_array[572] = 8'd1;    // spike[15] = 1
        main.datamemory1.memory_array[573] = 8'd0;
        main.datamemory1.memory_array[574] = 8'd0;
        main.datamemory1.memory_array[575] = 8'd0;
        
        // Test Program - OPTIMIZED SEQUENCE:
        // 1. Load registers with ADDI instructions
        // 2. LIFOPUSH spike pattern (register → spike LIFO, 1 cycle)
        // 3. LIFOPUSHMG gradient data (memory → gradient LIFO, ~62 cycles in parallel)
        // 4. LIFOPOP with weight and error to start computation
        
        // This saves ~62 NOPs by doing spike load in parallel with gradient load!
        
        // Load immediate values into registers
        // lui x1, 0  then addi x1, x1, 256 (0x100 - gradient base address)
        main.instructionmem1.memory_array[0] = {20'b0, 5'd1, 7'b0110111}; 
        main.instructionmem1.memory_array[1] = {12'd256, 5'd1, 3'b000, 5'd1, 7'b0010011};
        
        // addi x2, x0, 16 - count
        main.instructionmem1.memory_array[2] = {12'd16, 5'd0, 3'b000, 5'd2, 7'b0010011};
        
        // x3 already initialized with spike pattern 0xB0F5 = 45301
        
        // addi x4, x0, -512 - error term
        main.instructionmem1.memory_array[3] = {12'hE00, 5'd0, 3'b000, 5'd4, 7'b0010011};
        
        // addi x5, x0, 20 - initial weight  
        main.instructionmem1.memory_array[4] = {12'd20, 5'd0, 3'b000, 5'd5, 7'b0010011};
        
        // LIFOPUSH x3, x0 - Push spike pattern from x3 to spike LIFO (DATA1)
        // Format: {7'b0000000, rs2[4:0], rs1[4:0], 3'b000, rd[4:0], 7'b0001011}
        // DATA1=x3 goes to spike LIFO, DATA2=x0 goes to gradient LIFO (ignored, will be replaced by memory load)
        main.instructionmem1.memory_array[5] = {7'b0000000, 5'd0, 5'd3, 3'b000, 5'd0, 7'b0001011};
        
        // LIFOPUSHMG x1, x2 - Load gradient data from memory (happens in parallel conceptually, but sequentially in pipeline)
        main.instructionmem1.memory_array[6] = {7'b0000000, 5'd2, 5'd1, 3'b101, 5'd0, 7'b0001011};
        
        // Wait for gradient loader to complete (~62 NOPs)
        for (i = 7; i < 69; i = i + 1) begin
            main.instructionmem1.memory_array[i] = 32'h0000_0013;  // NOP
        end
        
        // LIFOPOP x5, x4 (start streaming + load weight from x5 + load error from x4 + enable computation)
        // Does NOT write back immediately - computation takes 17 cycles
        main.instructionmem1.memory_array[69] = {7'b0000000, 5'd4, 5'd5, 3'b001, 5'd0, 7'b0001011};
        
        // NOPs to allow streaming and computation (17+ cycles)
        for (i = 70; i < 87; i = i + 1) begin
            main.instructionmem1.memory_array[i] = 32'h0000_0013; // NOP
        end
        
        // LIFOWB x6 - Write computed weight from custom unit to register x6
        main.instructionmem1.memory_array[87] = {7'b0000000, 5'd0, 5'd0, 3'b110, 5'd6, 7'b0001011};
        
        // More NOPs for safety
        for (i = 88; i < 110; i = i + 1) begin
            main.instructionmem1.memory_array[i] = 32'h0000_0013; // NOP
        end
    end
    
    // Stimulus and monitoring
    initial begin
        $dumpfile("cpu_mem_loader.vcd");
        $dumpvars(0, CPU_tb_mem_loader);
        
        // Monitor key signals with computation details
        $monitor("Time=%0t grad_valid=%b spike=%b weight=%d grad_val=%d delta=%d apply_d=%b CW_ID=%b CW_EX=%b CW_MEM=%b WE_MEM=%b WA_MEM=%d UW_MEM=%d WD=%d", 
                 $time,
                 main.grad_stream_valid,
                 main.serial_out_spike_status,
                 main.UPDATED_WEIGHT,
                 main.grad_stream_value,
                 main.custom_unit.delta_out,
                 main.custom_unit.apply_update_d,
                 main.CUSTOM_WRITEBACK_IDOUT,
                 main.CUSTOM_WRITEBACK_EXOUT,
                 main.CUSTOM_WRITEBACK_MEMOUT,
                 main.WRITEENABLE_MEMOUT,
                 main.WRITEADDRESS_MEMOUT,
                 main.UPDATED_WEIGHT_MEMOUT,
                 main.WRITEDATA);
        
        // Reset
        RESET = 1'b1;
        #15;
        RESET = 1'b0;
        
        // Initialize x3 with spike pattern directly (after reset stabilizes)
        // Spike pattern: [1,0,1,0,1,1,1,1,0,0,0,0,1,1,0,1] = 0xB0F5 = 45301
        #2;
        main.registerfile1.registers[3] = 32'd45301;
        
        // Run for enough cycles to complete:
        // - Register initialization: ~5 cycles
        // - LIFOPUSH (spike): 1 cycle
        // - LIFOPUSHMG (gradient): ~62 cycles
        // - LIFOPOP + streaming: ~20 cycles
        // - LIFOWB: 4 cycles (through pipeline)
        // Total: ~95 cycles × 10ns = 950ns, use 1800ns for safety
        #1800;
        
        // Check final weight and writeback
        $display("\n=== Test Results ===");
        $display("Final weight (custom unit): %d", main.UPDATED_WEIGHT);
        $display("WRITEDATA (to register file): %d", main.WRITEDATA);
        $display("Register x6 value (updated weight): %d", main.registerfile1.registers[6]);
        $display("Register x5 value (initial weight): %d", main.registerfile1.registers[5]);
        $display("WRITEBACK_SELECT: %b", main.writeback_select);
        $display("CUSTOM_WRITEBACK_MEMOUT: %b", main.CUSTOM_WRITEBACK_MEMOUT);
        $display("WRITEENABLE_MEMOUT: %b", main.WRITEENABLE_MEMOUT);
        $display("WRITEADDRESS_MEMOUT: %d", main.WRITEADDRESS_MEMOUT);
        $display("Loader busy: %b", main.mem_loader_busy);
        $display("Loader done: %b", main.mem_loader_done);
        
        $finish;
    end

endmodule
