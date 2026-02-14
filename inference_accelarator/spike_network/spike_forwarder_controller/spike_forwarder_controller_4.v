module spike_forwarder_controller_4 (
    input wire clk,
    input wire rst,
    input wire [7:0] data_in,
    input wire load_data,
    output reg load_row,
    output reg [2:0] row_index,
    output reg [4:0] forwarding_row
);

    always @(posedge clk) begin
        if (rst) begin
            load_row <= 0;
            row_index <= 3'b000;
            forwarding_row <= 5'b00000;
        end else if (load_data) begin
            load_row <= 1;
            row_index <= data_in[7:5];
            forwarding_row <= data_in[4:0];
        end else begin
            load_row <= 0;
        end
    end

endmodule
