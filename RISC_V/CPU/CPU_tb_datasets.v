`timescale 1ns/100ps
`include "CPU.v"

// ============================================================================
// Multi-Dataset Testbench: Custom Unit Backpropagation
//
// Reads multiple neuron datasets from datasets_input.txt, runs each one
// through the custom hardware accelerator unit, and writes the final updated
// weight for every dataset to weights_output.txt.
//
// ── INPUT FILE FORMAT (datasets_input.txt) ───────────────────────────────────
// One dataset per line.  No comment lines.  Exactly 19 space-separated values:
//
//   <spike_hex> <error> <init_weight> <g0> <g1> <g2>...<g15>
//
//   spike_hex   : 16-bit spike pattern in HEX, no "0x" prefix  (e.g. B0F5)
//   error       : signed error term, decimal                   (e.g. -512)
//   init_weight : initial weight, decimal                      (e.g. 20)
//   g0..g15     : 16 signed gradient values, decimal
//
// ── OUTPUT FILE FORMAT (weights_output.txt) ──────────────────────────────────
//   dataset_index  updated_weight
//   (one row per dataset; updated_weight is signed decimal)
//
// ── BUILD & RUN ──────────────────────────────────────────────────────────────
//   cd RISC_V/CPU
//   iverilog -o tb_datasets CPU_tb_datasets.v
//   vvp tb_datasets
// ============================================================================

