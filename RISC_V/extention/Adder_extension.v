`include "customUnit.v"

module customCalculation (clk, rst_n, enable, error_term, gradient_val, weight, load_new_weight, Updated_weight);
    input wire signed [31:0] error_term;   // Input 1 (Calculated Error)
    input wire signed [31:0] gradient_val; // Input 2 (From Surrogate RAM)
    input wire clk, rst_n, enable; // Control signals for the pipeline register
    input wire signed [31:0] weight; // Current weight value for addition in cycle 2
    input wire load_new_weight; // Signal to load new weight value
    output reg signed [31:0] Updated_weight;   // The calculated weight change

    wire signed [31:0] delta_out;
    reg signed [31:0] delta_out_buffer;;
    reg [2:0] data_valid;

    custom_backprop_unit backprop_unit (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .error_term(error_term),
        .gradient_val(gradient_val),
        .delta_out(delta_out)
    );

    always @(posedge clk or negedge rst_n) begin
        delta_out_buffer <= delta_out;
        data_valid <=data_valid + 2'b01;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            Updated_weight <= 0;
            data_valid   <= 1'b0;
        end else if (enable) begin
            if(load_new_weight) begin
                Updated_weight <= weight;
            end 
            else if (data_valid>=2) begin
                Updated_weight <= Updated_weight + delta_out_buffer; // Update weight with the calculated delta           
            end 
            
        end
    end
endmodule