`timescale 1ns/100ps
`include "blackbox.v"

module blackbox_tb;

    // localparam time_step_window = 50;
    localparam layer_count = 2;

    reg clock;
    reg reset;
    reg rocc_cmd_valid;
    wire rocc_cmd_ready;
    reg [6:0] rocc_cmd_bits_inst_funct;
    reg [63:0] rocc_cmd_bits_rs1;
    reg [63:0] rocc_cmd_bits_rs2;
    wire [63:0] rocc_resp_bits_data;
    reg [63:0] rocc_resp_bits_data_reg;
    wire last_bit;

    assign last_bit = rocc_resp_bits_data_reg[0];

    reg [127:0] data_mem [0:100000000];
    reg [127:0] spike_mem [0:100000000];
    integer file;
    integer index = 0;
    integer input_size;
    integer input_count = 0;
    localparam output_inst = 128'h20000000000000000000000000000001;

    // Clock generation
    initial begin
        clock = 0;
        forever #5 clock = ~clock;
    end

    // dump file generation and read memory initialization
    initial begin
        // $dumpfile("blackbox_tb.vcd");
        // $dumpvars(0, blackbox_tb);

        // Initialize signals
        reset = 1;
        rocc_cmd_valid = 0;
        rocc_cmd_bits_inst_funct = 7'b0000000;
        rocc_cmd_bits_rs1 = 64'b0;
        rocc_cmd_bits_rs2 = 64'b0;

        // Load memory files
        $readmemh("data_mem.mem", data_mem);
        $readmemh("spike_mem.mem", spike_mem);

        file = $fopen("output.txt", "w");
        if (!file) begin
            $display("Failed to open file.");
            $finish;
        end

        // Reset the system
        #10 reset = 0;
    end

    // Task to give a instruction to the blackbox (without default arguments)
    task give_instruction;
        input [6:0] funct;
        input [63:0] rs1;
        input [63:0] rs2;
        input write_output;
        input integer input_index;
        begin
            wait(rocc_cmd_ready == 1'b0);
            rocc_cmd_valid = 1;
            rocc_cmd_bits_inst_funct = funct;
            rocc_cmd_bits_rs1 = rs1;
            rocc_cmd_bits_rs2 = rs2;

            // wait for the command to be ready
            wait(rocc_cmd_ready);
            @(posedge clock);
            rocc_resp_bits_data_reg = rocc_resp_bits_data;

            // Write response data to file if requested (for spike communication)
            if (write_output) begin
                $fwrite(file, "%h:%d\n", rocc_resp_bits_data, input_index);
                $fflush(file);
            end
            
            rocc_cmd_valid = 0;
        end
    endtask

    // Wrapper task for give_instruction with default input_index = 0
    task give_instruction_simple;
        input [6:0] funct;
        input [63:0] rs1;
        input [63:0] rs2;
        input write_output;
        begin
            give_instruction(funct, rs1, rs2, write_output, 0);
        end
    endtask

    // Task to process spike inputs and collect outputs (without default arguments)
    task process_spikes;
        input integer start_index;
        input integer end_index;
        input integer input_index;
        begin
            $display("Starting spike processing...");
            begin : spike_processing_loop
                for (integer j = start_index; j <= end_index; j = j + 1) begin
                    if (spike_mem[j] === 128'bx) begin
                        $display("Reached undefined memory at location %d", j);
                        disable spike_processing_loop; // Exit the named block
                    end

                    give_instruction(7'b0000001, spike_mem[j][127:64], spike_mem[j][63:0], 1'b1, input_index);
                    $display("instruction %d given: %h", j, spike_mem[j]);
                    
                    if (spike_mem[j][0]) begin 
                        while (!last_bit) begin
                            #5
                            give_instruction(7'b0000001, output_inst[127:64], output_inst[63:0], 1'b1, input_index);
                        end
                    end
                    #5; // Wait for a while before the next instruction
                end
            end
            $display("Spike processing complete.\n");
        end
    endtask

    // Wrapper task for process_spikes with default input_index = 0
    task process_spikes_simple;
        input integer start_index;
        input integer end_index;
        begin
            process_spikes(start_index, end_index, 0);
        end
    endtask

    // Task to get remaining outputs after processing (without default arguments)
    task get_final_outputs;
        input integer input_index;
        begin
            $display("Getting last outputs...");

            for (integer i = 0; i < layer_count; i = i + 1) begin
                #5
                give_instruction(7'b0000001, output_inst[127:64], output_inst[63:0], 1'b1, input_index);
            end

            while (!last_bit) begin
                while (!last_bit) begin
                    #5
                    give_instruction(7'b0000001, output_inst[127:64], output_inst[63:0], 1'b1, input_index);
                end

                for (integer i = 0; i < layer_count; i = i + 1) begin
                    #5
                    give_instruction(7'b0000001, output_inst[127:64], output_inst[63:0], 1'b1, input_index);
                end
                
            end
            $display("Last outputs received.\n");
        end
    endtask

    // Instantiate the blackbox module
    blackbox uut (
        .clock(clock),
        .reset(reset),
        .rocc_cmd_valid(rocc_cmd_valid),
        .rocc_cmd_ready(rocc_cmd_ready),
        .rocc_cmd_bits_inst_funct(rocc_cmd_bits_inst_funct),
        .rocc_cmd_bits_rs1(rocc_cmd_bits_rs1),
        .rocc_cmd_bits_rs2(rocc_cmd_bits_rs2),
        .rocc_resp_bits_data(rocc_resp_bits_data)
    );

    // Test sequence
    initial begin
        // Wait for reset to complete
        #20;

        $display("Starting initialization...");
        // Give some init instructions to the blackbox from the init memory
        begin : init_loop
            for (integer i = 0; i < 100000; i = i + 1) begin
                if (data_mem[i] === 128'bx) begin
                    $display("Reached undefined memory at location %d", i);
                    disable init_loop; // Exit the named block
                end

                give_instruction_simple(7'b0000001, data_mem[i][127:64], data_mem[i][63:0], 1'b0);
                $display("Init instruction %d given: %h %h", i, data_mem[i][127:64], data_mem[i][63:0]);
                #5; // Wait for a while before the next instruction
            end
        end
        $display("Initialization complete.\n\n");

        #100

        while (spike_mem[index] !== 128'bx) begin 
            input_size = spike_mem[index];
            index = index + 1;
            input_count = input_count + 1;

            // Process the current input
            process_spikes(index, index + input_size - 1, input_count);
            get_final_outputs(input_count);
            index = index + input_size;
        end

        // Close the output file
        $fclose(file);

        // Finish the simulation
        #1000;
        $finish;
    end

endmodule