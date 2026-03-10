`timescale 1ns/100ps

module potential_adder (
    input wire clk,
    input wire rst,        
    input wire time_step,      
    input wire [31:0] input_weight, 
    input wire [31:0] decayed_potential,
    input wire [1:0] reset_mode, // 0: no reset, 1: reset to 0, 2: decrese by threshold
    input wire load,
    output reg  [31:0] final_potential,
    output reg  [31:0] v_pre_spike,     // pre-fire potential for backprop (REGISTERED)
    output reg  done,
    output reg  spike
);

    // Common Signals
    wire signed [31:0] weight_added;
    wire signed [31:0] reset_value;
    reg signed [31:0] v_threshold;
    
    reg adder_state;
    reg prev_time_step;

    // Init weight addition
    always @(posedge clk) begin
        if (rst) begin
            v_threshold <= 0;
        end else if (load) begin
            v_threshold <= input_weight;
        end
    end

    assign weight_added = decayed_potential + input_weight;
    assign reset_value = (weight_added <= v_threshold) ?
                          weight_added :
                         (reset_mode == 0) ? decayed_potential :
                         (reset_mode == 1) ? 0 :
                         (reset_mode == 2) ? decayed_potential - v_threshold : 0;

    // Final potential calculation and spike detection
    always @(posedge clk) begin
        prev_time_step <= time_step;
        if (rst) begin
            final_potential <= 0;
            spike           <= 0;
            done            <= 0;
            v_pre_spike     <= 0;
            prev_time_step  <= 0;
            adder_state     <= 0;
        end else if (time_step && !prev_time_step) begin
            adder_state <= 1;
        end else if(adder_state == 1) begin
            spike           <= (weight_added > v_threshold);
            final_potential <= reset_value;
            v_pre_spike     <= weight_added; // latch pre-fire value — holds until next timestep
            done            <= 1;
            adder_state     <= 0;
        end else begin
            done  <= 0;
            spike <= 0;
            // v_pre_spike and final_potential HOLD their values
        end
    end

endmodule
