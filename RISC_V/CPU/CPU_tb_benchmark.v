`timescale 1ns/100ps
`include "CPU.v"

// ============================================================================
// Benchmark Testbench: Custom Unit vs Software Backpropagation
//
// Two programs run back-to-back on the same CPU:
//   PHASE 1  -  Custom unit path  (LIFOPUSH → LIFOPUSHMG → LIFOPOP → LIFOWB)
//   PHASE 2  -  Pure RISC-V path  (LW/MUL/ADD loop doing the same math)
//
// Test data: spike=0xB0F5, 16 gradients, error=-512, initial_weight=20
// Phase 1 (custom unit): simple STDP on spike-active neurons only
// Phase 2 (software RV32I): full stateful backprop with delta accumulation
//
// Cycle counter is started and stopped with $time for each phase.
// Summary is printed at the end.
// ============================================================================

module CPU_tb_benchmark;

    reg CLK, RESET;

    CPU main(CLK, RESET);

    integer i;

    // ── cycle / time stamping ────────────────────────────────────────────────
    real t_custom_start, t_custom_end;
    real t_soft_start,   t_soft_end;

    // ── clock ────────────────────────────────────────────────────────────────
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;      // 10 ns period = 100 MHz
    end

    // ========================================================================
    //  Memory Initialisation
    //  Gradients @ 0x100 (byte 256), spikes @ 0x200 (byte 512)
    //  Same data used by both programs.
    // ========================================================================
    initial begin
        // ── clear instruction memory ─────────────────────────────────────
        for (i = 0; i < 512; i = i + 1)
            main.instructionmem1.memory_array[i] = 32'h0000_0013; // NOP

        // ── load gradient values into data memory @ byte 256 (0x100) ─────
        // grad[0]=200, [1]=-100, [2]=-50, [3]=0, [4]=1, [5]=3,
        // [6]=6, [7]=12, [8]=25, [9]=50, [10]=100, [11]=-128,
        // [12]=0, [13]=128, [14]=255, [15]=0
        // Stored little-endian 32-bit words
        // grad[0] = 200
        main.datamemory1.memory_array[256] = 8'd200; main.datamemory1.memory_array[257] = 8'd0; main.datamemory1.memory_array[258] = 8'd0; main.datamemory1.memory_array[259] = 8'd0;
        // grad[1] = -100 = 0xFFFFFF9C
        main.datamemory1.memory_array[260] = 8'h9C;  main.datamemory1.memory_array[261] = 8'hFF; main.datamemory1.memory_array[262] = 8'hFF; main.datamemory1.memory_array[263] = 8'hFF;
        // grad[2] = -50 = 0xFFFFFFCE
        main.datamemory1.memory_array[264] = 8'hCE;  main.datamemory1.memory_array[265] = 8'hFF; main.datamemory1.memory_array[266] = 8'hFF; main.datamemory1.memory_array[267] = 8'hFF;
        // grad[3] = 0
        main.datamemory1.memory_array[268] = 8'd0;   main.datamemory1.memory_array[269] = 8'd0;  main.datamemory1.memory_array[270] = 8'd0;  main.datamemory1.memory_array[271] = 8'd0;
        // grad[4] = 1
        main.datamemory1.memory_array[272] = 8'd1;   main.datamemory1.memory_array[273] = 8'd0;  main.datamemory1.memory_array[274] = 8'd0;  main.datamemory1.memory_array[275] = 8'd0;
        // grad[5] = 3
        main.datamemory1.memory_array[276] = 8'd3;   main.datamemory1.memory_array[277] = 8'd0;  main.datamemory1.memory_array[278] = 8'd0;  main.datamemory1.memory_array[279] = 8'd0;
        // grad[6] = 6
        main.datamemory1.memory_array[280] = 8'd6;   main.datamemory1.memory_array[281] = 8'd0;  main.datamemory1.memory_array[282] = 8'd0;  main.datamemory1.memory_array[283] = 8'd0;
        // grad[7] = 12
        main.datamemory1.memory_array[284] = 8'd12;  main.datamemory1.memory_array[285] = 8'd0;  main.datamemory1.memory_array[286] = 8'd0;  main.datamemory1.memory_array[287] = 8'd0;
        // grad[8] = 25
        main.datamemory1.memory_array[288] = 8'd25;  main.datamemory1.memory_array[289] = 8'd0;  main.datamemory1.memory_array[290] = 8'd0;  main.datamemory1.memory_array[291] = 8'd0;
        // grad[9] = 50
        main.datamemory1.memory_array[292] = 8'd50;  main.datamemory1.memory_array[293] = 8'd0;  main.datamemory1.memory_array[294] = 8'd0;  main.datamemory1.memory_array[295] = 8'd0;
        // grad[10] = 100
        main.datamemory1.memory_array[296] = 8'd100; main.datamemory1.memory_array[297] = 8'd0;  main.datamemory1.memory_array[298] = 8'd0;  main.datamemory1.memory_array[299] = 8'd0;
        // grad[11] = -128 = 0xFFFFFF80
        main.datamemory1.memory_array[300] = 8'h80;  main.datamemory1.memory_array[301] = 8'hFF; main.datamemory1.memory_array[302] = 8'hFF; main.datamemory1.memory_array[303] = 8'hFF;
        // grad[12] = 0
        main.datamemory1.memory_array[304] = 8'd0;   main.datamemory1.memory_array[305] = 8'd0;  main.datamemory1.memory_array[306] = 8'd0;  main.datamemory1.memory_array[307] = 8'd0;
        // grad[13] = 128
        main.datamemory1.memory_array[308] = 8'd128; main.datamemory1.memory_array[309] = 8'd0;  main.datamemory1.memory_array[310] = 8'd0;  main.datamemory1.memory_array[311] = 8'd0;
        // grad[14] = 255
        main.datamemory1.memory_array[312] = 8'd255; main.datamemory1.memory_array[313] = 8'd0;  main.datamemory1.memory_array[314] = 8'd0;  main.datamemory1.memory_array[315] = 8'd0;
        // grad[15] = 0
        main.datamemory1.memory_array[316] = 8'd0;   main.datamemory1.memory_array[317] = 8'd0;  main.datamemory1.memory_array[318] = 8'd0;  main.datamemory1.memory_array[319] = 8'd0;
    end

    // ========================================================================
    //  PHASE 1 — Custom Unit Program
    //  Instruction memory [0..127]
    //
    //  Registers used:
    //    x1 = base addr of gradients (0x100)
    //    x2 = count (16)
    //    x3 = spike pattern (0xB0F5)
    //    x4 = error term (-512)
    //    x5 = initial weight (20)
    //    x6 = result (written back by LIFOWB)
    // ========================================================================
    initial begin
        // ── init ─────────────────────────────────────────────────────────
        // addi x1, x0, 0x100
        main.instructionmem1.memory_array[0]  = {12'h100,  5'd0, 3'b000, 5'd1,  7'b0010011};
        // addi x2, x0, 16
        main.instructionmem1.memory_array[1]  = {12'd16,   5'd0, 3'b000, 5'd2,  7'b0010011};
        // lui x3, 0 then addi x3, x3, 0xB0F5 — spike pattern too large for 12-bit imm
        // Use two instructions: lui  + addi. 0xB0F5 = 45301
        //   upper 20 bits of 45301 = 0x0000B → lui x3, 0xB
        //   lower 12 bits          = 0x0F5   = 245
        main.instructionmem1.memory_array[2]  = {20'h0000B, 5'd3, 7'b0110111};  // lui x3, 0xB
        main.instructionmem1.memory_array[3]  = {12'h0F5,   5'd3, 3'b000, 5'd3, 7'b0010011}; // addi x3,x3,0xF5
        // addi x4, x0, -512
        main.instructionmem1.memory_array[4]  = {12'hE00,   5'd0, 3'b000, 5'd4,  7'b0010011};
        // addi x5, x0, 20
        main.instructionmem1.memory_array[5]  = {12'd20,    5'd0, 3'b000, 5'd5,  7'b0010011};

        // ── LIFOPUSH x3 (spike → spike LIFO)  funct3=000, rs1=3, rs2=0 ──
        main.instructionmem1.memory_array[6]  = {7'b0000000, 5'd0, 5'd3, 3'b000, 5'd0, 7'b0001011};

        // ── LIFOPUSHMG x1, x2 (gradient mem → grad LIFO)  funct3=101 ────
        main.instructionmem1.memory_array[7]  = {7'b0000000, 5'd2, 5'd1, 3'b101, 5'd0, 7'b0001011};

        // ── 62 NOPs for gradient loader ───────────────────────────────────
        for (i = 8; i < 70; i = i + 1)
            main.instructionmem1.memory_array[i] = 32'h0000_0013;

        // ── LIFOPOP x5, x4 (start streaming + weight + error) funct3=001 ─
        main.instructionmem1.memory_array[70] = {7'b0000000, 5'd4, 5'd5, 3'b001, 5'd0, 7'b0001011};

        // ── 17 NOPs for computation ───────────────────────────────────────
        for (i = 71; i < 88; i = i + 1)
            main.instructionmem1.memory_array[i] = 32'h0000_0013;

        // ── LIFOWB x6  (writeback result)  funct3=110, rd=6 ──────────────
        main.instructionmem1.memory_array[88] = {7'b0000000, 5'd0, 5'd0, 3'b110, 5'd6, 7'b0001011};

        // ── sentinel NOP block (Phase 1 ends after x6 is written) ────────
        for (i = 89; i < 128; i = i + 1)
            main.instructionmem1.memory_array[i] = 32'h0000_0013;
    end

    // ========================================================================
    //  NOTE: Phase 2 program is loaded dynamically in the stimulus block
    //  (after Phase 1 completes and CPU is reset) at instruction indices 0..82.
    // ========================================================================

    // ========================================================================
    //  Stimulus, timing, and result reporting
    // ========================================================================
    initial begin
        $dumpfile("cpu_benchmark.vcd");
        $dumpvars(0, CPU_tb_benchmark);

        // ─────────────────────────────────────────────────────────────────
        // PHASE 1: Custom Unit
        // ─────────────────────────────────────────────────────────────────
        $display("\n========================================");
        $display("PHASE 1: Custom Unit Backpropagation");
        $display("========================================");

        RESET = 1;
        #15 RESET = 0;

        // Wait for first instruction to enter pipeline
        repeat(5) @(posedge CLK);
        t_custom_start = $realtime;
        $display("Custom unit START at %0t ns", t_custom_start);

        // Poll until LIFOWB writes back to x6
        begin : wait_custom
            forever begin
                @(posedge CLK);
                if (main.CUSTOM_WRITEBACK_MEMOUT === 1'b1 &&
                    main.WRITEENABLE_MEMOUT      === 1'b1 &&
                    main.WRITEADDRESS_MEMOUT     === 5'd6) disable wait_custom;
            end
        end
        @(posedge CLK); // let WB latch
        t_custom_end = $realtime;

        $display("Custom unit END   at %0t ns", t_custom_end);
        $display("Custom unit result  x6 = %0d",
                 $signed(main.registerfile1.registers[6]));
        $display("Custom unit cycles    = %0d",
                 (t_custom_end - t_custom_start) / 10.0);

        // ─────────────────────────────────────────────────────────────────
        // Between phases: RESET CPU and reload instruction memory with
        // the Phase 2 (pure software) program at index 0.
        // ─────────────────────────────────────────────────────────────────
        RESET = 1;
        @(posedge CLK); // hold reset for one cycle

        // Load Phase 2 program (assembled with riscv-none-elf-as, index 0..49)
        // Source: phase2_soft.s  halt = JAL x0,0 at index 49 (PC=0xC4=196)
        main.instructionmem1.memory_array[0]  = 32'h01000513; // li a0,16
        main.instructionmem1.memory_array[1]  = 32'h000005b7; // lui a1,0x0  (discard dup init)
        main.instructionmem1.memory_array[2]  = 32'h7f558593; // addi a1,a1,0x7f5
        main.instructionmem1.memory_array[3]  = 32'h01000513; // li a0,16  (canonical init, overrides [0])
        main.instructionmem1.memory_array[4]  = 32'h0000b5b7; // lui a1,0xb
        main.instructionmem1.memory_array[5]  = 32'h0f558593; // addi a1,a1,245  => a1=0xB0F5
        main.instructionmem1.memory_array[6]  = 32'h01400613; // li a2,20
        main.instructionmem1.memory_array[7]  = 32'he0000693; // li a3,-512
        main.instructionmem1.memory_array[8]  = 32'h00000713; // li a4,0
        main.instructionmem1.memory_array[9]  = 32'h10000793; // li a5,256
        main.instructionmem1.memory_array[10] = 32'h00f00c13; // li s8,15
        // loop: (index 11 = PC 44)
        main.instructionmem1.memory_array[11] = 32'h08050c63; // beqz a0,done
        main.instructionmem1.memory_array[12] = 32'hfff50513; // addi a0,a0,-1
        main.instructionmem1.memory_array[13] = 32'h0007a803; // lw a6,0(a5)
        main.instructionmem1.memory_array[14] = 32'h00478793; // addi a5,a5,4
        main.instructionmem1.memory_array[15] = 32'h0185d8b3; // srl a7,a1,s8
        main.instructionmem1.memory_array[16] = 32'h0018f893; // andi a7,a7,1
        main.instructionmem1.memory_array[17] = 32'hfffc0c13; // addi s8,s8,-1
        main.instructionmem1.memory_array[18] = 32'h02089e63; // bnez a7,spike_high
        // spike_low:
        main.instructionmem1.memory_array[19] = 32'h00000c93; // li s9,0
        main.instructionmem1.memory_array[20] = 32'h00ec8cb3; // add s9,s9,a4
        main.instructionmem1.memory_array[21] = 32'h00171d13; // slli s10,a4,1
        main.instructionmem1.memory_array[22] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[23] = 32'h00471d13; // slli s10,a4,4
        main.instructionmem1.memory_array[24] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[25] = 32'h00571d13; // slli s10,a4,5
        main.instructionmem1.memory_array[26] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[27] = 32'h00671d13; // slli s10,a4,6
        main.instructionmem1.memory_array[28] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[29] = 32'h00771d13; // slli s10,a4,7
        main.instructionmem1.memory_array[30] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[31] = 32'h408cd713; // srai a4,s9,8
        main.instructionmem1.memory_array[32] = 32'h0080006f; // j delta_update
        // spike_high: (index 33 = PC 132)
        main.instructionmem1.memory_array[33] = 32'h00000713; // li a4,0
        // delta_update: (index 34 = PC 136)
        main.instructionmem1.memory_array[34] = 32'h00181c93; // slli s9,a6,1
        main.instructionmem1.memory_array[35] = 32'h41900cb3; // neg s9,s9
        main.instructionmem1.memory_array[36] = 32'h01970733; // add a4,a4,s9
        // weight_update: (index 37 = PC 148)
        main.instructionmem1.memory_array[37] = 32'h00000c93; // li s9,0
        main.instructionmem1.memory_array[38] = 32'h00171d13; // slli s10,a4,1
        main.instructionmem1.memory_array[39] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[40] = 32'h00271d13; // slli s10,a4,2
        main.instructionmem1.memory_array[41] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[42] = 32'h00471d13; // slli s10,a4,4
        main.instructionmem1.memory_array[43] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[44] = 32'h00771d13; // slli s10,a4,7
        main.instructionmem1.memory_array[45] = 32'h01ac8cb3; // add s9,s9,s10
        main.instructionmem1.memory_array[46] = 32'h408cdc93; // srai s9,s9,8
        main.instructionmem1.memory_array[47] = 32'h01960633; // add a2,a2,s9
        main.instructionmem1.memory_array[48] = 32'hf6dff06f; // j loop (back to index 11)
        // done: (index 49 = PC 196 = 0xC4)
        main.instructionmem1.memory_array[49] = 32'h0000006f; // j done (halt)

        // Fill rest with NOPs
        for (i = 50; i < 512; i = i + 1)
            main.instructionmem1.memory_array[i] = 32'h0000_0013;

        // Release reset and start Phase 2
        @(posedge CLK);
        RESET = 0;

        // ── PHASE 2: Software Only ───────────────────────────────────────
        $display("\n========================================");
        $display("PHASE 2: Software Backpropagation (RV32I only)");
        $display("========================================");

        // (debug monitor removed)

        // Wait for pipeline to fill
        repeat(5) @(posedge CLK);
        t_soft_start = $realtime;
        $display("Software START at %0t ns", t_soft_start);

        // Wait until the software halt: counter reaches 0 (all 16 iterations done)
        // Then wait one more cycle to ensure j done (PC=196) is in fetch
        begin : wait_soft_end
            forever begin
                @(posedge CLK);
                if (main.registerfile1.registers[10] === 32'd0 &&
                    main.PC_OUT === 32'd196) disable wait_soft_end;
            end
        end
        repeat(5) @(posedge CLK); // let pipeline drain
        t_soft_end = $realtime;

        $display("Software END   at %0t ns", t_soft_end);
        $display("Software result x12 = %0d",
                 $signed(main.registerfile1.registers[12]));
        $display("Software cycles     = %0d",
                 (t_soft_end - t_soft_start) / 10.0);

        // ── Summary ──────────────────────────────────────────────────────
        $display("\n========================================");
        $display("BENCHMARK SUMMARY");
        $display("========================================");
        $display("Custom unit : %0d cycles",
                 (t_custom_end - t_custom_start) / 10.0);
        $display("Software    : %0d cycles",
                 (t_soft_end - t_soft_start) / 10.0);
        $display("Speedup     : %.2fx",
                 (t_soft_end - t_soft_start) / (t_custom_end - t_custom_start));
        $display("========================================\n");

        #100 $finish;
    end

    // ── Timeout guard ────────────────────────────────────────────────────────
    initial begin
        #500000;
        $display("TIMEOUT: simulation exceeded 500 us");
        $finish;
    end

endmodule
