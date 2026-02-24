`include "CPU.v"

module cpu_testbench;
    reg CLK, RESET;
    reg [31:0] INSTRUCTION;

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
        RESET = 1;
        #5 RESET = 0;

        #500000;  // 500k to ensure demo finishes completely
        
        // Print results for DEMO: SINGLE LIF NEURON
        $display("\n╔══════════════════════════════════════════════════════════════╗");
        $display("║  SINGLE LIF NEURON - RISC-V SNN VERIFICATION               ║");
        $display("╚══════════════════════════════════════════════════════════════╝");
        
        $display("\n--- Neuron Configuration ---");
        $display("  Input Current : 10 | Decay : 2 | Threshold : 30");
        
        $display("\n--- Execution Status ---");
        $display("  DEBUG (0x200): 0x%h%h%h%h", 
            cpu_inst.datamemory1.memory_array[515],
            cpu_inst.datamemory1.memory_array[514],
            cpu_inst.datamemory1.memory_array[513],
            cpu_inst.datamemory1.memory_array[512]);
        $display("  [0x1111=Start | 0xAAAA=Done]");
        
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
        $dumpfile("lif_neuron.vcd");
        $dumpvars(0, cpu_testbench);
        // Dump all 32 registers
        for (integer i = 0; i < 32; i = i + 1) begin
            $dumpvars(0, cpu_inst.registerfile1.registers[i]);
        end
        // Dump data memory around TRACE (0x100) and DEBUG (0x200) regions
        for (integer i = 250; i < 550; i = i + 1) begin
            $dumpvars(0, cpu_inst.datamemory1.memory_array[i]);
        end
    end

endmodule