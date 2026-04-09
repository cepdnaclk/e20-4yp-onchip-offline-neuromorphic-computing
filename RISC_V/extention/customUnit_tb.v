`timescale 1ns / 1ps

// ============================================================================
// Testbench: custom_backprop_unit
//
// Verifies the 16-bit fixed-point backpropagation unit used in the custom
// RV32IM neuromorphic extension.  All arithmetic is Q8.8 (scaled by 256).
//
// Port widths match custom_backprop_unit:
//   error_term  : signed [15:0]
//   gradient_val: signed [15:0]
//   grad_valid  : 1-bit stream-valid qualifier
//   spike_status: 1-bit temporal gate (1 = neuron fired this step)
// ============================================================================

module custom_backprop_unit_tb;

    // --- 1. Signal Declarations ---
    reg         clk;
    reg         rst_n;
    reg         enable;
    reg  signed [15:0] error_term;
    reg  signed [15:0] gradient_val;
    reg         grad_valid;
    reg         spike_status;
    wire signed [31:0] delta_out;

    integer pass_count;
    integer fail_count;

    // --- 2. Instantiate the Unit Under Test (UUT) ---
    custom_backprop_unit uut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .error_term(error_term),
        .gradient_val(gradient_val),
        .grad_valid(grad_valid),
        .spike_status(spike_status),
        .delta_out(delta_out)
    );

    // --- 3. Clock Generation (10ns period = 100MHz) ---
    always #5 clk = ~clk;

    // --- 4. Check task ---
    task check;
        input signed [31:0] expected;
        input [127:0] label;
        begin
            if ($signed(delta_out) === expected) begin
                $display("[PASS] %s | delta_out=%0d", label, $signed(delta_out));
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %s | delta_out=%0d  expected=%0d",
                         label, $signed(delta_out), expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // --- 5. Stimulus Block ---
    initial begin
        // Initialise
        clk          = 0;
        rst_n        = 0;
        enable       = 0;
        grad_valid   = 0;
        spike_status = 0;
        error_term   = 0;
        gradient_val = 0;
        pass_count   = 0;
        fail_count   = 0;

        $dumpfile("backprop_sim.vcd");
        $dumpvars(0, custom_backprop_unit_tb);

        // Reset sequence
        #20 rst_n = 1;
        #10 enable = 1;

        // ----------------------------------------------------------------
        // TC1: spike_status=1, positive values — basic spike-gated delta
        //   dm_prev=0, error=100, grad=128
        //   effective_error = 100 + 0 = 100
        //   delta_calc = (100 * 128) >>> 8 = 12800 >>> 8 = 50
        //   delta_spike_gated = 50  (spike=1)
        //   dm_next = 0             (spike=1 resets dm)
        // ----------------------------------------------------------------
        error_term   = 16'sd100;
        gradient_val = 16'sd128;
        grad_valid   = 1'b1;
        spike_status = 1'b1;
        #10;
        check(32'sd50, "TC1 spike=1  error= 100 grad=128");

        // ----------------------------------------------------------------
        // TC2: spike_status=0 — no spike, temporal delta accumulates
        //   dm_prev=0 (TC1 spike reset it), error=200, grad=64
        //   delta_calc = (200 * 64) >>> 8 = 12800 >>> 8 = 50
        //   delta_spike_gated = 0   (no spike)
        //   dm_next = 50
        // ----------------------------------------------------------------
        error_term   = 16'sd200;
        gradient_val = 16'sd64;
        spike_status = 1'b0;
        #10;
        check(32'sd0,  "TC2 spike=0  error= 200 grad= 64");

        // ----------------------------------------------------------------
        // TC3: spike_status=1 with temporal momentum from TC2
        //   dm_prev=50, error=50, grad=64, BETA=192 (0.75*256)
        //   beta_mul = 50 * 192 = 9600
        //   temporal_term = 9600 >>> 8 = 37
        //   effective_error = 50 + 37 = 87
        //   delta_calc = (87 * 64) >>> 8 = 5568 >>> 8 = 21
        //   delta_spike_gated = 21 (spike=1)
        //   dm_next = 0
        // ----------------------------------------------------------------
        error_term   = 16'sd50;
        gradient_val = 16'sd64;
        spike_status = 1'b1;
        #10;
        check(32'sd21, "TC3 spike=1  error=  50 grad= 64 (with temporal)");

        // ----------------------------------------------------------------
        // TC4: negative gradient (signed arithmetic), spike active
        //   dm_prev=0 (TC3 spike reset it), error=-100, grad=128
        //   delta_calc = (-100 * 128) >>> 8 = -12800 >>> 8 = -50
        //   delta_spike_gated = -50 (spike=1)
        // ----------------------------------------------------------------
        error_term   = -16'sd100;
        gradient_val = 16'sd128;
        spike_status = 1'b1;
        #10;
        check(-32'sd50, "TC4 spike=1  error=-100 grad=128 (neg grad)");

        // ----------------------------------------------------------------
        // TC5: grad_valid deasserted — output must clear to 0
        // ----------------------------------------------------------------
        grad_valid = 1'b0;
        #10;
        check(32'sd0,  "TC5 grad_valid=0 (output must be 0)");

        // Summary
        $display("----------------------------------------");
        $display("Results: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("[PASS] All custom_backprop_unit tests passed.");
        else
            $display("[FAIL] %0d test(s) failed.", fail_count);

        #50;
        $finish;
    end

endmodule