module custom_backprop_unit (
    input  wire                 clk,          // System Clock
    input  wire                 rst_n,        // Active-low Reset
    input  wire                 enable,       // Optional: Only update when instruction is valid
    
    // Inputs from Register File / Memory
    input  wire signed [31:0]   error_term,   // Input 1 (Calculated Error)
    input  wire signed [31:0]   gradient_val, // Input 2 (From Surrogate RAM)

    // Output to Pipeline/ALU
    output reg  signed [31:0]   delta_out     // The calculated gradient change
);

    // --- 1. Internal Signals (Combinational Math) ---
    wire signed [31:0] error_scaled;
    wire signed [63:0] raw_product;
    wire signed [63:0] shifted_result;

    // --- 2. Step A: Pre-Scaling (Matches your Diagram bubble "(Error_term)>>2") ---
    // We use arithmetic shift (>>>) to preserve the sign of the error.
    assign error_scaled = error_term >>> 2;

    // --- 3. Step B: Multiplication (Matches "Multiplier" box) ---
    // 32-bit * 32-bit = 64-bit result to prevent overflow.
    assign raw_product = error_scaled * gradient_val;

    // --- 4. Step C: Post-Scaling (Matches "Shift Right 8" box) ---
    // Fixed-point adjustment (division by 256).
    assign shifted_result = raw_product >>> 8;

    // --- 5. Step D: Pipeline Register ---
    // This holds the value for the NEXT clock cycle, allowing the 
    // Weight Update (Addition) to happen in cycle 2.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delta_out <= 32'd0;
        end else if (enable) begin
            // Truncate back to 32 bits and store in the register
            delta_out <= shifted_result[31:0];
        end
    end

endmodule