`timescale 1ns/100ps

module potential_adder (
    input wire clk,
    input wire rst,        
    input wire time_step,      
    input wire [31:0] input_weight, 
    input wire [63:0] decayed_potential,
    input wire [1:0] model,
    input wire [2:0] init_mode,
    input wire load,
    
    output reg  [31:0] final_potential,
    output reg  [31:0] v_pre_spike,     // pre-fire potential for backprop (REGISTERED, holds value)
    output reg  done,
    output reg  spike
);

    // Common Signals
    wire signed [63:0] weight_added;
    reg signed [31:0] u;

    // Internal Signals for Izhikevich Model
    wire signed [63:0] bv, a_bv_u, bv_u, a_bv_u_u;
    reg signed [31:0] a, b, c, d, v_threshold;
    
    reg bv_start, abv_start;
    wire bv_done, abv_done;
    
    reg [1:0] adder_state;

    reg prev_time_step;

    multiplier_32bit multIzhiBV (
        .clk(clk),
        .rst(rst),
        .start(bv_start),
        .A(b),
        .B(decayed_potential[47:16]), // decayed_potential / 65536 = decayed_potential * 2^(-16)
        .result(bv),
        .done(bv_done)
    );

    multiplier_32bit multIzhiaBVu (
        .clk(clk),
        .rst(rst),
        .start(abv_start),
        .A(a),
        .B(bv_u[47:16]), // bv_u / 65536 = bv_u * 2^(-16)
        .result(a_bv_u),
        .done(abv_done)
    );

    assign bv_u = (bv << 16) - {{32{u[31]}}, u}; // bv_u = bv * 65536 - u
    assign a_bv_u_u = -(a_bv_u << 16) + {{32{u[31]}},u};

    always @(posedge clk) begin
        prev_time_step <= time_step;
        if(rst) begin
            bv_start <= 0;
            abv_start <= 0;
            adder_state <= 0;
            prev_time_step <= 0;
        end else if (time_step && !prev_time_step) begin
            if (adder_state == 0) begin
                if (model == `IZHI_AD) begin
                    bv_start <= 1;
                    abv_start <= 0;
                    adder_state <= 1;
                end else begin
                    bv_start <= 0;
                    abv_start <= 0;
                    adder_state <= 2;
                end
            end
        end else if (bv_done) begin
            bv_start <= 0;
            abv_start <= 1;
        end else if (abv_done) begin
            bv_start <= 0;
            abv_start <= 0;
            adder_state <= 2;
        end else if (adder_state == 2) begin
            bv_start <= 0;
            abv_start <= 0;
            adder_state <= 0;
        end 
    end

    always @(posedge clk) begin
        if (rst) begin
            a <= 0;
            b <= 0;
            c <= 0;
            d <= 0;
            v_threshold <= 0;
            u <= 0;
        end else if (load) begin
            if (init_mode == `A) begin
                a <= input_weight;
            end else if (init_mode == `B) begin
                b <= input_weight;
            end else if (init_mode == `C) begin
                c <= input_weight;
            end else if (init_mode == `D) begin
                d <= input_weight;
            end else if (init_mode == `VT) begin
                v_threshold <= input_weight;
            end else if (init_mode == `U) begin
                u <= input_weight;
            end
        end else if (init_mode == `DEFAULT) begin
            if (adder_state == 2 && model == `IZHI_AD) begin
                u <= (weight_added > v_threshold) ? u + d : a_bv_u_u; // u = u + d if spike, else u = a * bv_u + u
            end
        end
    end

    assign weight_added = model == `IZHI_AD ? 
        {{32{input_weight[31]}}, input_weight} + decayed_potential - {{32{u[31]}}, u} // v^2 + 6 * v + 140 - u + I
        : {{32{input_weight[31]}}, input_weight} + decayed_potential; // LIF and QIF

    always @(posedge clk) begin
        if (rst) begin
            final_potential <= 0;
            spike           <= 0;
            done            <= 0;
            v_pre_spike     <= 0;  // cleared on reset
        end else if(adder_state == 2) begin
            if (model == `IZHI_AD) begin
                spike           <= (weight_added > v_threshold);
                final_potential <= (weight_added > v_threshold) ? c : weight_added[31:0];
            end else begin // LIF and QIF
                spike           <= (weight_added > v_threshold);
                final_potential <= (weight_added > v_threshold) ? 0 : weight_added;
            end
            v_pre_spike <= weight_added[31:0]; // latch pre-fire potential, holds until next timestep
            done <= 1;
        end else begin
            done  <= 0;
            spike <= 0;
            // v_pre_spike and final_potential HOLD their values (not reset here)
        end
    end

endmodule

// IZHIKEVICH MODEL
// Vt+1 = Vt + (0.04 Vt^2 + 5Vt - u + I) * dt
// dt = 1 timestep
// Vt+1 = Vt + 0.04 Vt^2 + 5Vt - u + I
// Vt+1 = 0.04 * Vt^2 + 6 * Vt - u + I

// u+1 = u + a * (b * Vt - u)
