module incoming_forwarder #(
    parameter incoming_weight_table_rows = 32,    // Number of rows in incoming weight table
    parameter max_weight_table_rows = 32, // Maximum number of rows in the weight table
    parameter weight_address_buffer_depth = 8 // Depth of the weight address buffer
)(
    // Module interface
    input wire clk,                     // Clock signal
    input wire rst,                   // reset signal
    input wire [10:0] packet,         // Spike packet 11bit
    input wire [$clog2(weight_address_buffer_depth)-1:0] address_buffer_count,  // Current count of addresses in the buffer
    output reg [$clog2(max_weight_table_rows)-1:0] weight_addr_out,  // Output weight address vector
    output reg address_buffer_wr_en,  // Write enable for address buffer
    output wire forwarder_done,
    
    // Forwarder control signals
    input wire forwarder_mode,          // Mode selector: 0=forward, 1=store
    input wire [5:0] cluster_id,        // 6-bit cluster identifier
    input wire load_cluster_index,  // load signal for cluster index load
    input wire [15:0] base_weight_addr, // Base weight address
    input wire load_addr_in,          // Signal to store incoming weights

    // fifo control signals
    input wire empty,               // FIFO empty flag
    output wire rd_en            // Read enable
);

    // Storage for weights and their addresses
    reg [6:0] cluster_id_table [0:31];
    reg [$clog2(max_weight_table_rows)-1:0] base_weight_addr_reg;
    reg [4:0] row_index;
    
    // Control registers
    reg wait_for_data;

    assign rd_en = !empty && address_buffer_count + 2 < weight_address_buffer_depth;  // Enable read if FIFO is not empty and address buffer has space
    assign forwarder_done = !(rd_en | wait_for_data);  // Forwarder is done when not waiting for data

    reg [4:0] found_row_index;
    reg match_found;
    
    integer i;  // Loop variable

    always @(*) begin
        match_found = 0;
        found_row_index = 0;

        if (wait_for_data) begin
            for (i = 0; i < 32; i = i + 1) begin
                if (cluster_id_table[i] != 6'h3F && cluster_id_table[i] == packet[10:5]) begin
                    match_found = 1;
                    found_row_index = i;
                end
            end
        end
    end


    always @(posedge clk) begin
        if (rst) begin
            // Reset all outputs and internal state
            weight_addr_out <= 0;  // Reset weight address output
            address_buffer_wr_en <= 0;  // Disable write to address buffer
            wait_for_data <= 0;  // Reset wait for data flag
            // found_row_index <= 0;  // Reset found row index
            // match_found <= 0;  // Reset match found flag
            row_index <= 0;
            base_weight_addr_reg <= 0;

            // Clear weight and ID tables
            for (i = 0; i < 32; i = i + 1) begin
                cluster_id_table[i] <= 6'h3F;
            end
        end else if(!forwarder_mode) begin
            wait_for_data <= rd_en;  // Wait for data if FIFO is not empty
            
            if  (wait_for_data) begin
                if (match_found) begin
                    weight_addr_out <= base_weight_addr_reg + (found_row_index << 5) + packet[4:0];
                    address_buffer_wr_en <= 1;
                end else begin
                    // No match found, do not load weights
                    weight_addr_out <= 0;  // Use incoming address
                    address_buffer_wr_en <= 0;  // Disable write to address buffer
                end
            end else begin
                // Not waiting for data, reset address buffer write enable
                address_buffer_wr_en <= 0;
                weight_addr_out <= 0;  // Use incoming address
            end
        end else if(forwarder_mode) begin
            // Storage mode: record incoming weights at specified row_index
            if(load_addr_in) begin
                base_weight_addr_reg <= base_weight_addr;
            end else if(load_cluster_index) begin
                cluster_id_table[row_index] <= {1'b0, cluster_id[5:0]};
                row_index <= row_index + 1;
            end
        end
    end

endmodule