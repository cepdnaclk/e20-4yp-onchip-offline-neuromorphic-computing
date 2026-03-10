`timescale 1ns/100ps

`include "surrogate_lut_wb.v"

// =============================================================================
//  surrogate_lut_wb_tb.v — Testbench for Surrogate Gradient LUT
//  Project: On-Chip Offline Neuromorphic Computing (FYP)
// =============================================================================
//
//  Tests:
//    1. Reset behaviour:          ACK stays low during reset
//    2. Read v=0   (index   0):  peak gradient, expect 0xFF
//    3. Read v=+64 (index  64):  positive side, expect 0x1C
//    4. Read v=-64 (index 192):  negative side, expect 0x1C (symmetric)
//    5. Symmetry check:           idx 64 result == idx 192 result
//    6. Read v=+127 (index 127): far positive, expect 0x0A (near-zero)
//    7. Write attempt:            ACK returned, but ROM value unchanged on re-read
//    8. Back-to-back reads:       two consecutive read cycles both ACK correctly
//
//  Run:
//    iverilog -o surrogate_lut_wb_tb.vvp surrogate_lut_wb_tb.v
//    vvp surrogate_lut_wb_tb.vvp
//    gtkwave surrogate_lut_wb_tb.vcd   (optional)
// =============================================================================

