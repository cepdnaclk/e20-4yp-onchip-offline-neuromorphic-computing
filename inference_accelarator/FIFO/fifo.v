module fifo #(
    parameter WIDTH = 11,        // Data width (11 bits)
    parameter DEPTH = 8          // FIFO depth (8 entries)
) (
    input wire clk,
    input wire rst,              // Active-high reset
    input wire wr_en,            // Write enable
    input wire [WIDTH-1:0] din,  // 11-bit input data
    input wire rd_en,            // Read enable
    output reg [WIDTH-1:0] dout, // 11-bit output data
    output wire full,            // FIFO full flag
    output wire empty,           // FIFO empty flag
    output reg [$clog2(DEPTH):0] count       // Number of items in FIFO
);

    // Memory array
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    
    // Pointers
    reg [$clog2(DEPTH)-1:0] wr_ptr;           // Write pointer
    reg [$clog2(DEPTH)-1:0] rd_ptr;           // Read pointer
    
    // Read and write enables gated by full/empty status
    wire do_write = wr_en && !full;
    wire do_read = rd_en && !empty;
    
    // Empty and full flags derived from pointers and count
    assign empty = (count == 0);
    assign full = (count == DEPTH);
    
    // Handle pointer updates and data movement
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // Reset pointers and count
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
            dout <= 0;
        end
        else begin
            // Update read pointer and output data
            if (do_read) begin
                dout <= mem[rd_ptr];
                rd_ptr <= (rd_ptr == DEPTH-1) ? 0 : rd_ptr + 1;
            end else begin
                dout <= 0;
            end
            
            // Update write pointer and write data
            if (do_write) begin
                mem[wr_ptr] <= din;
                wr_ptr <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1;
            end
            
            // Update count based on operations
            case ({do_write, do_read})
                2'b01:   count <= count - 1; // Read only
                2'b10:   count <= count + 1; // Write only
                2'b11:   count <= count;     // Read and write (no change)
                default: count <= count;     // No operation
            endcase
        end
    end

endmodule