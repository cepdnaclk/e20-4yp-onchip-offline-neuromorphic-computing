`include "CPU.v"

module cpu_testbench;
    reg CLK, RESET;
    reg [31:0] INSTRUCTION;

    localparam [31:0] LIFOPUSH = 32'h0020800b; // funct3=000, rs1=x1, rs2=x2
    localparam [31:0] LIFOPOP  = 32'h0041900b; // funct3=001, rs1=x3(weight), rs2=x4(error)
    localparam [31:0] BKPROP   = 32'h0000200b; // funct3=010

    CPU cpu_inst(
        .CLK(CLK),
        .RESET(RESET)
    );  

    // Clock generation
    initial begin
        CLK = 0;
        forever #4 CLK = ~CLK;
    end

    initial begin
         // Program: push -> pop(load weight) -> BKPROP repeated 16 cycles
         cpu_inst.instructionmem1.memory_array[0] = LIFOPUSH;
         cpu_inst.instructionmem1.memory_array[1] = LIFOPOP;
         for (integer j = 2; j < 18; j = j + 1) begin
             cpu_inst.instructionmem1.memory_array[j] = BKPROP;
         end
         for (integer j = 18; j < 80; j = j + 1) begin
             cpu_inst.instructionmem1.memory_array[j] = 32'h00000013; // NOP (ADDI x0,x0,0)
         end

        RESET = 1;
        #5 RESET = 0;

        // Preload registers with known non-zero values for DATA1/DATA2
        #1;
        cpu_inst.registerfile1.registers[1] = 32'h0000000F;  // x1 = 15  (1111)
        cpu_inst.registerfile1.registers[2] = 32'h00000005;  // x2 = 5   (0101)
        cpu_inst.registerfile1.registers[3] = 32'h00000021;  // x3 = 33  (initial weight)
        cpu_inst.registerfile1.registers[4] = 32'h00000018;  // x4 = 24  (dataset error term, Q8)

        $monitor("Time: %t | INSTR: %h | PUSH:%b POP:%b CEN:%b LNW:%b | DATA1:%h DATA1_ID:%h DATA2:%h DATA2_ID:%h | SP_PTR:%0d GR_PTR:%0d | BUSY_S:%b BUSY_G:%b | SER_S:%b SER_G:%b | GRAD16:%h GVAL:%b DELTA:%0d UPD_W:%0d", 
            $time,
            cpu_inst.INSTRUCTION_OUT,
            cpu_inst.PUSH,
            cpu_inst.POP,
            cpu_inst.CUSTOM_ENABLE_IDOUT,
            cpu_inst.LOAD_NEW_WEIGHT_IDOUT,
            cpu_inst.DATA1,
            cpu_inst.DATA1_IDOUT,
            cpu_inst.DATA2,
            cpu_inst.DATA2_IDOUT,
            cpu_inst.LIFO_Buffer_spike_status.stack_ptr,
            cpu_inst.LIFO_Buffer_grad_value.stack_ptr,
            cpu_inst.LIFO_Buffer_spike_status.busy,
            cpu_inst.LIFO_Buffer_grad_value.busy,
            cpu_inst.serial_out_spike_status,
            cpu_inst.serial_out_grad,
            cpu_inst.grad_stream_value,
            cpu_inst.grad_stream_valid,
            cpu_inst.custom_unit.delta_out_buffer,
            cpu_inst.UPDATED_WEIGHT);

        #320;  // enough for push/pop + 16 BKPROP cycles + 1-cycle pipeline settle
        
        // Print results
        $display("\n========== SIMULATION RESULTS ==========");
        $display("Program check: instr[0]=%h instr[1]=%h instr[2]=%h", 
            cpu_inst.instructionmem1.memory_array[0],
            cpu_inst.instructionmem1.memory_array[1],
            cpu_inst.instructionmem1.memory_array[2]);
        $display("DEBUG (0x200): 0x%h", 
            cpu_inst.datamemory1.memory_array[515]);
        //$display("RESULT (0x1B0): %0d", 
            //{cpu_inst.datamemory1.memory_array[435],
             //cpu_inst.datamemory1.memory_array[434],
             //cpu_inst.datamemory1.memory_array[433],
             //cpu_inst.datamemory1.memory_array[432]});

        $display("LIFO spike stack[0] = %h", cpu_inst.LIFO_Buffer_spike_status.stack[0]);
        $display("LIFO grad  stack[0] = %h", cpu_inst.LIFO_Buffer_grad_value.stack[0]);
        $display("Final custom Updated_weight = %0d (0x%h)", $signed(cpu_inst.UPDATED_WEIGHT), cpu_inst.UPDATED_WEIGHT);
        $display("Final dataset error term    = %0d", $signed(cpu_inst.custom_unit.error_term_latched));
        $display("Final serial bits           = spike:%b grad:%b", cpu_inst.serial_out_spike_status, cpu_inst.serial_out_grad);
             
        $display("\n--- W1 Weights (first 4) ---");
        $display("W1[0] = %0d", $signed({cpu_inst.datamemory1.memory_array[259], cpu_inst.datamemory1.memory_array[258], cpu_inst.datamemory1.memory_array[257], cpu_inst.datamemory1.memory_array[256]}));
        $display("W1[1] = %0d", $signed({cpu_inst.datamemory1.memory_array[263], cpu_inst.datamemory1.memory_array[262], cpu_inst.datamemory1.memory_array[261], cpu_inst.datamemory1.memory_array[260]}));
        $display("W1[2] = %0d", $signed({cpu_inst.datamemory1.memory_array[267], cpu_inst.datamemory1.memory_array[266], cpu_inst.datamemory1.memory_array[265], cpu_inst.datamemory1.memory_array[264]}));
        $display("W1[3] = %0d", $signed({cpu_inst.datamemory1.memory_array[271], cpu_inst.datamemory1.memory_array[270], cpu_inst.datamemory1.memory_array[269], cpu_inst.datamemory1.memory_array[268]}));

        
        // TRACE at 0x100 = byte 256
        $display("\n--- Membrane Potential Trace (0x100) ---");
        $display("  t=0: v_mem = %0d  (Expected: 0  - Initial State)", 
            $signed({cpu_inst.datamemory1.memory_array[259], cpu_inst.datamemory1.memory_array[258], cpu_inst.datamemory1.memory_array[257], cpu_inst.datamemory1.memory_array[256]}));
        $display("  t=1: v_mem = %0d  (Expected: 8  - Integrate +10, Decay -2)", 
            $signed({cpu_inst.datamemory1.memory_array[263], cpu_inst.datamemory1.memory_array[262], cpu_inst.datamemory1.memory_array[261], cpu_inst.datamemory1.memory_array[260]}));
        $display("  t=2: v_mem = %0d  (Expected: 16 - Integrate +10, Decay -2)", 
            $signed({cpu_inst.datamemory1.memory_array[267], cpu_inst.datamemory1.memory_array[266], cpu_inst.datamemory1.memory_array[265], cpu_inst.datamemory1.memory_array[264]}));
        $display("  t=3: v_mem = %0d  (Expected: 24 - Integrate +10, Decay -2)", 
            $signed({cpu_inst.datamemory1.memory_array[271], cpu_inst.datamemory1.memory_array[270], cpu_inst.datamemory1.memory_array[269], cpu_inst.datamemory1.memory_array[268]}));
        $display("  t=4: v_mem = %0d  (Expected: 0  - SPIKE! Reset to 0)", 
            $signed({cpu_inst.datamemory1.memory_array[275], cpu_inst.datamemory1.memory_array[274], cpu_inst.datamemory1.memory_array[273], cpu_inst.datamemory1.memory_array[272]}));

        // SPIKE at 0x1B0 = byte 432
        $display("\n--- Spike Output (0x1B0) ---");
        $display("  Last RESULT: 0x%h%h%h%h  (0x0000FFFF=Spike fired, 0x00000000=No spike)", 
            cpu_inst.datamemory1.memory_array[435],
            cpu_inst.datamemory1.memory_array[434],
            cpu_inst.datamemory1.memory_array[433],
            cpu_inst.datamemory1.memory_array[432]);

        $display("\n══════════════════════════════════════════════════════════════");
        
        $finish;
    end

    // VCD Waveform dump for GTKWave
    initial begin

        $dumpfile("cpu_pipeline_lifo.vcd");
        $dumpvars(0, cpu_testbench);
        
        // Explicitly dump all LIFO buffer signals
        $dumpvars(0, cpu_inst.LIFO_Buffer_spike_status);
        $dumpvars(0, cpu_inst.LIFO_Buffer_grad_value);
        $dumpvars(0, cpu_inst.custom_unit);
        $dumpvars(0, cpu_inst.custom_unit.backprop_unit);


        for (integer i = 0; i < 32; i = i + 1) begin
            $dumpvars(0, cpu_inst.registerfile1.registers[i]);
        end
        // Dump data memory around TRACE (0x100) and DEBUG (0x200) regions
        for (integer i = 250; i < 550; i = i + 1) begin
            $dumpvars(0, cpu_inst.datamemory1.memory_array[i]);
        end
    end

endmodule