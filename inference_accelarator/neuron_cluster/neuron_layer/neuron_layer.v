// ============================================================
// Neuron Layer Module
// Description:
//   - Manages a bank of neurons (parameterizable size)
//   - Handles neuron configuration and spike processing
//   - Supports two operating modes:
//     1. Chip mode: Individual neuron configuration
//     2. Layer mode: Broadcast configuration
// ============================================================

`define NEURON_INCLUDE

module neuron_layer #(
    parameter neuron_bank_size = 16 // Number of neurons in this layer
)(
    // ================ System Interface ================
    input wire clk,          // System clock
    input wire rst,          // Active-high reset
    input wire time_step,    // Time step signal for neuron updates
    input wire chip_mode,    // Operation mode: 0=layer mode, 1=chip mode
    
    // ================ Configuration Interface ================
    input wire [$clog2(neuron_bank_size)-1:0] neuron_id,  // Target neuron ID (in chip mode)
    input wire load_data,        // Load configuration data pulse
    input wire [7:0] data,       // Configuration data bus
    
    // ================ Weight Input Interface ================
    input wire [32*neuron_bank_size-1:0] weight_in,  // Parallel weight inputs
    input wire rst_potential,
    
    // ================ Output Interface ================
    output reg [neuron_bank_size-1:0] spikes_out,  // Spike outputs
    output wire neurons_done                      // All neurons completed processing
);

    integer j,k;

    // ================ Internal Signals ================
    wire [neuron_bank_size-1:0] load_data_neuron;  // Decoded load signals
    wire [neuron_bank_size-1:0] neuron_done;      // Individual done signals
    wire [neuron_bank_size-1:0] spikes;           // Raw spike outputs
    wire [neuron_bank_size-1:0] neuron_clock;
    
    reg [neuron_bank_size-1:0] prev_neuron_done;  // For edge detection
    reg [neuron_bank_size-1:0] prev_spikes;       // For edge detection
    reg [neuron_bank_size-1:0] neuron_done_reg;   // Registered done states
    reg prev_time_step;                           // For time step edge detection
    reg [neuron_bank_size-1:0] enable_neuron; // Enable signals for neurons

    genvar i;
    generate
        for (i = 0; i < neuron_bank_size; i = i + 1) begin : neuron_clock_gen
            // Generate clock signals for each neuron
            assign neuron_clock[i] = chip_mode ? clk : enable_neuron[i] & clk; // Use enable signals in chip mode
        end
    endgenerate

    // ================ Neuron Instantiation ================
    generate
        for (i = 0; i < neuron_bank_size; i = i + 1) begin : neuron_gen
            neuron neuron_inst (
                .clk(neuron_clock[i]),
                .rst(rst),
                .time_step(time_step),
                .load_data(load_data_neuron[i]),  // Individual load signal
                .chip_mode(chip_mode),
                .data(data),                      // Shared configuration bus
                .neuron_weight_in(weight_in[i*32 +: 32]),  // Weight inputs
                .rst_potential(rst_potential),
                .spike(spikes[i]),                 // Spike output
                .done(neuron_done[i])              // Completion signal
            );
        end
    endgenerate

    // ================ Control Logic ================
    // Generate 'all done' signal when all neurons complete
    assign neurons_done = (enable_neuron & neuron_done_reg) == enable_neuron;

    // Load data decoder - different behavior based on chip_mode
    generate
        for (i = 0; i < neuron_bank_size; i = i + 1) begin : load_decoder
            assign load_data_neuron[i] = !chip_mode ? 
                   load_data :                   // Broadcast in layer mode
                   (neuron_id[$clog2(neuron_bank_size)-1:0] == i) ? load_data : 1'b0;  // Targeted in chip mode
        end
    endgenerate

    // ================ Output Processing ================
    always @(posedge clk) begin
        // Store previous values for edge detection
        prev_spikes <= spikes;
        prev_time_step <= time_step;
        prev_neuron_done <= neuron_done;
        
        if (rst) begin
            // Reset all registers
            prev_neuron_done <= 0;
            spikes_out <= 0;
            for (j = 0; j < neuron_bank_size; j = j + 1) begin
                neuron_done_reg[j] <= 1;
            end
            enable_neuron <= 0; // Disable all neurons on reset
        end 
        else if (chip_mode && load_data) begin
            enable_neuron[neuron_id[$clog2(neuron_bank_size)-1:0]] <= 1; // Enable specific neuron in chip mode
        end
        // New time step initialization
        else if (time_step && !prev_time_step) begin
            neuron_done_reg <= 0;
            spikes_out <= 0;
        end 
        else begin
            // Detect rising edges on neuron done signals
            for (j = 0; j < neuron_bank_size; j = j + 1) begin
                if (neuron_done[j] && !prev_neuron_done[j]) begin
                    neuron_done_reg[j] <= 1;  // Latch completion status
                end
            end
            
            // Detect rising edges on spike outputs
            for (k = 0; k < neuron_bank_size; k = k + 1) begin
                if (spikes[k] && !prev_spikes[k]) begin
                    spikes_out[k] <= 1;  // Capture spike events
                end
            end
        end
    end
    
endmodule

