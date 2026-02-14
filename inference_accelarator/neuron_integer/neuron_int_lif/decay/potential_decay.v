`timescale 1ns/100ps

module potential_decay(
    input wire clk,
    input wire rst,
    input wire load,
    input wire time_step,
    input wire rst_potential,
    input wire [2:0] mode,
    input wire [31:0] new_potential,
    output reg [31:0] output_potential_decay
);
    
    reg [31:0] membrane_potential;
    reg prev_time_step;

    always @(posedge clk) begin
        prev_time_step <= time_step;
        if (rst) begin
            output_potential_decay <= 0;
        end else if (time_step && !prev_time_step) begin
            if (mode == `INIT) begin
                // Do nothing
            end else if (mode == `LIF2) begin
                output_potential_decay <= {{1{membrane_potential[31]}}, membrane_potential[31:1]};
            end else if (mode == `LIF4) begin
                output_potential_decay <= {{2{membrane_potential[31]}}, membrane_potential[31:2]};
            end else if (mode == `LIF8) begin
                output_potential_decay <= {{3{membrane_potential[31]}}, membrane_potential[31:3]};
            end else if (mode == `LIF24) begin
                output_potential_decay <= {{1{membrane_potential[31]}}, membrane_potential[31:1]} + {{2{membrane_potential[31]}}, membrane_potential[31:2]};
            end else if(mode == `IDLE) begin
                // do nothing
            end
        end
    end

    always @(posedge clk) begin
        if (rst || rst_potential) begin
            membrane_potential <= 0;
        end
        if (load) begin
            membrane_potential <= {{32{new_potential[31]}}, new_potential};
        end
    end

endmodule
