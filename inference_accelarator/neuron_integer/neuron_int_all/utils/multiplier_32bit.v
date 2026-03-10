`timescale 1ns/1ps

module multiplier_32bit (
    input wire clk,
    input wire rst,
    input wire start,
    input wire signed [31:0] A,
    input wire signed [31:0] B,
    output reg signed [63:0] result,
    output reg done
);

    reg [4:0] count;
    reg signed [63:0] acc;
    reg signed [63:0] acc_next;
    reg signed [63:0] multiplicand;
    reg [32:0] multiplier;
    reg running, prev_start;

    always @(posedge clk) begin
        if (rst) begin
            result <= 0;
            acc <= 0;
            acc_next <= 0;
            multiplicand <= 0;
            multiplier <= 0;
            count <= 0;
            done <= 0;
            running <= 0;
            prev_start <= 0;
        end else begin
            prev_start <= start;
            if (start && !prev_start && !running) begin
                multiplicand <= { {32{A[31]}}, A };
                multiplier <= { B, 1'b0 };  // 33 bits
                acc <= 0;
                acc_next <= 0;
                count <= 0;
                done <= 0;
                running <= 1;
            end else if (running) begin
                // Compute acc_next (accumulator after add/sub)
                case (multiplier[2:0])
                    3'b000, 3'b111: acc <= acc;
                    3'b001, 3'b010: acc <= acc + multiplicand;
                    3'b011:         acc <= acc + (multiplicand << 1);
                    3'b100:         acc <= acc - (multiplicand << 1);
                    3'b101, 3'b110: acc <= acc - multiplicand;
                    default:        acc <= acc; // default case
                endcase

                // Shift after updating acc
                multiplicand <= multiplicand << 2;
                multiplier <= { {2{multiplier[32]}}, multiplier[32:2] };
                
                count <= count + 1;

                if (count == 15) begin
                    result <= acc;
                    done <= 1;
                    running <= 0;
                end
            end else begin
                done <= 0;
            end
        end
    end
endmodule
