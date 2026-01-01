`timescale 1ns/100ps

module potential_decay(
    input wire clk,
    input wire rst,
    input wire load,
    input wire time_step,
    input wire rst_potential,
    input wire [2:0] mode,
    input wire [31:0] new_potential,
    output reg [63:0] output_potential_decay
);
    
    reg [63:0] membrane_potential;
    wire v_squared_done;
    wire izi2_done;
    wire [63:0] v_squared;
    wire [63:0] izi_first_term, temp_izi_first;
    wire [63:0] izi_second_term;
    reg start;
    reg prev_time_step;

    multiplier_32bit v_squared_mul(
        .clk(clk),
        .rst(rst),
        .start(start),
        .A(membrane_potential[31:0]),
        .B(membrane_potential[31:0]),
        .result(v_squared),
        .done(v_squared_done)
    );

    assign temp_izi_first = {v_squared[61:0], 2'b00} + v_squared; // v_squared * 4 + v_squared = v_squared * 5
    assign izi_first_term = {{7{temp_izi_first[63]}}, temp_izi_first[63:7]}; // Shift right by 7 bits to get the first term of Izhikevich model = v_squared * 5 / 128 = v_squared * 0.0390625 ~ 0.04

    multiplier_32bit izi2(
        .clk(clk),
        .rst(rst),
        .start(start),
        .A(membrane_potential[31:0]),
        .B(32'h0006),
        .result(izi_second_term),
        .done(izi2_done)
    ); // v * 6 = 6v

    always @(posedge clk) begin
        if (rst) begin
            start <= 0;
        end else if (load) begin
            if(mode == `IZHI || mode == `QUAD) begin
                start <= 1;
            end
        end else begin
            start <= 0;
        end
    end

    always @(posedge clk) begin
        prev_time_step <= time_step;
        if (rst) begin
            output_potential_decay <= 0;
        end else if (time_step && !prev_time_step) begin
            if (mode == `INIT) begin
                // Do nothing
            end else if (mode == `LIF2) begin
                output_potential_decay <= {{1{membrane_potential[63]}}, membrane_potential[63:1]};
            end else if (mode == `LIF4) begin
                output_potential_decay <= {{2{membrane_potential[63]}}, membrane_potential[63:2]};
            end else if (mode == `LIF8) begin
                output_potential_decay <= {{3{membrane_potential[63]}}, membrane_potential[63:3]};
            end else if (mode == `LIF24) begin
                output_potential_decay <= {{1{membrane_potential[63]}}, membrane_potential[63:1]} + {{2{membrane_potential[63]}}, membrane_potential[63:2]};
            end else if (mode == `IZHI || mode == `QUAD) begin
                output_potential_decay <= membrane_potential;
            end else if(mode == `IDLE) begin
                // do nothing
            end
        end
    end

    always @(posedge clk) begin
        if (rst || rst_potential) begin
            membrane_potential <= 0;
        end else if(mode == `IZHI) begin
            if(v_squared_done & izi2_done) begin
                membrane_potential <= izi_first_term - izi_second_term + 32'h008C0000; // 0.04*v^2 - 6v + 140 
            end
        end else if(mode == `QUAD) begin
            if(v_squared_done) begin
                membrane_potential <= v_squared;
            end
        end

        if (load) begin
            membrane_potential <= {{32{new_potential[31]}}, new_potential};
        end
    end

endmodule
