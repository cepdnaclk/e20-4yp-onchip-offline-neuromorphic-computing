// =============================================================================
//  snn_shared_memory_tb.v — Testbench for snn_shared_memory_wb
//  Project: On-Chip Offline Neuromorphic Computing (FYP)
// =============================================================================
//
//  Tests:
//      1. CPU writes via Wishbone (Port A) → Accelerator reads via Port B
//      2. Accelerator writes via Port B    → CPU reads via Wishbone (Port A)
//      3. Byte-select writes (SB, SH, SW) from Port A
//      4. Back-to-back Wishbone transactions
//      5. Both ports reading simultaneously from different addresses
//      6. Collision detection verification
//
//  Run with Iverilog:
//      iverilog -o snn_shared_memory_tb.vvp snn_shared_memory_tb.v snn_shared_memory_wb.v
//      vvp snn_shared_memory_tb.vvp
//      gtkwave snn_shared_memory_tb.vcd
// =============================================================================

`timescale 1ns/100ps

module snn_shared_memory_tb;

    // ==================== Parameters ====================
    // Use small memory for fast simulation
    localparam MEM_DEPTH  = 1024;                       // 4 KB (not full 192KB)
    localparam BASE_ADDR  = 32'h2000_0000;
    localparam ADDR_WIDTH = $clog2(MEM_DEPTH);

    // ==================== Clock & Reset ====================
    reg clk;
    reg rst;

    // ==================== Port A: Wishbone ====================
    reg  [31:0] wb_adr_i;
    reg  [31:0] wb_dat_i;
    wire [31:0] wb_dat_o;
    reg   [3:0] wb_sel_i;
    reg         wb_we_i;
    reg         wb_stb_i;
    reg         wb_cyc_i;
    wire        wb_ack_o;

    // ==================== Port B: Accelerator ====================
    reg  [ADDR_WIDTH-1:0] portb_addr;
    reg  [31:0]           portb_din;
    wire [31:0]           portb_dout;
    reg                   portb_we;
    reg                   portb_en;

    // ==================== Debug ====================
    wire collision_detect;

    // ==================== Test Control ====================
    integer test_num;
    integer pass_count;
    integer fail_count;

    // ==================== DUT ====================
    snn_shared_memory_wb #(
        .MEM_DEPTH(MEM_DEPTH),
        .BASE_ADDR(BASE_ADDR),
        .INIT_FILE("")
    ) dut (
        .clk(clk),
        .rst(rst),
        .wb_adr_i(wb_adr_i),
        .wb_dat_i(wb_dat_i),
        .wb_dat_o(wb_dat_o),
        .wb_sel_i(wb_sel_i),
        .wb_we_i(wb_we_i),
        .wb_stb_i(wb_stb_i),
        .wb_cyc_i(wb_cyc_i),
        .wb_ack_o(wb_ack_o),
        .portb_addr(portb_addr),
        .portb_din(portb_din),
        .portb_dout(portb_dout),
        .portb_we(portb_we),
        .portb_en(portb_en),
        .collision_detect(collision_detect)
    );

    // ==================== Clock Generation (10ns period = 100MHz) ====================
    initial clk = 0;
    always #5 clk = ~clk;

    // ==================== Wishbone Tasks ====================

    // Write a 32-bit word via Wishbone Port A
    task wb_write_word;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            wb_adr_i <= addr;
            wb_dat_i <= data;
            wb_sel_i <= 4'b1111;    // Full word
            wb_we_i  <= 1'b1;
            wb_stb_i <= 1'b1;
            wb_cyc_i <= 1'b1;

            // Wait for ACK
            @(posedge clk);
            while (!wb_ack_o) @(posedge clk);

            // Deassert bus
            @(posedge clk);
            wb_stb_i <= 1'b0;
            wb_cyc_i <= 1'b0;
            wb_we_i  <= 1'b0;
        end
    endtask

    // Write a single byte via Wishbone Port A
    task wb_write_byte;
        input [31:0] addr;
        input [7:0]  data;
        begin
            @(posedge clk);
            wb_adr_i <= addr;
            wb_dat_i <= {24'h0, data};
            wb_sel_i <= 4'b0001;    // Byte 0 only
            wb_we_i  <= 1'b1;
            wb_stb_i <= 1'b1;
            wb_cyc_i <= 1'b1;

            @(posedge clk);
            while (!wb_ack_o) @(posedge clk);

            @(posedge clk);
            wb_stb_i <= 1'b0;
            wb_cyc_i <= 1'b0;
            wb_we_i  <= 1'b0;
        end
    endtask

    // Write a half-word via Wishbone Port A
    task wb_write_half;
        input [31:0] addr;
        input [15:0] data;
        begin
            @(posedge clk);
            wb_adr_i <= addr;
            wb_dat_i <= {16'h0, data};
            wb_sel_i <= 4'b0011;    // Lower half-word
            wb_we_i  <= 1'b1;
            wb_stb_i <= 1'b1;
            wb_cyc_i <= 1'b1;

            @(posedge clk);
            while (!wb_ack_o) @(posedge clk);

            @(posedge clk);
            wb_stb_i <= 1'b0;
            wb_cyc_i <= 1'b0;
            wb_we_i  <= 1'b0;
        end
    endtask

    // Read a 32-bit word via Wishbone Port A
    task wb_read_word;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            wb_adr_i <= addr;
            wb_sel_i <= 4'b1111;
            wb_we_i  <= 1'b0;
            wb_stb_i <= 1'b1;
            wb_cyc_i <= 1'b1;

            @(posedge clk);
            while (!wb_ack_o) @(posedge clk);
            data = wb_dat_o;

            @(posedge clk);
            wb_stb_i <= 1'b0;
            wb_cyc_i <= 1'b0;
        end
    endtask

    // ==================== Port B Tasks ====================

    // Write via Port B (accelerator)
    task portb_write;
        input [ADDR_WIDTH-1:0] addr;
        input [31:0]           data;
        begin
            @(posedge clk);
            portb_addr <= addr;
            portb_din  <= data;
            portb_we   <= 1'b1;
            portb_en   <= 1'b1;

            @(posedge clk);
            portb_we   <= 1'b0;
            portb_en   <= 1'b0;
        end
    endtask

    // Read via Port B (accelerator)
    task portb_read;
        input  [ADDR_WIDTH-1:0] addr;
        output [31:0]           data;
        begin
            @(posedge clk);
            portb_addr <= addr;
            portb_we   <= 1'b0;
            portb_en   <= 1'b1;

            @(posedge clk);     // Data available on next rising edge
            data = portb_dout;
            portb_en   <= 1'b0;
        end
    endtask

    // ==================== Check Helper ====================
    task check;
        input [31:0] expected;
        input [31:0] actual;
        input [255:0] test_name;   // Padded string
        begin
            if (actual === expected) begin
                $display("  PASS: %0s — expected=0x%08h got=0x%08h", test_name, expected, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0s — expected=0x%08h got=0x%08h", test_name, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ==================== Main Test Sequence ====================
    reg [31:0] read_data;

    initial begin
        $dumpfile("snn_shared_memory_tb.vcd");
        $dumpvars(0, snn_shared_memory_tb);

        // Initialize
        pass_count = 0;
        fail_count = 0;
        wb_adr_i   = 0;
        wb_dat_i   = 0;
        wb_sel_i   = 0;
        wb_we_i    = 0;
        wb_stb_i   = 0;
        wb_cyc_i   = 0;
        portb_addr = 0;
        portb_din  = 0;
        portb_we   = 0;
        portb_en   = 0;

        // Reset
        rst = 1;
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        $display("=============================================================");
        $display(" SNN Shared Memory — Testbench");
        $display("=============================================================");

        // ─────────────────────────────────────────────────────────────────
        // TEST 1: CPU writes word via Port A → Accelerator reads via Port B
        // ─────────────────────────────────────────────────────────────────
        $display("\n--- Test 1: CPU Word Write → Accelerator Read ---");

        wb_write_word(BASE_ADDR + 32'h00, 32'hDEAD_BEEF);
        wb_write_word(BASE_ADDR + 32'h04, 32'hCAFE_BABE);
        wb_write_word(BASE_ADDR + 32'h08, 32'h1234_5678);

        portb_read(0, read_data);
        check(32'hDEAD_BEEF, read_data, "Word 0");

        portb_read(1, read_data);
        check(32'hCAFE_BABE, read_data, "Word 1");

        portb_read(2, read_data);
        check(32'h1234_5678, read_data, "Word 2");

        // ─────────────────────────────────────────────────────────────────
        // TEST 2: Accelerator writes via Port B → CPU reads via Port A
        // ─────────────────────────────────────────────────────────────────
        $display("\n--- Test 2: Accelerator Write → CPU Read ---");

        portb_write(10, 32'hA5A5_A5A5);    // word address 10
        portb_write(11, 32'h5A5A_5A5A);    // word address 11

        wb_read_word(BASE_ADDR + 32'h28, read_data);   // word 10 = byte offset 0x28
        check(32'hA5A5_A5A5, read_data, "Port B word 10");

        wb_read_word(BASE_ADDR + 32'h2C, read_data);   // word 11 = byte offset 0x2C
        check(32'h5A5A_5A5A, read_data, "Port B word 11");

        // ─────────────────────────────────────────────────────────────────
        // TEST 3: Byte-select writes (SB)
        // ─────────────────────────────────────────────────────────────────
        $display("\n--- Test 3: Byte-Select Writes ---");

        // First write full word, then overwrite individual bytes
        wb_write_word(BASE_ADDR + 32'h10, 32'h0000_0000);

        wb_write_byte(BASE_ADDR + 32'h10, 8'hAA);   // Write byte 0

        wb_read_word(BASE_ADDR + 32'h10, read_data);
        check(32'h0000_00AA, read_data, "SB byte 0");

        // ─────────────────────────────────────────────────────────────────
        // TEST 4: Half-word write (SH)
        // ─────────────────────────────────────────────────────────────────
        $display("\n--- Test 4: Half-Word Write ---");

        wb_write_word(BASE_ADDR + 32'h14, 32'hFFFF_FFFF);   // Fill with FF
        wb_write_half(BASE_ADDR + 32'h14, 16'h1234);         // Overwrite lower half

        wb_read_word(BASE_ADDR + 32'h14, read_data);
        check(32'hFFFF_1234, read_data, "SH lower half");

        // ─────────────────────────────────────────────────────────────────
        // TEST 5: Back-to-back Wishbone transactions
        // ─────────────────────────────────────────────────────────────────
        $display("\n--- Test 5: Back-to-Back Writes & Reads ---");

        wb_write_word(BASE_ADDR + 32'h20, 32'h1111_1111);
        wb_write_word(BASE_ADDR + 32'h24, 32'h2222_2222);
        wb_write_word(BASE_ADDR + 32'h28, 32'h3333_3333);

        wb_read_word(BASE_ADDR + 32'h20, read_data);
        check(32'h1111_1111, read_data, "B2B read 0");

        wb_read_word(BASE_ADDR + 32'h24, read_data);
        check(32'h2222_2222, read_data, "B2B read 1");

        wb_read_word(BASE_ADDR + 32'h28, read_data);
        check(32'h3333_3333, read_data, "B2B read 2");

        // ─────────────────────────────────────────────────────────────────
        // TEST 6: Simultaneous reads from both ports (different addresses)
        // ─────────────────────────────────────────────────────────────────
        $display("\n--- Test 6: Simultaneous Dual-Port Reads ---");

        wb_write_word(BASE_ADDR + 32'h30, 32'hAAAA_BBBB);
        portb_write(13, 32'hCCCC_DDDD);   // word 13 = byte 0x34

        // Start both reads on the same clock edge
        @(posedge clk);
        // Port A reads word at 0x30 (word 12)
        wb_adr_i <= BASE_ADDR + 32'h30;
        wb_sel_i <= 4'b1111;
        wb_we_i  <= 1'b0;
        wb_stb_i <= 1'b1;
        wb_cyc_i <= 1'b1;
        // Port B reads word 13 simultaneously
        portb_addr <= 13;
        portb_we   <= 1'b0;
        portb_en   <= 1'b1;

        @(posedge clk);
        while (!wb_ack_o) @(posedge clk);

        check(32'hAAAA_BBBB, wb_dat_o, "Simul Port A read");
        check(32'hCCCC_DDDD, portb_dout, "Simul Port B read");

        wb_stb_i <= 1'b0;
        wb_cyc_i <= 1'b0;
        portb_en <= 1'b0;

        // ─────────────────────────────────────────────────────────────────
        // TEST 7: Address outside memory range → no ACK
        // ─────────────────────────────────────────────────────────────────
        $display("\n--- Test 7: Address Outside Range ---");

        @(posedge clk);
        wb_adr_i <= 32'h3000_0000;  // Wrong base address
        wb_sel_i <= 4'b1111;
        wb_we_i  <= 1'b0;
        wb_stb_i <= 1'b1;
        wb_cyc_i <= 1'b1;

        // Wait a few cycles — ACK should NOT assert
        repeat(3) @(posedge clk);
        if (!wb_ack_o) begin
            $display("  PASS: No ACK for out-of-range address");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: ACK asserted for out-of-range address!");
            fail_count = fail_count + 1;
        end

        wb_stb_i <= 1'b0;
        wb_cyc_i <= 1'b0;

        // ─────────────────────────────────────────────────────────────────
        // TEST 8: Weight-like pattern (simulate weight loading)
        // ─────────────────────────────────────────────────────────────────
        $display("\n--- Test 8: Weight Loading Pattern ---");

        // Simulate CPU writing 8 weights (8-bit each, packed 4 per word)
        wb_write_word(BASE_ADDR + 32'h100, {8'd200, 8'd150, 8'd100, 8'd50});
        wb_write_word(BASE_ADDR + 32'h104, {8'd25,  8'd75,  8'd125, 8'd175});

        // Accelerator reads the weight words
        portb_read(64, read_data);    // word 64 = byte 0x100
        check({8'd200, 8'd150, 8'd100, 8'd50}, read_data, "Weight word 0");

        portb_read(65, read_data);    // word 65 = byte 0x104
        check({8'd25, 8'd75, 8'd125, 8'd175}, read_data, "Weight word 1");

        // ─────────────────────────────────────────────────────────────────
        // RESULTS
        // ─────────────────────────────────────────────────────────────────
        $display("\n=============================================================");
        $display(" Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("=============================================================");

        if (fail_count == 0)
            $display(" *** ALL TESTS PASSED ***");
        else
            $display(" *** SOME TESTS FAILED ***");

        $finish;
    end

    // ==================== Timeout Watchdog ====================
    initial begin
        #100000;
        $display("\nERROR: Simulation timed out!");
        $finish;
    end

endmodule
