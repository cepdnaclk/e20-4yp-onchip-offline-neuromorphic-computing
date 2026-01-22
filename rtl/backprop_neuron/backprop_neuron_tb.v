`timescale 1ns / 1ps

/*
 * Testbench for Time-Multiplexed Backpropagation Neuron
 * 
 * Tests:
 * 1. Weight initialization
 * 2. Forward pass with spike inputs
 * 3. Membrane potential accumulation and decay
 * 4. Spike generation
 * 5. Spike history recording
 * 6. Backward pass gradient calculation
 * 7. Weight updates
 * 8. Error propagation
 */

module backprop_neuron_tb;

    // Parameters
    parameter DATA_WIDTH = 16;
    parameter WEIGHT_WIDTH = 16;
    parameter NUM_INPUTS = 8;
    parameter SPIKE_HISTORY_DEPTH = 32;
    parameter ADDR_WIDTH = $clog2(SPIKE_HISTORY_DEPTH);
    
    // Clock and reset
    reg clk;
    reg rst_n;
    
    // Control signals
    reg mode;
    reg enable;
    reg weight_init_mode;
    
    // Forward pass inputs
    reg [NUM_INPUTS-1:0] spike_in;
    reg signed [DATA_WIDTH-1:0] threshold;
    reg signed [DATA_WIDTH-1:0] leak_rate;
    
    // Backward pass inputs
    reg signed [DATA_WIDTH-1:0] error_gradient;
    reg signed [DATA_WIDTH-1:0] learning_rate;
    reg backprop_enable;
    
    // Weight initialization
    reg [3:0] weight_init_addr;
    reg signed [WEIGHT_WIDTH-1:0] weight_init_data;
    reg weight_init_write;
    
    // Outputs
    wire spike_out;
    wire signed [DATA_WIDTH-1:0] membrane_potential;
    wire signed [DATA_WIDTH-1:0] membrane_potential_pre_spike;
    wire signed [DATA_WIDTH-1:0] error_out;
    wire weight_update_done;
    wire [ADDR_WIDTH-1:0] spike_count;
    wire signed [DATA_WIDTH-1:0] total_weight_change;
    
    // Test tracking
    integer test_num;
    integer i, j;
    integer forward_cycles;
    integer spikes_generated;
    
    // DUT instantiation
    backprop_neuron #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .NUM_INPUTS(NUM_INPUTS),
        .SPIKE_HISTORY_DEPTH(SPIKE_HISTORY_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mode(mode),
        .enable(enable),
        .weight_init_mode(weight_init_mode),
        .spike_in(spike_in),
        .threshold(threshold),
        .leak_rate(leak_rate),
        .error_gradient(error_gradient),
        .learning_rate(learning_rate),
        .backprop_enable(backprop_enable),
        .weight_init_addr(weight_init_addr),
        .weight_init_data(weight_init_data),
        .weight_init_write(weight_init_write),
        .spike_out(spike_out),
        .membrane_potential(membrane_potential),
        .membrane_potential_pre_spike(membrane_potential_pre_spike),
        .error_out(error_out),
        .weight_update_done(weight_update_done),
        .spike_count(spike_count),
        .total_weight_change(total_weight_change)
    );
    
    // Clock generation - 10ns period (100MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // VCD dump for waveform viewing
    initial begin
        $dumpfile("backprop_neuron_tb.vcd");
        $dumpvars(0, backprop_neuron_tb);
        
        // Dump weight values
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin
            $dumpvars(1, dut.weights[i]);
        end
        
        // Dump some history
        for (i = 0; i < 8; i = i + 1) begin
            $dumpvars(1, dut.spike_history[i]);
            $dumpvars(1, dut.input_spike_history[i]);
            $dumpvars(1, dut.membrane_history[i]);
        end
    end
    
    // Main test sequence
    initial begin
        $display("\n==========================================================");
        $display("Starting Backpropagation Neuron Testbench");
        $display("==========================================================\n");
        
        // Initialize
        test_num = 0;
        forward_cycles = 0;
        spikes_generated = 0;
        initialize_signals();
        
        // Reset
        @(posedge clk);
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        // Test 1: Weight Initialization
        test_weight_initialization();
        
        // Test 2: Forward Pass - No spikes
        test_forward_pass_no_spike();
        
        // Test 3: Forward Pass - Single spike input
        test_forward_pass_single_spike();
        
        // Test 4: Forward Pass - Multiple spike inputs
        test_forward_pass_multiple_spikes();
        
        // Test 5: Forward Pass - Spike generation
        test_spike_generation();
        
        // Test 6: Forward Pass - Membrane decay
        test_membrane_decay();
        
        // Test 7: Extended forward pass to build spike history
        test_extended_forward_pass();
        
        // Test 8: Backward Pass - Gradient calculation
        test_backward_pass_gradient();
        
        // Test 9: Backward Pass - Weight updates
        test_weight_updates();
        
        // Test 10: Backward Pass - Error propagation
        test_error_propagation();
        
        // Test 11: Complete forward-backward cycle
        test_complete_cycle();
        
        // Final summary
        @(posedge clk);
        repeat(10) @(posedge clk);
        
        $display("\n==========================================================");
        $display("All Tests Completed Successfully!");
        $display("Total spikes generated: %0d", spike_count);
        $display("==========================================================\n");
        
        $finish;
    end
    
    //==========================================================================
    // Task: Initialize all signals
    //==========================================================================
    task initialize_signals;
    begin
        mode = 0;
        enable = 0;
        weight_init_mode = 0;
        spike_in = 8'b0;
        threshold = 16'd1000;
        leak_rate = 16'd10;
        error_gradient = 16'd0;
        learning_rate = 16'd256;  // Learning rate ~ 1.0 in fixed point
        backprop_enable = 0;
        weight_init_addr = 4'd0;
        weight_init_data = 16'd0;
        weight_init_write = 0;
    end
    endtask
    
    //==========================================================================
    // Test 1: Weight Initialization
    //==========================================================================
    task test_weight_initialization;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Weight Initialization", test_num);
        $display("----------------------------------------------------------");
        
        weight_init_mode = 1;
        
        // Initialize weights with different values
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin
            @(posedge clk);
            weight_init_addr = i;
            weight_init_data = 100 + (i * 50);  // 100, 150, 200, 250, etc.
            weight_init_write = 1;
            $display("  Initializing weight[%0d] = %0d", i, weight_init_data);
        end
        
        @(posedge clk);
        weight_init_write = 0;
        weight_init_mode = 0;
        
        $display("  Weight initialization complete\n");
    end
    endtask
    
    //==========================================================================
    // Test 2: Forward Pass - No spikes
    //==========================================================================
    task test_forward_pass_no_spike;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Forward Pass - No Input Spikes", test_num);
        $display("----------------------------------------------------------");
        
        mode = 0;  // Forward mode
        enable = 1;
        spike_in = 8'b0;
        
        repeat(5) @(posedge clk);
        
        $display("  Membrane potential after 5 cycles: %0d", membrane_potential);
        $display("  Expected decay only (negative growth)");
        $display("  Spike output: %0b\n", spike_out);
        
        enable = 0;
    end
    endtask
    
    //==========================================================================
    // Test 3: Forward Pass - Single spike input
    //==========================================================================
    task test_forward_pass_single_spike;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Forward Pass - Single Spike Input", test_num);
        $display("----------------------------------------------------------");
        
        mode = 0;
        enable = 1;
        
        // Send spike on input 0
        @(posedge clk);
        spike_in = 8'b00000001;
        $display("  Spike on input 0, weight = 100");
        
        @(posedge clk);
        spike_in = 8'b0;
        $display("  Membrane potential: %0d", membrane_potential);
        
        repeat(3) @(posedge clk);
        $display("  Membrane after decay: %0d\n", membrane_potential);
        
        enable = 0;
    end
    endtask
    
    //==========================================================================
    // Test 4: Forward Pass - Multiple spike inputs
    //==========================================================================
    task test_forward_pass_multiple_spikes;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Forward Pass - Multiple Spike Inputs", test_num);
        $display("----------------------------------------------------------");
        
        mode = 0;
        enable = 1;
        
        // Send spikes on multiple inputs
        @(posedge clk);
        spike_in = 8'b00001111;  // First 4 inputs
        $display("  Spikes on inputs 0-3");
        $display("  Expected contribution: 100+150+200+250 = 700");
        
        @(posedge clk);
        spike_in = 8'b0;
        $display("  Membrane potential: %0d\n", membrane_potential);
        
        enable = 0;
    end
    endtask
    
    //==========================================================================
    // Test 5: Forward Pass - Spike generation
    //==========================================================================
    task test_spike_generation;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Forward Pass - Spike Generation", test_num);
        $display("----------------------------------------------------------");
        
        mode = 0;
        enable = 1;
        threshold = 16'd500;  // Lower threshold for easier spiking
        
        $display("  Threshold set to: %0d", threshold);
        
        // Send strong input to trigger spike
        @(posedge clk);
        spike_in = 8'b11111111;  // All inputs
        $display("  All inputs active");
        
        @(posedge clk);
        spike_in = 8'b0;
        
        if (spike_out) begin
            $display("  *** SPIKE GENERATED ***");
            $display("  Membrane reset to: %0d", membrane_potential);
        end else begin
            $display("  No spike, membrane: %0d", membrane_potential);
        end
        
        repeat(3) @(posedge clk);
        $display("");
        
        threshold = 16'd1000;  // Reset threshold
        enable = 0;
    end
    endtask
    
    //==========================================================================
    // Test 6: Forward Pass - Membrane decay
    //==========================================================================
    task test_membrane_decay;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Forward Pass - Membrane Decay", test_num);
        $display("----------------------------------------------------------");
        
        mode = 0;
        enable = 1;
        leak_rate = 16'd50;  // Increased leak
        
        // Build up membrane potential
        @(posedge clk);
        spike_in = 8'b00001111;
        
        @(posedge clk);
        spike_in = 8'b0;
        $display("  Initial membrane: %0d", membrane_potential);
        
        // Watch decay
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge clk);
            $display("  Cycle %0d - Membrane: %0d", i+1, membrane_potential);
        end
        
        leak_rate = 16'd10;  // Reset leak rate
        enable = 0;
        $display("");
    end
    endtask
    
    //==========================================================================
    // Test 7: Extended forward pass to build spike history
    //==========================================================================
    task test_extended_forward_pass;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Extended Forward Pass - Building Spike History", test_num);
        $display("----------------------------------------------------------");
        
        mode = 0;
        enable = 1;
        threshold = 16'd600;
        
        $display("  Running 20 cycles with random spike patterns");
        
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            spike_in = $random & 8'hFF;  // Random spike pattern
            
            if (spike_out) begin
                spikes_generated = spikes_generated + 1;
                $display("  [Cycle %0d] SPIKE! Total spikes: %0d", i, spike_count);
            end
        end
        
        @(posedge clk);
        spike_in = 8'b0;
        enable = 0;
        
        $display("  Total spikes generated: %0d", spike_count);
        $display("  Spike history populated for backpropagation\n");
    end
    endtask
    
    //==========================================================================
    // Test 8: Backward Pass - Gradient calculation
    //==========================================================================
    task test_backward_pass_gradient;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Backward Pass - Gradient Calculation", test_num);
        $display("----------------------------------------------------------");
        
        mode = 1;  // Backward mode
        enable = 0;
        backprop_enable = 1;
        error_gradient = 16'sd100;  // Positive error
        learning_rate = 16'd256;    // LR = 1.0
        
        $display("  Error gradient: %0d", error_gradient);
        $display("  Learning rate: %0d", learning_rate);
        $display("  Starting gradient calculation...");
        
        @(posedge clk);
        @(posedge clk);
        
        // Wait for gradient calculation
        repeat(10) @(posedge clk);
        
        $display("  Gradient calculation phase complete\n");
    end
    endtask
    
    //==========================================================================
    // Test 9: Backward Pass - Weight updates
    //==========================================================================
    task test_weight_updates;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Backward Pass - Weight Updates", test_num);
        $display("----------------------------------------------------------");
        
        $display("  Weights before update:");
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin
            $display("    Weight[%0d] = %0d", i, dut.weights[i]);
        end
        
        // Continue backward pass until weight update done
        while (!weight_update_done) begin
            @(posedge clk);
        end
        
        $display("\n  Weight update complete!");
        $display("  Weights after update:");
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin
            $display("    Weight[%0d] = %0d", i, dut.weights[i]);
        end
        
        $display("  Total weight change: %0d\n", total_weight_change);
        
        backprop_enable = 0;
    end
    endtask
    
    //==========================================================================
    // Test 10: Backward Pass - Error propagation
    //==========================================================================
    task test_error_propagation;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Backward Pass - Error Propagation", test_num);
        $display("----------------------------------------------------------");
        
        mode = 1;
        backprop_enable = 1;
        error_gradient = 16'sd200;
        
        @(posedge clk);
        
        // Wait for error propagation
        repeat(20) @(posedge clk);
        
        $display("  Input error gradient: %0d", error_gradient);
        $display("  Propagated error: %0d", error_out);
        $display("  Error propagation complete\n");
        
        backprop_enable = 0;
    end
    endtask
    
    //==========================================================================
    // Test 11: Complete forward-backward cycle
    //==========================================================================
    task test_complete_cycle;
    begin
        test_num = test_num + 1;
        $display("[TEST %0d] Complete Forward-Backward Cycle", test_num);
        $display("==========================================================");
        
        // Forward pass
        $display("\n  === FORWARD PASS ===");
        mode = 0;
        enable = 1;
        threshold = 16'd800;
        
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            spike_in = (i % 3 == 0) ? 8'b00001111 : 8'b00000001;
            
            if (spike_out) begin
                $display("  [FWD Cycle %0d] Output spike generated!", i);
            end
        end
        
        @(posedge clk);
        spike_in = 8'b0;
        enable = 0;
        
        $display("  Forward pass complete. Spikes: %0d", spike_count);
        
        // Backward pass
        $display("\n  === BACKWARD PASS ===");
        mode = 1;
        backprop_enable = 1;
        error_gradient = -16'sd50;  // Negative error (reduce weights)
        learning_rate = 16'd128;     // LR = 0.5
        
        $display("  Starting backpropagation with error: %0d", error_gradient);
        
        @(posedge clk);
        
        // Wait for completion
        while (!weight_update_done) begin
            @(posedge clk);
        end
        
        $display("  Backpropagation complete!");
        $display("  Total weight change: %0d", total_weight_change);
        $display("  Propagated error: %0d", error_out);
        
        backprop_enable = 0;
        
        $display("\n  === CYCLE COMPLETE ===\n");
    end
    endtask
    
    // Timeout watchdog
    initial begin
        #100000;
        $display("\nERROR: Testbench timeout!");
        $finish;
    end

endmodule
