`timescale 1ns/1ps
`include "cluster_controller.v"

module cluster_controller_tb;

    // Parameters
    parameter NUMBER_OF_CLUSTERS = 64;
    parameter NEURONS_PER_CLUSTER = 32;
    parameter NEURONS_PER_LAYER = 16;
    parameter MAX_WEIGHT_TABLE_ROWS = 32;
    
    // Clock and reset
    reg clk;
    reg rst;
    
    // Inputs
    reg load_data;
    reg [7:0] data;
    
    // Outputs
    wire [$clog2(NEURONS_PER_CLUSTER)-1:0] neuron_id;
    wire [7:0] neuron_data;
    wire neuron_load_data;
    wire [15:0] if_row_index;
    wire [$clog2(NUMBER_OF_CLUSTERS)-1:0] if_cluster_id;
    wire [$clog2(NEURONS_PER_CLUSTER)-1:0] if_neuron_id;
    wire [$clog2(MAX_WEIGHT_TABLE_ROWS)-1:0] if_weight_addr_init;
    wire if_load_weight_addr;
    wire [NEURONS_PER_CLUSTER-1:0] neuron_mask;
    wire load_neuron_mask;
    wire if_load_weight;

    // Instantiate the DUT
    cluster_controller #(
        .number_of_clusters(NUMBER_OF_CLUSTERS),
        .neurons_per_cluster(NEURONS_PER_CLUSTER),
        .max_weight_table_rows(MAX_WEIGHT_TABLE_ROWS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .load_data(load_data),
        .data(data),
        .chip_mode(1'b1),  // Set chip_mode to 1 for testing
        .internal_clk(),
        .neuron_id(neuron_id),
        .neuron_data(neuron_data),
        .neuron_load_data(neuron_load_data),
        .if_row_index(if_row_index),
        .if_cluster_id(if_cluster_id),
        .if_neuron_id(if_neuron_id),
        .if_weight_addr_init(if_weight_addr_init),
        .if_load_weight_addr(if_load_weight_addr),
        .neuron_mask(neuron_mask),
        .load_neuron_mask(load_neuron_mask)
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // Test procedure
    initial begin
        $dumpfile("cluster_controller_tb.vcd");
        $dumpvars(0, cluster_controller_tb);

        // Initialize
        rst = 1;
        load_data = 0;
        data = 0;
        
        // Reset
        #20;
        rst = 0;
        #10;
        
        // Test 1: Neuron Initialization (NI)
        $display("=== Testing NI (Neuron Init) Mode ===");
        test_ni_mode();
        
        // Test 3: Inter-Field Weight Loading (IF)
        $display("=== Testing IF (Inter-Field) Mode ===");
        test_if_mode();

        // Test 4: Output Enable (OE)
        $display("=== Testing OE (Output Enable) Mode ===");
        test_oe_mode();
        
        // Finish simulation
        #100;
        $display("All tests completed successfully!");
        $finish;
    end
    
    // Task to test NI mode
    task test_ni_mode;
        begin
            // Send opcode
            send_byte(8'h01);  // OPCODE_LOAD_NI
            
            // Send neuron ID
            send_byte(8'h05);  // neuron_id = 5
            
            // Send flit count (number of data bytes)
            send_byte(8'h03);  // 3 data bytes
            
            // Send data bytes
            send_byte(8'hAA);
            send_byte(8'hBB);
            send_byte(8'hCC);
            
            // Verify outputs
            #20;
            if (neuron_id !== 5) $display("ERROR: NI: neuron_id incorrect");
            if (neuron_data !== 8'hCC) $display("ERROR: NI: last data byte incorrect");
            if (neuron_load_data !== 1) $display("ERROR: NI: load_data not asserted");
            
            #10;
            if (neuron_load_data !== 0) $display("ERROR: NI: load_data not deasserted");
            
            $display("NI test passed");
        end
    endtask
        
    // Task to test IF mode with 1024-bit weights
    task test_if_mode;
        integer i;
        reg [31:0] expected_word;
        begin
            // Send opcode
            send_byte(8'h03);  // OPCODE_LOAD_IF
            
            // Send metadata
            send_byte(8'h01);  // row_index = 01 (LSB)
            send_byte(8'h00);  // row_index = 00 (MSB)
            send_byte(8'h0B);  // cluster_id = 11
            send_byte(8'h0C);  // neuron_id = 12
            
            // Send number of weight address
            send_byte(8'h20);  // 32 in hex
            send_byte(8'h00);  // 0 for MSB
            
            // Verification phase
            #40;
            
            // Verify metadata
            if (if_row_index !== 01) $display("ERROR: IF: row_index incorrect");
            if (if_cluster_id !== 11) $display("ERROR: IF: cluster_id incorrect");
            if (if_neuron_id !== 12) $display("ERROR: IF: neuron_id incorrect");
            if (if_weight_addr_init !== 16'h0020) $display("ERROR: IF: weight_addr_init incorrect");

            // Verify control signals
            if (if_load_weight !== 1) $display("ERROR: IF: load_weight not asserted");
            #10;
            if (if_load_weight !== 0) $display("ERROR: IF: load_weight not deasserted");
            
            $display("IF weight address test passed");
        end
    endtask

    task test_oe_mode;
        begin
            // Send opcode
            send_byte(8'h04);  // OPCODE_LOAD_OE
            
            // Send neuron mask
            send_byte(8'h0F);
            send_byte(8'hF0);
            send_byte(8'h0F);
            send_byte(8'hF0);  // neuron_mask = 32'hF00FF00F
            
            // Verify outputs
            #20;
            if (neuron_mask !== 32'hF00FF00F) $display("ERROR: OE: neuron_mask incorrect");
            if (load_neuron_mask !== 1) $display("ERROR: OE: load_neuron_mask not asserted");
            
            #10;
            if (load_neuron_mask !== 0) $display("ERROR: OE: load_neuron_mask not deasserted");
            
            $display("OE test passed");
        end
    endtask
    
    // Helper task to send a byte
    task send_byte;
        input [7:0] byte_data;
        begin
            @(posedge clk);
            load_data = 1;
            data = byte_data;
            #5;
            @(posedge clk);
            load_data = 0;
            #5;
        end
    endtask
    
    // Monitor for debugging
    reg [7:0] monitor_state;
    reg [7:0] monitor_mode;
    reg [7:0] monitor_flit_counter;
    
    always @(posedge clk) begin
        monitor_state = dut.state;
        monitor_mode = dut.work_mode;
        monitor_flit_counter = dut.flit_counter;
        $display("Time: %0t | State: %d | Mode: %h | FlitCnt: %d", 
                $time, monitor_state, monitor_mode, monitor_flit_counter);
    end
    
endmodule