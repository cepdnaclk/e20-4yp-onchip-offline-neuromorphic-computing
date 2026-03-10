// ============================================================================
// test_state2_cpu_lut.v — STATE 2 Test: Shared Memory + Surrogate LUT Integration
// ============================================================================
// 
// GOAL: Test the complete STATE 2 (Surrogate Substitution) pipeline:
//   1. Read a V_mem value from snn_shared_memory_wb via Wishbone Port A
//   2. Use V_mem as an address offset and query surrogate_lut_wb
//   3. Write the returned surrogate gradient back to shared memory
//
// TEST SCENARIO:
//   - Pre-load shared memory at address 0x2002_8000 with V_mem = 0x00000005
//   - Verify reads return correct value
//   - Query LUT at address 0xA000_0014 (offset = 5*4)
//   - Verify LUT returns correct surrogate gradient (0xFC for v=5)
//   - Write result back to 0x2002_8004
//   - Read and verify write completed
//
// CHECKS (5 total):
//   1. Initial write to shared memory succeeds
//   2. Read from shared memory returns V_mem = 0x00000005
//   3. Read from LUT returns correct surrogate value (0xFC)
//   4. Write result to shared memory succeeds
//   5. Verify written value persists on read
//
// ============================================================================

`timescale 1ns/100ps

module test_state2_cpu_lut ();
    reg         clk, rst;
    
    // ====== Test Control ======
    integer test_count = 0;
    integer pass_count = 0;
    integer fail_count = 0;
    
    // ====== Wishbone Bus (32-bit) ======
    reg         wb_cyc, wb_stb, wb_we;
    reg  [31:0] wb_adr, wb_dat_o;           // Master → Slave
    reg  [ 3:0] wb_sel;
    wire [31:0] wb_dat_i;                   // Slave → Master (multiplexed)
    wire        wb_ack;
    
    // ====== Peripheral Acks ======
    wire wb_ack_mem, wb_ack_lut;
    wire [31:0] wb_dat_mem, wb_dat_lut;
    
    // ====== Expected LUT Values ======
    reg [7:0] expected_surrogate [0:255];
    
    // ====== Instantiate Shared Memory (Wishbone Slave) ======
    snn_shared_memory_wb #(
        .BASE_ADDR(32'h2000_0000)
    ) shared_mem (
        .clk(clk),
        .rst(rst),
        // Port A: Wishbone
        .wb_adr_i(wb_adr),
        .wb_dat_i(wb_dat_o),
        .wb_dat_o(wb_dat_mem),
        .wb_sel_i(wb_sel),
        .wb_we_i(wb_we),
        .wb_stb_i(wb_stb),
        .wb_cyc_i(wb_cyc),
        .wb_ack_o(wb_ack_mem),
        // Port B: Direct (tied off for this test)
        .portb_addr(16'b0),
        .portb_din(32'b0),
        .portb_dout(),
        .portb_we(1'b0),
        .portb_en(1'b0),
        .collision_detect()
    );
    
    // ====== Instantiate Surrogate LUT (Wishbone Slave) ======
    surrogate_lut_wb #(
        .BASE_ADDR(32'hA000_0000)
    ) lut (
        .clk(clk),
        .rst(rst),
        .wb_adr_i(wb_adr),
        .wb_dat_i(32'b0),              // LUT is read-only
        .wb_dat_o(wb_dat_lut),
        .wb_sel_i(4'b1111),
        .wb_we_i(1'b0),                // Never write to LUT
        .wb_stb_i(wb_stb),
        .wb_cyc_i(wb_cyc),
        .wb_ack_o(wb_ack_lut)
    );
    
    // ====== Bus Multiplexer (address-based chip select) ======
    // Shared Memory: 0x2000_0000 → 0x2003_FFFF (address bits [31:18] = 0x0800)
    // Surrogate LUT: 0xA000_0000 → 0xA000_03FF (address bits [31:10] = 0x28000)
    wire cs_mem = wb_cyc & wb_stb & (wb_adr[31:18] == 14'h0800);
    wire cs_lut = wb_cyc & wb_stb & (wb_adr[31:10] == 22'h28000);
    
    assign wb_ack   = cs_mem ? wb_ack_mem : cs_lut ? wb_ack_lut : 1'b0;
    assign wb_dat_i = cs_mem ? wb_dat_mem : cs_lut ? wb_dat_lut : 32'hDEADBEEF;
    
    // ====== Clock Generation (10 MHz) ======
    initial clk = 1'b0;
    always #50 clk = ~clk;  // 100ns period = 10 MHz
    
    // ====== Test Stimulus ======
    initial begin
        // ---- Initialization ----
        rst = 1'b1;
        wb_cyc = 1'b0;
        wb_stb = 1'b0;
        wb_we  = 1'b0;
        wb_adr = 32'b0;
        wb_dat_o = 32'b0;
        wb_sel = 4'b1111;
        
        // Load expected LUT values
        $readmemh("../../surrogate_lut/surrogate_lut.hex", expected_surrogate);
        $display("\n========== STATE 2 Integration Test ==========");
        $display("Testing: Shared Memory + Surrogate LUT via Wishbone");
        $display("=============================================\n");
        
        #1000 rst = 1'b0;
        #100;
        
        // ====== TEST 1: Write V_mem to Shared Memory ======
        $display("[TEST 1] Write V_mem=0x00000005 to shared_mem[0x2002_8000]");
        write_wishbone(32'h2002_8000, 32'h0000_0005, 4'b1111);
        wait_wishbone();
        pass_test(1);
        #100;
        
        // ====== TEST 2: Read V_mem Back ======
        $display("[TEST 2] Read V_mem from shared_mem[0x2002_8000]");
        read_wishbone(32'h2002_8000);
        wait_wishbone();
        if (wb_dat_i == 32'h0000_0005) begin
            $display("  ✓ PASS: Read V_mem = 0x%08x", wb_dat_i);
            pass_test(2);
        end else begin
            $display("  ✗ FAIL: Read V_mem = 0x%08x (expected 0x00000005)", wb_dat_i);
            fail_test(2);
        end
        #100;
        
        // ====== TEST 3: Query Surrogate LUT ======
        // Address calculation: BASE (0xA000_0000) + (V_mem_byte * 4)
        // V_mem = 5 → offset = 5*4 = 0x14 → address = 0xA000_0014
        $display("[TEST 3] Query LUT at address 0xA000_0014 (V_mem=5)");
        read_wishbone(32'hA000_0014);
        wait_wishbone();
        if (wb_dat_i[7:0] == expected_surrogate[5]) begin
            $display("  ✓ PASS: LUT[5] = 0x%02x (surrogate gradient for v=5)", 
                     wb_dat_i[7:0]);
            pass_test(3);
        end else begin
            $display("  ✗ FAIL: LUT[5] = 0x%02x (expected 0x%02x)", 
                     wb_dat_i[7:0], expected_surrogate[5]);
            fail_test(3);
        end
        #100;
        
        // ====== TEST 4: Write Surrogate Result Back ======
        $display("[TEST 4] Write surrogate result (0x%02x) to shared_mem[0x2002_8004]", 
                 expected_surrogate[5]);
        write_wishbone(32'h2002_8004, {24'b0, expected_surrogate[5]}, 4'b0001);
        wait_wishbone();
        pass_test(4);
        #100;
        
        // ====== TEST 5: Verify Write Persisted ======
        $display("[TEST 5] Read back from shared_mem[0x2002_8004] to verify");
        read_wishbone(32'h2002_8004);
        wait_wishbone();
        if (wb_dat_i[7:0] == expected_surrogate[5]) begin
            $display("  ✓ PASS: Surrogate value persisted: 0x%02x", wb_dat_i[7:0]);
            pass_test(5);
        end else begin
            $display("  ✗ FAIL: Surrogate value = 0x%02x (expected 0x%02x)", 
                     wb_dat_i[7:0], expected_surrogate[5]);
            fail_test(5);
        end
        #100;
        
        // ====== Print Summary ======
        print_summary();
        $finish;
    end
    
    // ====== Wishbone Helper Tasks ======
    task write_wishbone(input [31:0] addr, input [31:0] data, input [3:0] sel);
        @(posedge clk);
        wb_adr = addr;
        wb_dat_o = data;
        wb_sel = sel;
        wb_cyc = 1'b1;
        wb_stb = 1'b1;
        wb_we = 1'b1;
    endtask
    
    task read_wishbone(input [31:0] addr);
        @(posedge clk);
        wb_adr = addr;
        wb_sel = 4'b1111;
        wb_cyc = 1'b1;
        wb_stb = 1'b1;
        wb_we = 1'b0;
    endtask
    
    task wait_wishbone();
        @(posedge clk);
        while (~wb_ack) @(posedge clk);
        @(posedge clk);
        wb_cyc = 1'b0;
        wb_stb = 1'b0;
    endtask
    
    task pass_test(input integer id);
        test_count = test_count + 1;
        pass_count = pass_count + 1;
        $display("  [PASS] Test %d\n", id);
    endtask
    
    task fail_test(input integer id);
        test_count = test_count + 1;
        fail_count = fail_count + 1;
        $display("  [FAIL] Test %d\n", id);
    endtask
    
    task print_summary();
        $display("\n=============================================");
        $display(" FINAL RESULT: %d/%d TESTS PASSED", pass_count, test_count);
        if (fail_count == 0)
            $display(" ✓ ALL TESTS PASSED — STATE 2 pipeline works!");
        else
            $display(" ✗ %d test(s) failed — check above for details", fail_count);
        $display("=============================================\n");
    endtask
    
endmodule
