module custom_backprop_unit (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 enable,
    input  wire signed [15:0]   error_term,
    input  wire signed [15:0]   gradient_val,
    input  wire                 grad_valid,
    input  wire                 spike_status,
    output reg  signed [31:0]   delta_out
);

    localparam signed [15:0] BETA = 16'sd243; // 0.95 * 256

    reg  signed [31:0] dm_prev;

    wire signed [31:0] error_fixed;
    wire signed [31:0] grad_fixed;
    wire signed [63:0] beta_mul;
    wire signed [31:0] temporal_term;
    wire signed [31:0] effective_error;
    wire signed [63:0] grad_mul;
    wire signed [31:0] delta_calc;
    wire signed [31:0] delta_spike_gated;
    wire signed [31:0] dm_next_calc;

    assign error_fixed   = {{16{error_term[15]}}, error_term};
    assign grad_fixed    = {{16{gradient_val[15]}}, gradient_val};
    assign beta_mul      = $signed(dm_prev) * $signed(BETA);
    assign temporal_term = beta_mul >>> 8;
    assign effective_error = error_fixed + temporal_term;
    assign grad_mul      = $signed(effective_error) * $signed(grad_fixed);
    assign delta_calc    = grad_mul >>> 8;
    assign delta_spike_gated = spike_status ? delta_calc : 32'sd0;
    assign dm_next_calc  = spike_status ? 32'sd0 : delta_calc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delta_out <= 32'sd0;
            dm_prev <= 32'sd0;
        end else if (enable && grad_valid) begin
            delta_out <= delta_spike_gated;
            dm_prev <= dm_next_calc;
        end else begin
            delta_out <= 32'sd0;
        end
    end

endmodule