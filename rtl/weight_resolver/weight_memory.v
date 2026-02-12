module weight_memory #(
    parameter max_weight_rows = 2048,
    parameter neurons_per_cluster = 32
) (
    input clk,
    input rst,
    
    // initialize weight memory
    input [32*neurons_per_cluster-1:0] weight_in,
    input load_weight,

    // weight memory read
    input [$clog2(max_weight_rows)-1:0] weight_addr,
    output [32*neurons_per_cluster-1:0] weight_out
);

    // weight memory storage
    reg [32*neurons_per_cluster-1:0] weight_mem [0:max_weight_rows-1];
    
    integer i;

    // Load weights into memory
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // Reset logic if needed
            for (i = 0; i < max_weight_rows; i = i + 1) begin
                weight_mem[i] <= 0; // Initialize all weights to zero
            end
        end else if (load_weight) begin
            weight_mem[weight_addr] <= weight_in;
        end
    end

    // Read weights from memory
    assign weight_out = weight_mem[weight_addr];
    
endmodule

