`timescale 1ns/100ps

module accumulator (
    input  clk,        // System clock
    input  rst,        // Reset signal
    input  time_step,  // Time step pulse (sync signal)
    input  load,       // Load signal for setting weights
    input  [31:0] weight_in, // Input weight for loading
    output reg [31:0] accumulated_out // Output accumulated weight (32-bit)
);

    reg [31:0] accumulated_reg;     // 32-bit accumulation register
    reg prev_time_step_val;                     

    always @(posedge clk) begin
        if(rst) begin
            accumulated_reg <= 32'b0;
        end else begin
            if(time_step && !prev_time_step_val) begin
                accumulated_reg <= 0;
            end
            if (load) begin
                accumulated_reg <= accumulated_reg + weight_in;
            end
        end
    end

    always @(posedge clk) begin
        prev_time_step_val <= time_step;
        if(rst) begin
            accumulated_out <= 32'b0;
            prev_time_step_val <= 0;
        end else if(time_step && !prev_time_step_val) begin
            accumulated_out <= accumulated_reg; // Output accumulated weight
        end
    end

endmodule
