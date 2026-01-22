/*
 * Time-Multiplexed Backpropagation Neuron
 * Supports both forward and backward passes using time multiplexing
 * 
 * Forward Pass:
 * - Receives spike inputs
 * - Multiplies by weights
 * - Accumulates to membrane potential
 * - Applies leak/decay
 * - Compares with threshold and generates output spike
 * - Stores spike history for backward pass
 *
 * Backward Pass:
 * - Receives error gradient from next layer
 * - Calculates local gradients
 * - Updates weights using learning rate
 * - Propagates error to previous layer
 */

module backprop_neuron #(
    parameter DATA_WIDTH = 16,          // Width of data signals
    parameter WEIGHT_WIDTH = 16,        // Width of weight values
    parameter NUM_INPUTS = 8,           // Number of input connections
    parameter SPIKE_HISTORY_DEPTH = 32, // Depth of spike history buffer
    parameter ADDR_WIDTH = $clog2(SPIKE_HISTORY_DEPTH)
)(
    input wire clk,
    input wire rst_n,
    
    // Control signals
    input wire mode,                    // 0: Forward pass, 1: Backward pass
    input wire enable,                  // Enable neuron operation
    input wire weight_init_mode,        // Weight initialization mode
    
    // Forward pass inputs
    input wire [NUM_INPUTS-1:0] spike_in,        // Input spikes
    input wire signed [DATA_WIDTH-1:0] threshold, // Firing threshold
    input wire signed [DATA_WIDTH-1:0] leak_rate, // Membrane leak rate
    
    // Backward pass inputs
    input wire signed [DATA_WIDTH-1:0] error_gradient,    // Error from next layer
    input wire signed [DATA_WIDTH-1:0] learning_rate,     // Learning rate
    input wire backprop_enable,                            // Enable backprop calculation
    
    // Weight initialization
    input wire [3:0] weight_init_addr,                          // Weight address for init
    input wire signed [WEIGHT_WIDTH-1:0] weight_init_data,      // Weight data for init
    input wire weight_init_write,                                // Weight write enable
    
    // Forward pass outputs
    output reg spike_out,                                        // Output spike
    output reg signed [DATA_WIDTH-1:0] membrane_potential,      // Current membrane potential
    output reg signed [DATA_WIDTH-1:0] membrane_potential_pre_spike, // Membrane potential before spike
    
    // Backward pass outputs
    output reg signed [DATA_WIDTH-1:0] error_out,               // Error to propagate back
    output reg weight_update_done,                               // Weight update completion flag
    
    // Debug/monitoring outputs
    output reg [ADDR_WIDTH-1:0] spike_count,                    // Total spikes generated
    output reg signed [DATA_WIDTH-1:0] total_weight_change      // Accumulated weight changes
);

    // Internal registers
    reg signed [WEIGHT_WIDTH-1:0] weights [0:NUM_INPUTS-1];         // Weight memory
    reg signed [DATA_WIDTH-1:0] weighted_sum;                        // Current weighted sum
    reg signed [DATA_WIDTH-1:0] membrane_potential_next;            // Next membrane potential
    
    // Spike history for BPTT (Backpropagation Through Time)
    reg spike_history [0:SPIKE_HISTORY_DEPTH-1];                   // Spike history buffer
    reg [NUM_INPUTS-1:0] input_spike_history [0:SPIKE_HISTORY_DEPTH-1]; // Input spike history
    reg signed [DATA_WIDTH-1:0] membrane_history [0:SPIKE_HISTORY_DEPTH-1]; // Membrane potential history
    reg [ADDR_WIDTH-1:0] history_write_ptr;                        // Write pointer for history
    reg [ADDR_WIDTH-1:0] history_read_ptr;                         // Read pointer for history
    
    // Backward pass temporaries
    reg signed [DATA_WIDTH-1:0] weight_gradients [0:NUM_INPUTS-1]; // Calculated gradients
    reg [3:0] backprop_state;                                       // State for backprop FSM
    reg [3:0] weight_update_index;                                  // Index for weight updates
    
    // Constants
    localparam signed [DATA_WIDTH-1:0] ZERO = {DATA_WIDTH{1'b0}};
    
    // FSM states for backward pass
    localparam IDLE = 4'd0;
    localparam CALC_GRADIENT = 4'd1;
    localparam UPDATE_WEIGHTS = 4'd2;
    localparam PROPAGATE_ERROR = 4'd3;
    localparam DONE = 4'd4;
    
    integer i;
    
    //==========================================================================
    // Weight Initialization
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_INPUTS; i = i + 1) begin
                weights[i] <= {WEIGHT_WIDTH{1'b0}};
            end
        end else if (weight_init_mode && weight_init_write && weight_init_addr < NUM_INPUTS) begin
            weights[weight_init_addr] <= weight_init_data;
        end
    end
    
    //==========================================================================
    // Forward Pass Logic
    //==========================================================================
    always @(*) begin
        weighted_sum = ZERO;
        
        // Calculate weighted sum of inputs
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin
            if (spike_in[i]) begin
                weighted_sum = weighted_sum + weights[i];
            end
        end
    end
    
    always @(*) begin
        // Apply leak and add weighted input
        membrane_potential_next = membrane_potential - leak_rate + weighted_sum;
        
        // Check if neuron should spike
        if (membrane_potential_next >= threshold) begin
            membrane_potential_next = ZERO; // Reset after spike
        end
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            membrane_potential <= ZERO;
            membrane_potential_pre_spike <= ZERO;
            spike_out <= 1'b0;
            spike_count <= {ADDR_WIDTH{1'b0}};
            history_write_ptr <= {ADDR_WIDTH{1'b0}};
        end else if (enable && !mode) begin // Forward pass
            membrane_potential_pre_spike <= membrane_potential_next;
            
            // Check for spike
            if (membrane_potential_next >= threshold) begin
                spike_out <= 1'b1;
                membrane_potential <= ZERO;
                spike_count <= spike_count + 1'b1;
                
                // Store spike event
                spike_history[history_write_ptr] <= 1'b1;
            end else begin
                spike_out <= 1'b0;
                membrane_potential <= membrane_potential_next;
                
                // Store no spike event
                spike_history[history_write_ptr] <= 1'b0;
            end
            
            // Store input spikes and membrane potential in history
            input_spike_history[history_write_ptr] <= spike_in;
            membrane_history[history_write_ptr] <= membrane_potential;
            
            // Advance history pointer (circular buffer)
            history_write_ptr <= (history_write_ptr + 1'b1) % SPIKE_HISTORY_DEPTH;
        end
    end
    
    //==========================================================================
    // Backward Pass Logic
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            backprop_state <= IDLE;
            weight_update_index <= 4'd0;
            weight_update_done <= 1'b0;
            error_out <= ZERO;
            total_weight_change <= ZERO;
            history_read_ptr <= {ADDR_WIDTH{1'b0}};
            
            for (i = 0; i < NUM_INPUTS; i = i + 1) begin
                weight_gradients[i] <= ZERO;
            end
        end else if (mode && backprop_enable) begin // Backward pass
            case (backprop_state)
                IDLE: begin
                    weight_update_done <= 1'b0;
                    weight_update_index <= 4'd0;
                    total_weight_change <= ZERO;
                    
                    // Set read pointer to most recent history
                    if (history_write_ptr == 0)
                        history_read_ptr <= SPIKE_HISTORY_DEPTH - 1;
                    else
                        history_read_ptr <= history_write_ptr - 1'b1;
                    
                    backprop_state <= CALC_GRADIENT;
                end
                
                CALC_GRADIENT: begin
                    // Calculate gradients for each weight
                    // gradient = error * input_spike * derivative_of_activation
                    // For LIF neuron, derivative approximation based on spike status
                    
                    for (i = 0; i < NUM_INPUTS; i = i + 1) begin
                        if (input_spike_history[history_read_ptr][i]) begin
                            // Gradient calculation
                            // If neuron spiked, gradient includes spike derivative approximation
                            if (spike_history[history_read_ptr]) begin
                                // Spike occurred - use surrogate gradient
                                weight_gradients[i] <= (error_gradient * learning_rate) >>> 8;
                            end else begin
                                // No spike - gradient based on membrane potential proximity to threshold
                                weight_gradients[i] <= (error_gradient * learning_rate * 
                                                       membrane_history[history_read_ptr]) >>> 12;
                            end
                        end else begin
                            weight_gradients[i] <= ZERO;
                        end
                    end
                    
                    backprop_state <= UPDATE_WEIGHTS;
                end
                
                UPDATE_WEIGHTS: begin
                    // Update weights using calculated gradients
                    if (weight_update_index < NUM_INPUTS) begin
                        // W_new = W_old - gradient
                        weights[weight_update_index] <= weights[weight_update_index] - 
                                                        weight_gradients[weight_update_index];
                        
                        // Track total weight change for monitoring
                        total_weight_change <= total_weight_change + 
                                             ((weight_gradients[weight_update_index] >= 0) ? 
                                              weight_gradients[weight_update_index] : 
                                              -weight_gradients[weight_update_index]);
                        
                        weight_update_index <= weight_update_index + 1'b1;
                    end else begin
                        backprop_state <= PROPAGATE_ERROR;
                    end
                end
                
                PROPAGATE_ERROR: begin
                    // Calculate error to propagate to previous layer
                    // error_out = sum(error * weight) for all connections
                    error_out <= ZERO;
                    
                    for (i = 0; i < NUM_INPUTS; i = i + 1) begin
                        error_out <= error_out + ((error_gradient * weights[i]) >>> 8);
                    end
                    
                    backprop_state <= DONE;
                end
                
                DONE: begin
                    weight_update_done <= 1'b1;
                    backprop_state <= IDLE;
                end
                
                default: begin
                    backprop_state <= IDLE;
                end
            endcase
        end else if (!backprop_enable) begin
            // Reset when backprop not enabled
            backprop_state <= IDLE;
            weight_update_done <= 1'b0;
        end
    end
    
endmodule