module CPU_tb_datasets;

    reg CLK, RESET;
    CPU main(CLK, RESET);

    integer fd_in, fd_out;
    integer i, ds;
    integer scan_result;

    // Dataset variables (read from file each iteration)
    integer spike_val;
    integer error_val;
    integer init_weight;
    integer grad [0:15];

    // Per-dataset halt flag
    reg lifowb_done;

    // ── clock 100 MHz ─────────────────────────────────────────────────────────
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    // ── task: store a 32-bit signed integer little-endian in data memory ──────
    task write_word;
        input integer byte_addr;
        input integer val;
        begin
            main.datamemory1.memory_array[byte_addr]   = val[ 7: 0];
            main.datamemory1.memory_array[byte_addr+1] = val[15: 8];
            main.datamemory1.memory_array[byte_addr+2] = val[23:16];
            main.datamemory1.memory_array[byte_addr+3] = val[31:24];
        end
    endtask

    // ── Fixed program loaded ONCE at simulation start ─────────────────────────
    //
    // All per-dataset parameters are read from data memory, so only
    // data memory needs to change between datasets — instruction memory
    // stays constant and survives RESET.
    //
    // Data memory layout (byte addresses):
    //   0x200 (512) : spike pattern (32-bit, only lower 16 bits used)
    //   0x204 (516) : error term    (32-bit signed)
    //   0x208 (520) : initial weight(32-bit signed)
    //   0x20C (524) : grad[0]       (32-bit signed)
    //   0x210 (528) : grad[1]       ...
    //   ...
    //   0x248 (584) : grad[15]
    //
    // Instruction memory layout (index → PC = index×4):
    //   0 : addi x1, x0, 0x20C    — gradient base address
    //   1 : addi x2, x0, 16       — gradient count
    //   2 : lw   x3, 0x200(x0)    — load spike pattern
    //   3 : lw   x4, 0x204(x0)    — load error term
    //   4 : lw   x5, 0x208(x0)    — load initial weight
    //   5 : LIFOPUSH  x3           — push spike to LIFO
    //   6 : LIFOPUSHMG x1, x2      — DMA-load 16 gradients from memory
    //   7-68 : NOP × 62            — wait for gradient DMA (same timing as benchmark)
    //  69 : LIFOPOP  x5, x4        — start streaming, load weight & error, enable unit
    //  70-86: NOP × 17             — wait for 16-step computation
    //  87 : LIFOWB  x6             — write updated weight to x6
    //  88+ : NOP                   — idle

    initial begin
        for (i = 0; i < 512; i = i + 1)
            main.instructionmem1.memory_array[i] = 32'h0000_0013; // NOP

        // addi x1, x0, 0x20C
        main.instructionmem1.memory_array[0] = {12'h20C, 5'd0, 3'b000, 5'd1, 7'b0010011};
        // addi x2, x0, 16
        main.instructionmem1.memory_array[1] = {12'd16,  5'd0, 3'b000, 5'd2, 7'b0010011};
        // lw x3, 0x200(x0)
        main.instructionmem1.memory_array[2] = {12'h200, 5'd0, 3'b010, 5'd3, 7'b0000011};
        // lw x4, 0x204(x0)
        main.instructionmem1.memory_array[3] = {12'h204, 5'd0, 3'b010, 5'd4, 7'b0000011};
        // lw x5, 0x208(x0)
        main.instructionmem1.memory_array[4] = {12'h208, 5'd0, 3'b010, 5'd5, 7'b0000011};
        // LIFOPUSH x3, x0   (funct3=000)
        main.instructionmem1.memory_array[5] = {7'b0000000, 5'd0,  5'd3, 3'b000, 5'd0, 7'b0001011};
        // LIFOPUSHMG x1, x2 (funct3=101)
        main.instructionmem1.memory_array[6] = {7'b0000000, 5'd2,  5'd1, 3'b101, 5'd0, 7'b0001011};

        // 62 NOPs  (indices 7-68)
        for (i = 7; i < 69; i = i + 1)
            main.instructionmem1.memory_array[i] = 32'h0000_0013;

        // LIFOPOP x5, x4  (funct3=001)
        main.instructionmem1.memory_array[69] = {7'b0000000, 5'd4, 5'd5, 3'b001, 5'd0, 7'b0001011};

        // 17 NOPs  (indices 70-86)
        for (i = 70; i < 87; i = i + 1)
            main.instructionmem1.memory_array[i] = 32'h0000_0013;

        // LIFOWB x6  (funct3=110, rd=6)
        main.instructionmem1.memory_array[87] = {7'b0000000, 5'd0, 5'd0, 3'b110, 5'd6, 7'b0001011};
        // remaining indices already NOP
    end

    // ── Main stimulus ─────────────────────────────────────────────────────────
    initial begin
        fd_in  = $fopen("datasets_input.txt", "r");
        fd_out = $fopen("weights_output.txt",  "w");

        if (fd_in == 0) begin
            $display("ERROR: cannot open datasets_input.txt");
            $finish;
        end
        if (fd_out == 0) begin
            $display("ERROR: cannot open weights_output.txt");
            $finish;
        end

        $display("\n=== Multi-Dataset Custom Unit Simulation ===");
        $fdisplay(fd_out, "dataset_index  updated_weight");

        ds = 0;

        // Read one dataset at a time; $fscanf skips whitespace/newlines between tokens
        scan_result = $fscanf(fd_in,
            " %h %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
            spike_val, error_val, init_weight,
            grad[ 0], grad[ 1], grad[ 2], grad[ 3],
            grad[ 4], grad[ 5], grad[ 6], grad[ 7],
            grad[ 8], grad[ 9], grad[10], grad[11],
            grad[12], grad[13], grad[14], grad[15]);

        while (scan_result == 19) begin

            // ── Load this dataset's parameters into data memory ───────────
            write_word(512, spike_val);      // 0x200
            write_word(516, error_val);      // 0x204
            write_word(520, init_weight);    // 0x208
            for (i = 0; i < 16; i = i + 1)
                write_word(524 + i*4, grad[i]); // 0x20C ... 0x248

            // ── RESET CPU (clears pipeline, register file, custom unit) ───
            RESET = 1;
            repeat(3) @(posedge CLK);
            RESET = 0;

            // Wait for pipeline to fill before monitoring
            repeat(5) @(posedge CLK);

            // ── Poll for LIFOWB writeback to x6 ──────────────────────────
            lifowb_done = 1'b0;
            while (!lifowb_done) begin
                @(posedge CLK);
                if (main.CUSTOM_WRITEBACK_MEMOUT === 1'b1 &&
                    main.WRITEENABLE_MEMOUT      === 1'b1 &&
                    main.WRITEADDRESS_MEMOUT     === 5'd6)
                    lifowb_done = 1'b1;
            end
            @(posedge CLK); // let writeback latch into x6

            // ── Report ────────────────────────────────────────────────────
            $display("Dataset %0d: spike=0x%h  error=%0d  init_weight=%0d  =>  updated_weight=%0d",
                     ds, spike_val[15:0], error_val, init_weight,
                     $signed(main.registerfile1.registers[6]));
            $fdisplay(fd_out, "%0d  %0d",
                      ds, $signed(main.registerfile1.registers[6]));

            ds = ds + 1;

            // Read next dataset
            scan_result = $fscanf(fd_in,
                " %h %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                spike_val, error_val, init_weight,
                grad[ 0], grad[ 1], grad[ 2], grad[ 3],
                grad[ 4], grad[ 5], grad[ 6], grad[ 7],
                grad[ 8], grad[ 9], grad[10], grad[11],
                grad[12], grad[13], grad[14], grad[15]);
        end

        $fclose(fd_in);
        $fclose(fd_out);
        $display("\nDone. Processed %0d datasets. Results saved to weights_output.txt", ds);
        $display("==============================================\n");
        #100 $finish;
    end

    // ── Global timeout guard (10 ms, enough for ~1000 datasets) ──────────────
    initial begin
        #10_000_000;
        $display("TIMEOUT: simulation exceeded 10 ms");
        $finish;
    end

endmodule
