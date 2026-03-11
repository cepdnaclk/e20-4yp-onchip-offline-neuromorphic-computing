`include "customUnit.v"

module customCalculation (clk, rst_n, enable, error_term_in, gradient_val, grad_valid, spike_status, weight, load_new_weight, Updated_weight);
    input wire signed [15:0] error_term_in;   // one error term for one dataset
    input wire signed [15:0] gradient_val;    // 16-bit surrogate gradient stream
    input wire grad_valid;                    // gradient stream valid
    input wire spike_status; // 1-bit spike status for temporal gating
    input wire clk, rst_n, enable; // Control signals for the pipeline register
    input wire signed [31:0] weight; // Current weight value for addition in cycle 2
    input wire load_new_weight; // Signal to load new weight value
    output reg signed [31:0] Updated_weight;   // The calculated weight change

    localparam signed [15:0] LR = 16'sd150;
    
    wire signed [31:0] delta_out;
    reg apply_update_d;
    reg signed [15:0] error_term_latched;
    reg enable_latched;  // Latched enable signal for continuous computation
    wire signed [63:0] lr_mul;
    wire signed [31:0] lr_delta;

    function signed [31:0] sat16_to_32;
        input signed [63:0] value;
        begin
            if (value > 64'sd32767)
                sat16_to_32 = 32'sd32767;
            else if (value < -64'sd32768)
                sat16_to_32 = -32'sd32768;
            else
                sat16_to_32 = value[31:0];
        end
    endfunction

    assign lr_mul = $signed(delta_out) * $signed(LR);
    assign lr_delta = lr_mul >>> 8;

    custom_backprop_unit backprop_unit (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable_latched),  // Use latched enable for continuous computation
        .error_term(error_term_latched),
        .gradient_val(gradient_val),
        .grad_valid(grad_valid),
        .spike_status(spike_status),
        .delta_out(delta_out)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            Updated_weight <= 0;
            apply_update_d <= 1'b0;
            error_term_latched <= 0;
            enable_latched <= 1'b0;
        end else if (load_new_weight) begin
            Updated_weight <= sat16_to_32(weight);
            apply_update_d <= 1'b0;
            error_term_latched <= error_term_in;
            enable_latched <= 1'b1;  // Latch enable high when starting computation
        end else begin
            if (apply_update_d) begin
                Updated_weight <= sat16_to_32($signed(Updated_weight) - $signed(lr_delta));
            end
            apply_update_d <= (enable_latched && grad_valid);  // Use latched enable
        end
    end
endmodule