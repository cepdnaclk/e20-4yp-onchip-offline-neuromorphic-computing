module PISO_LIFO #(
    parameter DATA_WIDTH = 32,
    parameter DEPTH = 16,
    parameter SERIALIZE_BITS = 1
) (
    input wire clk, rst,
    input wire push,
    input wire pop_trigger,
    input wire [DATA_WIDTH-1:0] data_in,
    output reg serial_out,
    output reg busy,
    output reg [DATA_WIDTH-1:0] data_out,
    output reg data_valid
);

    integer i;
    reg [DATA_WIDTH-1:0] stack [0:DEPTH-1];
    reg [4:0] stack_ptr;
    reg [4:0] stream_count;
    reg [4:0] read_ptr;
    reg [DATA_WIDTH-1:0] shift_reg;
    reg [5:0] bit_count;

    always @(posedge clk or negedge rst) begin
        if (rst) begin
            stack_ptr <= 0;
            stream_count <= 0;
            read_ptr <= 0;
            shift_reg <= 0;
            bit_count <= 0;
            serial_out <= 0;
            busy <= 0;
            data_out <= 0;
            data_valid <= 0;
        end else begin
            data_valid <= 0;

            if (push && !busy && (stack_ptr < DEPTH)) begin
                stack[stack_ptr] <= data_in;
                stack_ptr <= stack_ptr + 1;
            end else if (pop_trigger && (stack_ptr > 0) && !busy) begin
                busy <= 1;
                if (SERIALIZE_BITS) begin
                    shift_reg <= stack[stack_ptr - 1];
                    stack_ptr <= stack_ptr - 1;
                    bit_count <= 0;
                end else begin
                    stream_count <= stack_ptr;
                    read_ptr <= stack_ptr - 1;
                    stack_ptr <= 0;
                end
            end else if (busy) begin
                if (SERIALIZE_BITS) begin
                    serial_out <= shift_reg[bit_count];
                    data_out <= {{(DATA_WIDTH-1){1'b0}}, shift_reg[bit_count]};
                    data_valid <= 1;
                    if (bit_count == DATA_WIDTH-1) begin
                        busy <= 0;
                    end else begin
                        bit_count <= bit_count + 1;
                    end
                end else begin
                    data_out <= stack[read_ptr];
                    serial_out <= stack[read_ptr][0];
                    data_valid <= 1;
                    if (stream_count == 1) begin
                        busy <= 0;
                        stream_count <= 0;
                    end else begin
                        stream_count <= stream_count - 1;
                        read_ptr <= read_ptr - 1;
                    end
                end
            end
        end
    end
endmodule