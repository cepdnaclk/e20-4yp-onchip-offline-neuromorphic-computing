module spike_forwarder_controller_8 (
    input wire clk,
    input wire rst,
    input wire [7:0] data_in,
    input wire load_data,
    output reg load_row,
    output reg [3:0] row_index,
    output reg [8:0] forwarding_row
);
    reg state;

    always @(posedge clk) begin
        if (rst) begin
            state <= 0;
            load_row <= 0;
            row_index <= 4'b0000;
            forwarding_row <= 9'b000000000;
        end else if (load_data) begin
            if(state == 0) begin
                row_index <= data_in[7:4];
                forwarding_row[8] <= data_in[0];
                load_row <= 0;
                state <= 1;
            end else begin
                forwarding_row[7:0] <= data_in[7:0];
                load_row <= 1;
                state <= 0;
            end
        end else begin
            load_row <= 0;
            forwarding_row <= 0;
        end
    end
    
endmodule