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

        #500000;  // Increased time for SNN to complete
        
        // Print results
        $display("\n========== SIMULATION RESULTS ==========");
        $display("DEBUG (0x200): 0x%h%h%h%h", 
            cpu_inst.datamemory1.memory_array[515],
            cpu_inst.datamemory1.memory_array[514],
            cpu_inst.datamemory1.memory_array[513],
            cpu_inst.datamemory1.memory_array[512]);
        $display("RESULT (0x1B0): %0d", 
            {cpu_inst.datamemory1.memory_array[435],
             cpu_inst.datamemory1.memory_array[434],
             cpu_inst.datamemory1.memory_array[433],
             cpu_inst.datamemory1.memory_array[432]});
        
        $display("\n--- W1 Weights (first 4) ---");
        $display("W1[0] = %0d", $signed({cpu_inst.datamemory1.memory_array[259], cpu_inst.datamemory1.memory_array[258], cpu_inst.datamemory1.memory_array[257], cpu_inst.datamemory1.memory_array[256]}));
        $display("W1[1] = %0d", $signed({cpu_inst.datamemory1.memory_array[263], cpu_inst.datamemory1.memory_array[262], cpu_inst.datamemory1.memory_array[261], cpu_inst.datamemory1.memory_array[260]}));
        $display("W1[2] = %0d", $signed({cpu_inst.datamemory1.memory_array[267], cpu_inst.datamemory1.memory_array[266], cpu_inst.datamemory1.memory_array[265], cpu_inst.datamemory1.memory_array[264]}));
        $display("W1[3] = %0d", $signed({cpu_inst.datamemory1.memory_array[271], cpu_inst.datamemory1.memory_array[270], cpu_inst.datamemory1.memory_array[269], cpu_inst.datamemory1.memory_array[268]}));
        
        $display("\n--- W2 Weights (all 8) ---");
        $display("W2[0] = %0d", $signed({cpu_inst.datamemory1.memory_array[387], cpu_inst.datamemory1.memory_array[386], cpu_inst.datamemory1.memory_array[385], cpu_inst.datamemory1.memory_array[384]}));
        $display("W2[1] = %0d", $signed({cpu_inst.datamemory1.memory_array[391], cpu_inst.datamemory1.memory_array[390], cpu_inst.datamemory1.memory_array[389], cpu_inst.datamemory1.memory_array[388]}));
        $display("W2[2] = %0d", $signed({cpu_inst.datamemory1.memory_array[395], cpu_inst.datamemory1.memory_array[394], cpu_inst.datamemory1.memory_array[393], cpu_inst.datamemory1.memory_array[392]}));
        $display("W2[3] = %0d", $signed({cpu_inst.datamemory1.memory_array[399], cpu_inst.datamemory1.memory_array[398], cpu_inst.datamemory1.memory_array[397], cpu_inst.datamemory1.memory_array[396]}));
        $display("W2[4] = %0d", $signed({cpu_inst.datamemory1.memory_array[403], cpu_inst.datamemory1.memory_array[402], cpu_inst.datamemory1.memory_array[401], cpu_inst.datamemory1.memory_array[400]}));
        $display("W2[5] = %0d", $signed({cpu_inst.datamemory1.memory_array[407], cpu_inst.datamemory1.memory_array[406], cpu_inst.datamemory1.memory_array[405], cpu_inst.datamemory1.memory_array[404]}));
        $display("W2[6] = %0d", $signed({cpu_inst.datamemory1.memory_array[411], cpu_inst.datamemory1.memory_array[410], cpu_inst.datamemory1.memory_array[409], cpu_inst.datamemory1.memory_array[408]}));
        $display("W2[7] = %0d", $signed({cpu_inst.datamemory1.memory_array[415], cpu_inst.datamemory1.memory_array[414], cpu_inst.datamemory1.memory_array[413], cpu_inst.datamemory1.memory_array[412]}));
        
        $display("\n=========================================\n");
        
        $finish;
    end

    initial begin
        $dumpfile("cpu_pipeline.vcd");
        $dumpvars(0, cpu_testbench);
        for (integer i = 0; i < 32; i = i + 1) begin
            $dumpvars(0, cpu_inst.registerfile1.registers[i]);
        end
        for (integer i = 250; i < 550; i = i + 1) begin
            $dumpvars(0, cpu_inst.datamemory1.memory_array[i]);
        end
    end

  



endmodule