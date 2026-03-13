// =============================================================================
//  state2_integration_tb.v — Level 7: State 2 Surrogate Substitution
//  End-to-End Integration Test
// =============================================================================
//
//  PURPOSE:
//    Verifies the complete STATE 2 data path:
//
//      snn_shared_memory_wb (BRAM)
//            │  Port A: Wishbone (CPU reads V_mem, writes gradient)
//            │  Port B: Direct (pre-loaded with known V_mem values)
//            ↓
//      CPU FSM (in testbench, mimicking state2_surrogate.c)
//            │  reads vmem_region[i] via Port A
//            │  extracts bits [23:16] → lut_index
//            ↓
//      surrogate_lut_wb (ROM)
//            │  returns 8-bit gradient for lut_index
//            ↓
//      CPU FSM writes gradient back to vmem_region[i] via Port A
//
//    After the pass: shared memory VMEM region must contain surrogate
//    gradient bytes (not raw V_mem Q16.16 words).
//
//  TEST VECTORS (from snn_integration_dump_tb / real_mem_integration_tb):
//    vmem[0] = 0x00050000  v_int=5   lut[5]  = 0xBF  (grad ≈ 0.749)
//    vmem[1] = 0x00050000  v_int=5   lut[5]  = 0xBF
//    vmem[2] = 0x00140000  v_int=20  lut[20] = 0x61  (grad ≈ 0.380)
//    vmem[3] = 0x00000000  v_int=0   lut[0]  = 0xFF  (grad = 1.0, peak)
//
//  PASS CRITERIA (8 checks):
//    1.  vmem[0] after pass = 0x000000BF  (was 0x00050000)
//    2.  vmem[1] after pass = 0x000000BF  (was 0x00050000)
//    3.  vmem[2] after pass = 0x00000061  (was 0x00140000)
//    4.  vmem[3] after pass = 0x000000FF  (was 0x00000000, v=0 → peak)
//    5.  LUT query for index 5   returns 0xBF
//    6.  LUT query for index 20  returns 0x61
//    7.  LUT query for index 0   returns 0xFF
//    8.  No collision_detect asserted during CPU pass
//
// =============================================================================
// Compile with explicit source files — no `include needed:
//   iverilog -g2012 -Wno-timescale \
//     snn_shared_memory_wb.v surrogate_lut_wb.v state2_integration_tb.v
`timescale 1ns/100ps

module state2_integration_tb;

// ─── Parameters ──────────────────────────────────────────────────────────────
localparam MEM_DEPTH  = 8192;
localparam ADDR_WIDTH = 13;                    // $clog2(8192)
localparam [31:0] MEM_BASE = 32'h2000_0000;
localparam [31:0] LUT_BASE = 32'hA000_0000;

// Shared-memory word offsets (must match accelerator config)
localparam [ADDR_WIDTH-1:0] VMEM_WORD_BASE  = 13'h1000;  // word 4096
localparam [ADDR_WIDTH-1:0] SPIKE_WORD_BASE = 13'h1100;  // word 4352

// Number of test neurons
localparam N_TEST = 4;

// Expected gradient values (from lut_rom in surrogate_lut_wb.v)
localparam [7:0] EXP_GRAD_V5  = 8'hBF;   // lut[5]  → v=5   grad≈0.749
localparam [7:0] EXP_GRAD_V20 = 8'h61;   // lut[20] → v=20  grad≈0.380
localparam [7:0] EXP_GRAD_V0  = 8'hFF;   // lut[0]  → v=0   grad=1.0 (peak)

// ─── Clock ───────────────────────────────────────────────────────────────────
reg clk = 0;
always #5 clk = ~clk;  // 100 MHz

// ─── Reset ───────────────────────────────────────────────────────────────────
reg rst = 1;

// ─── Wishbone bus (shared by both peripherals — separate signals per slave) ──
// Port A → snn_shared_memory_wb
reg  [31:0] mem_adr  = 0;
reg  [31:0] mem_dati = 0;
wire [31:0] mem_dato;
reg   [3:0] mem_sel  = 4'hF;
reg         mem_we   = 0;
reg         mem_stb  = 0;
reg         mem_cyc  = 0;
wire        mem_ack;

// Port A → surrogate_lut_wb
reg  [31:0] lut_adr  = 0;
reg  [31:0] lut_dati = 0;
wire [31:0] lut_dato;
reg         lut_stb  = 0;
reg         lut_cyc  = 0;
wire        lut_ack;

// Port B — direct write into shared memory (pre-load test V_mem values)
reg  [ADDR_WIDTH-1:0] portb_addr = 0;
reg  [31:0]           portb_din  = 0;
reg                   portb_we   = 0;
reg                   portb_en   = 0;
wire [31:0]           portb_dout;

// Collision detect
wire collision_detect;
integer collision_count = 0;

always @(posedge clk)
    if (collision_detect) collision_count <= collision_count + 1;

// ─── DUT Instantiation ───────────────────────────────────────────────────────
snn_shared_memory_wb #(
    .MEM_DEPTH (MEM_DEPTH),
    .BASE_ADDR (MEM_BASE),
    .INIT_FILE ("")
) shared_mem (
    .clk          (clk),
    .rst          (rst),
    .wb_adr_i     (mem_adr),
    .wb_dat_i     (mem_dati),
    .wb_dat_o     (mem_dato),
    .wb_sel_i     (mem_sel),
    .wb_we_i      (mem_we),
    .wb_stb_i     (mem_stb),
    .wb_cyc_i     (mem_cyc),
    .wb_ack_o     (mem_ack),
    .portb_addr   (portb_addr),
    .portb_din    (portb_din),
    .portb_dout   (portb_dout),
    .portb_we     (portb_we),
    .portb_en     (portb_en),
    .collision_detect(collision_detect)
);

surrogate_lut_wb #(
    .BASE_ADDR (LUT_BASE)
) lut (
    .wb_clk_i (clk),
    .wb_rst_i (rst),
    .wb_adr_i (lut_adr),
    .wb_dat_i (lut_dati),
    .wb_sel_i (4'hF),
    .wb_we_i  (1'b0),
    .wb_stb_i (lut_stb),
    .wb_cyc_i (lut_cyc),
    .wb_dat_o (lut_dato),
    .wb_ack_o (lut_ack)
);

// ─── VCD ─────────────────────────────────────────────────────────────────────
initial begin
    $dumpfile("/home/ravindu/FYP/e20-4yp-onchip-offline-neuromorphic-computing/surrogate_lut/state2_integration_tb.vcd");
    $dumpvars(0, state2_integration_tb);
end

// ─── Wishbone tasks ───────────────────────────────────────────────────────────
// Write one 32-bit word to shared_memory via Port A
task mem_write_word;
    input [31:0] byte_addr;
    input [31:0] data;
    begin
        @(negedge clk);
        mem_adr  = byte_addr;
        mem_dati = data;
        mem_sel  = 4'hF;
        mem_we   = 1;
        mem_stb  = 1;
        mem_cyc  = 1;
        @(posedge clk); #1;
        while (!mem_ack) @(posedge clk);
        @(negedge clk);
        mem_stb  = 0;
        mem_cyc  = 0;
        mem_we   = 0;
        mem_adr  = 0;
    end
endtask

// Read one 32-bit word from shared_memory via Port A
task mem_read_word;
    input  [31:0] byte_addr;
    output [31:0] data;
    begin
        @(negedge clk);
        mem_adr  = byte_addr;
        mem_dati = 0;
        mem_sel  = 4'hF;
        mem_we   = 0;
        mem_stb  = 1;
        mem_cyc  = 1;
        @(posedge clk); #1;
        while (!mem_ack) @(posedge clk);
        data = mem_dato;
        @(negedge clk);
        mem_stb  = 0;
        mem_cyc  = 0;
        mem_adr  = 0;
    end
endtask

// Query surrogate_lut_wb for a given 8-bit index
task lut_query;
    input  [7:0]  lut_index;
    output [7:0]  gradient;
    reg    [31:0] lut_word;
    begin
        @(negedge clk);
        lut_adr  = LUT_BASE + {22'd0, lut_index, 2'b00}; // index × 4
        lut_stb  = 1;
        lut_cyc  = 1;
        @(posedge clk); #1;
        while (!lut_ack) @(posedge clk);
        lut_word = lut_dato;
        @(negedge clk);
        lut_stb  = 0;
        lut_cyc  = 0;
        lut_adr  = 0;
        gradient = lut_word[7:0];
    end
endtask

// ─── Score tracking ──────────────────────────────────────────────────────────
integer pass_count = 0;
integer fail_count = 0;

task check;
    input        ok;
    input [255:0] msg;
    begin
        if (ok) begin $display("  [PASS] %s", msg); pass_count = pass_count + 1; end
        else    begin $display("  [FAIL] %s", msg); fail_count = fail_count + 1; end
    end
endtask

// ─── Helper: byte address for a vmem word-offset entry ───────────────────────
// byte_addr = MEM_BASE + (VMEM_WORD_BASE + i) * 4
function [31:0] vmem_addr;
    input integer i;
    vmem_addr = MEM_BASE + ((VMEM_WORD_BASE + i) << 2);
endfunction

// ─── Main test ───────────────────────────────────────────────────────────────
reg [31:0] readback;
reg  [7:0] grad;
integer    i;

initial begin
    $display("=============================================================");
    $display(" Level 7: State 2 Surrogate Substitution — End-to-End Test");
    $display(" snn_shared_memory_wb  ←→  surrogate_lut_wb");
    $display("=============================================================\n");

    // ── Reset ──
    rst = 1;
    repeat(10) @(posedge clk);
    rst = 0;
    repeat(2) @(posedge clk);

    // ─────────────────────────────────────────────────────────────────────────
    //  PHASE 1: Pre-load V_mem values into shared memory via Port B
    //           (simulating what the accelerator dump FSM writes in STATE 1)
    // ─────────────────────────────────────────────────────────────────────────
    $display("[PHASE 1] Pre-loading V_mem via Port B (simulating STATE 1 dump)...");

    // vmem[0] = 5.0 Q16.16 = 0x00050000  → v_int = 5,  lut_index = 5
    portb_addr = VMEM_WORD_BASE + 0; portb_din = 32'h00050000; portb_we = 1; portb_en = 1;
    @(posedge clk); #1;
    portb_we = 0; portb_en = 0;

    // vmem[1] = 5.0 Q16.16 = 0x00050000  → v_int = 5,  lut_index = 5
    portb_addr = VMEM_WORD_BASE + 1; portb_din = 32'h00050000; portb_we = 1; portb_en = 1;
    @(posedge clk); #1;
    portb_we = 0; portb_en = 0;

    // vmem[2] = 20.0 Q16.16 = 0x00140000 → v_int = 20, lut_index = 20
    portb_addr = VMEM_WORD_BASE + 2; portb_din = 32'h00140000; portb_we = 1; portb_en = 1;
    @(posedge clk); #1;
    portb_we = 0; portb_en = 0;

    // vmem[3] = 0.0 Q16.16 = 0x00000000  → v_int = 0,  lut_index = 0 (PEAK)
    portb_addr = VMEM_WORD_BASE + 3; portb_din = 32'h00000000; portb_we = 1; portb_en = 1;
    @(posedge clk); #1;
    portb_we = 0; portb_en = 0;

    repeat(2) @(posedge clk);
    $display("[PHASE 1] Done — 4 V_mem words written via Port B.\n");

    // ─────────────────────────────────────────────────────────────────────────
    //  PHASE 2: Verify Port A reads back the raw V_mem values
    // ─────────────────────────────────────────────────────────────────────────
    $display("[PHASE 2] Verifying Port A can read back raw V_mem values...");
    for (i = 0; i < N_TEST; i = i + 1) begin
        mem_read_word(vmem_addr(i), readback);
        $display("  vmem[%0d] = 0x%08h", i, readback);
    end
    $display("[PHASE 2] Done.\n");

    // ─────────────────────────────────────────────────────────────────────────
    //  PHASE 3: Verify LUT standalone queries (before touching shared memory)
    // ─────────────────────────────────────────────────────────────────────────
    $display("[PHASE 3] Standalone LUT queries...");

    lut_query(8'd5,  grad);
    $display("  lut[5]  = 0x%02h  (expect 0x%02h, v=5  grad≈0.749)", grad, EXP_GRAD_V5);
    check(grad == EXP_GRAD_V5,  "LUT index=5  returns 0xBF");

    lut_query(8'd20, grad);
    $display("  lut[20] = 0x%02h  (expect 0x%02h, v=20 grad≈0.380)", grad, EXP_GRAD_V20);
    check(grad == EXP_GRAD_V20, "LUT index=20 returns 0x61");

    lut_query(8'd0,  grad);
    $display("  lut[0]  = 0x%02h  (expect 0x%02h, v=0  grad=1.0 PEAK)", grad, EXP_GRAD_V0);
    check(grad == EXP_GRAD_V0,  "LUT index=0  returns 0xFF (peak)");

    $display("[PHASE 3] Done.\n");

    // ─────────────────────────────────────────────────────────────────────────
    //  PHASE 4: STATE 2 PASS — CPU firmware behaviour in RTL
    //
    //    For each neuron i in 0..N_TEST-1:
    //      1. Read vmem_region[i]  via Port A (mem_read_word)
    //      2. Extract lut_index = vmem_word[23:16]
    //      3. Query lut_query(lut_index) → gradient
    //      4. Write gradient back to vmem_region[i] via Port A (mem_write_word)
    // ─────────────────────────────────────────────────────────────────────────
    $display("[PHASE 4] STATE 2 pass — surrogate substitution loop...");
    for (i = 0; i < N_TEST; i = i + 1) begin
        // Step 1: Read V_mem
        mem_read_word(vmem_addr(i), readback);

        // Step 2: Extract 8-bit LUT index from bits [23:16]
        // (Q16.16: integer part in [31:16], lower 8 bits of integer = [23:16])
        lut_query(readback[23:16], grad);

        // Step 4: Write gradient back (32-bit, zero-extended)
        mem_write_word(vmem_addr(i), {24'd0, grad});

        $display("  [%0d] vmem=0x%08h  lut_idx=%0d  grad=0x%02h",
                 i, readback, readback[23:16], grad);
    end
    $display("[PHASE 4] Surrogate substitution complete.\n");

    // ─────────────────────────────────────────────────────────────────────────
    //  PHASE 5: Read back and verify — gradients must be in memory now
    // ─────────────────────────────────────────────────────────────────────────
    $display("[PHASE 5] Verifying gradients in shared memory after STATE 2 pass...");

    $display("\n=============================================================");
    $display(" VERIFICATION");
    $display("=============================================================");

    // vmem[0]: was 0x00050000 → expect 0x000000BF
    mem_read_word(vmem_addr(0), readback);
    $display("  vmem[0] = 0x%08h  (expect 0x%08h)", readback, {24'd0, EXP_GRAD_V5});
    check(readback == {24'd0, EXP_GRAD_V5},
          "vmem[0] = 0xBF after pass (v=5.0 → grad=0xBF)");

    // vmem[1]: was 0x00050000 → expect 0x000000BF
    mem_read_word(vmem_addr(1), readback);
    $display("  vmem[1] = 0x%08h  (expect 0x%08h)", readback, {24'd0, EXP_GRAD_V5});
    check(readback == {24'd0, EXP_GRAD_V5},
          "vmem[1] = 0xBF after pass (v=5.0 → grad=0xBF)");

    // vmem[2]: was 0x00140000 → expect 0x00000061
    mem_read_word(vmem_addr(2), readback);
    $display("  vmem[2] = 0x%08h  (expect 0x%08h)", readback, {24'd0, EXP_GRAD_V20});
    check(readback == {24'd0, EXP_GRAD_V20},
          "vmem[2] = 0x61 after pass (v=20.0 → grad=0x61)");

    // vmem[3]: was 0x00000000 → expect 0x000000FF (peak)
    mem_read_word(vmem_addr(3), readback);
    $display("  vmem[3] = 0x%08h  (expect 0x%08h)", readback, {24'd0, EXP_GRAD_V0});
    check(readback == {24'd0, EXP_GRAD_V0},
          "vmem[3] = 0xFF after pass (v=0 → peak grad=0xFF)");

    $display("\n  -- Infrastructure --");
    check(collision_count == 0,
          "No Port A/B collisions during STATE 2 pass");

    $display("\n=============================================================");
    if (fail_count == 0) begin
        $display(" ALL %0d / 8 TESTS PASSED", pass_count);
        $display(" STATE 2 verified: raw V_mem → surrogate gradient");
        $display(" snn_shared_memory_wb + surrogate_lut_wb end-to-end OK.");
    end else
        $display(" %0d PASSED / %0d FAILED — check state2_integration_tb.vcd",
                 pass_count, fail_count);
    $display("=============================================================");

    $finish;
end

// ─── Watchdog ─────────────────────────────────────────────────────────────────
initial begin
    #500_000;
    $display("[TIMEOUT] 500us exceeded");
    $finish;
end

endmodule