module surrogate_lut_wb_tb;

    // ---- DUT Signals ----
    reg         wb_clk_i;
    reg         wb_rst_i;
    reg  [31:0] wb_adr_i;
    reg  [31:0] wb_dat_i;
    reg   [3:0] wb_sel_i;
    reg         wb_we_i;
    reg         wb_stb_i;
    reg         wb_cyc_i;
    wire [31:0] wb_dat_o;
    wire        wb_ack_o;

    // ---- Test tracking ----
    integer pass_count;
    integer fail_count;

    // ---- BASE_ADDR used in DUT (match here for address calculations) ----
    localparam [31:0] BASE = 32'hA000_0000;

    // ---- Instantiate DUT ----
    surrogate_lut_wb #(
        .BASE_ADDR(BASE)
    ) dut (
        .wb_clk_i(wb_clk_i),
        .wb_rst_i(wb_rst_i),
        .wb_adr_i(wb_adr_i),
        .wb_dat_i(wb_dat_i),
        .wb_sel_i(wb_sel_i),
        .wb_we_i (wb_we_i),
        .wb_stb_i(wb_stb_i),
        .wb_cyc_i(wb_cyc_i),
        .wb_dat_o(wb_dat_o),
        .wb_ack_o(wb_ack_o)
    );

    // ---- Clock: 10 ns period ----
    always #5 wb_clk_i = ~wb_clk_i;

    // ---- Helper Tasks ----

    // Perform a single Wishbone read and return lower byte of data
    task wb_read;
        input  [7:0]  lut_index;   // raw 8-bit V_mem value (= LUT index)
        output [7:0]  read_data;
        begin
            @(negedge wb_clk_i);
            wb_adr_i = BASE + {22'b0, lut_index, 2'b00};  // word-aligned
            wb_dat_i = 32'h0;
            wb_sel_i = 4'hF;
            wb_we_i  = 1'b0;
            wb_stb_i = 1'b1;
            wb_cyc_i = 1'b1;
            // Wait for ACK
            @(posedge wb_clk_i);
            #1;  // small settle
            while (!wb_ack_o) @(posedge wb_clk_i);
            read_data = wb_dat_o[7:0];
            // Deassert
            @(negedge wb_clk_i);
            wb_stb_i = 1'b0;
            wb_cyc_i = 1'b0;
        end
    endtask

    // Perform a Wishbone write (should be ignored by ROM)
    task wb_write;
        input [7:0]  lut_index;
        input [31:0] write_data;
        begin
            @(negedge wb_clk_i);
            wb_adr_i = BASE + {22'b0, lut_index, 2'b00};
            wb_dat_i = write_data;
            wb_sel_i = 4'hF;
            wb_we_i  = 1'b1;
            wb_stb_i = 1'b1;
            wb_cyc_i = 1'b1;
            @(posedge wb_clk_i);
            #1;
            while (!wb_ack_o) @(posedge wb_clk_i);
            @(negedge wb_clk_i);
            wb_stb_i = 1'b0;
            wb_cyc_i = 1'b0;
            wb_we_i  = 1'b0;
        end
    endtask

    // Check helper
    task check;
        input [127:0] test_name;
        input         condition;
        begin
            if (condition) begin
                $display("[PASS] %0s", test_name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %0s", test_name);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ---- Simulation ----
    reg [7:0] result_a, result_b;

    initial begin
        $dumpfile("surrogate_lut_wb_tb.vcd");
        $dumpvars(0, surrogate_lut_wb_tb);

        // Init
        wb_clk_i = 0;
        wb_rst_i = 0;
        wb_adr_i = 32'h0;
        wb_dat_i = 32'h0;
        wb_sel_i = 4'hF;
        wb_we_i  = 0;
        wb_stb_i = 0;
        wb_cyc_i = 0;
        pass_count = 0;
        fail_count = 0;

        $display("==============================================");
        $display("  Surrogate Gradient LUT Testbench");
        $display("  BASE_ADDR = 0x%08X", BASE);
        $display("==============================================");

        // ---- TEST 1: Reset behaviour ----
        $display("\n[TEST 1] Reset behaviour");
        wb_rst_i = 1;
        wb_stb_i = 1;
        wb_cyc_i = 1;
        wb_we_i  = 0;
        wb_adr_i = BASE;  // try reading during reset
        @(posedge wb_clk_i); #1;
        check("ACK=0 during reset", wb_ack_o == 1'b0);
        wb_rst_i = 0;
        wb_stb_i = 0;
        wb_cyc_i = 0;
        #20;

        // ---- TEST 2: Read v=0 (index 0) — peak gradient ----
        $display("\n[TEST 2] Read v=0 (index 0) — expect 0xFF");
        wb_read(8'd0, result_a);
        $display("  Got: 0x%02X  Expected: 0xFF", result_a);
        check("v=0 peak gradient = 0xFF", result_a == 8'hFF);

        // ---- TEST 3: Read v=+64 (index 64) ----
        $display("\n[TEST 3] Read v=+64 (index 64) — expect 0x1C");
        wb_read(8'd64, result_a);
        $display("  Got: 0x%02X  Expected: 0x1C", result_a);
        check("v=+64 gradient = 0x1C", result_a == 8'h1C);

        // ---- TEST 4: Read v=-64 (index 192) ----
        $display("\n[TEST 4] Read v=-64 (index 192) — expect 0x1C (symmetric)");
        wb_read(8'd192, result_b);
        $display("  Got: 0x%02X  Expected: 0x1C", result_b);
        check("v=-64 gradient = 0x1C", result_b == 8'h1C);

        // ---- TEST 5: Symmetry check ----
        $display("\n[TEST 5] Symmetry: result(v=+64) == result(v=-64)");
        check("Symmetric gradient values match", result_a == result_b);

        // ---- TEST 6: Read v=+127 (index 127) — near zero ----
        $display("\n[TEST 6] Read v=+127 (index 127) — expect 0x0A");
        wb_read(8'd127, result_a);
        $display("  Got: 0x%02X  Expected: 0x0A", result_a);
        check("v=+127 near-zero gradient = 0x0A", result_a == 8'h0A);

        // ---- TEST 7: Write ignored — ROM unchanged ----
        $display("\n[TEST 7] Write 0xDEADBEEF to index 0, then read back");
        wb_write(8'd0, 32'hDEADBEEF);
        wb_read(8'd0, result_a);
        $display("  Read after write: 0x%02X  Expected: 0xFF (unchanged)", result_a);
        check("ROM is read-only, write ignored", result_a == 8'hFF);

        // ---- TEST 8: Back-to-back reads ----
        $display("\n[TEST 8] Back-to-back reads (index 0 then index 64)");
        wb_read(8'd0,  result_a);
        wb_read(8'd64, result_b);
        $display("  Read[0]=0x%02X (expect 0xFF), Read[64]=0x%02X (expect 0x1C)",
                 result_a, result_b);
        check("Back-to-back read[0] = 0xFF",  result_a == 8'hFF);
        check("Back-to-back read[64] = 0x1C", result_b == 8'h1C);

        // ---- Summary ----
        $display("\n==============================================");
        $display("  RESULTS: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display("  *** All tests passed! ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        $display("==============================================\n");

        #50;
        $finish;
    end

endmodule
