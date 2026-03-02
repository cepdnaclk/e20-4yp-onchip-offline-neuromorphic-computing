// =============================================================================
//  accel_mem_integration_tb.v
//  Integration test: Port B Write -> Shared Memory -> Port A (Wishbone) Read
//
//  What this tests:
//    1. Write test values to shared memory via Port B (mimics accelerator dump)
//    2. Read them back via Port A Wishbone (mimics RISC-V CPU)
//    3. Verify values match -- proves Port B->Memory->Port A path works
//    4. Also test Port A write -> Port B read path
//
//  Run from neuron_accelerator/ folder:
//    iverilog -o integration_tb.vvp accel_mem_integration_tb.v && vvp integration_tb.vvp
// =============================================================================

`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns/100ps

module accel_mem_integration_tb;

    localparam MEM_DEPTH  = 8192;
    localparam BASE_ADDR  = 32'h2000_0000;
    localparam VMEM_BASE  = 13'h1000;   // word 0x1000
    localparam SPIKE_BASE = 13'h1100;   // word 0x1100
    localparam N_NEURONS  = 16;

    reg clk, rst;
    initial clk = 0;
    always #5 clk = ~clk;

    // Port B: testbench drives directly (mimics accelerator dump FSM)
    reg  [12:0] portb_addr;
    reg  [31:0] portb_din;
    reg         portb_we, portb_en;
    wire [31:0] portb_dout;

    // Port A: Wishbone (mimics RISC-V CPU)
    reg  [31:0] wb_adr_i, wb_dat_i;
    wire [31:0] wb_dat_o;
    reg  [3:0]  wb_sel_i;
    reg         wb_we_i, wb_stb_i, wb_cyc_i;
    wire        wb_ack_o, collision_detect;

    // DUT: Shared Memory only
    snn_shared_memory_wb #(
        .MEM_DEPTH(MEM_DEPTH),
        .BASE_ADDR(BASE_ADDR)
    ) smem (
        .clk(clk), .rst(rst),
        .wb_adr_i(wb_adr_i), .wb_dat_i(wb_dat_i),
        .wb_dat_o(wb_dat_o), .wb_sel_i(wb_sel_i),
        .wb_we_i(wb_we_i), .wb_stb_i(wb_stb_i),
        .wb_cyc_i(wb_cyc_i), .wb_ack_o(wb_ack_o),
        .portb_addr(portb_addr), .portb_din(portb_din),
        .portb_dout(portb_dout), .portb_we(portb_we),
        .portb_en(portb_en), .collision_detect(collision_detect)
    );

    initial begin #200_000; $display("TIMEOUT"); $finish; end

    // Wishbone read task
    reg [31:0] wb_result;
    task wb_read;
        input [31:0] baddr;
        begin
            @(posedge clk); #1;
            wb_adr_i=baddr; wb_we_i=0; wb_stb_i=1; wb_cyc_i=1; wb_sel_i=4'hF;
            @(posedge wb_ack_o); @(posedge clk); #1;
            wb_result = wb_dat_o;
            wb_stb_i=0; wb_cyc_i=0;
        end
    endtask

    // Wishbone write task
    task wb_write;
        input [31:0] baddr;
        input [31:0] wdata;
        begin
            @(posedge clk); #1;
            wb_adr_i=baddr; wb_dat_i=wdata; wb_we_i=1;
            wb_stb_i=1; wb_cyc_i=1; wb_sel_i=4'hF;
            @(posedge wb_ack_o); @(posedge clk); #1;
            wb_stb_i=0; wb_cyc_i=0; wb_we_i=0;
        end
    endtask

    // Port B write task (1 word per call, like the dump FSM)
    task portb_write;
        input [12:0] waddr;
        input [31:0] wdata;
        begin
            @(posedge clk); #1;
            portb_addr=waddr; portb_din=wdata; portb_we=1; portb_en=1;
            @(posedge clk); #1;
            portb_we=0; portb_en=0;
        end
    endtask

    integer i, pass_cnt, fail_cnt;
    reg [31:0] test_vmem [0:15];
    reg [31:0] read_val, expected;

    initial begin
        $dumpfile("integration_test.vcd");
        $dumpvars(0, accel_mem_integration_tb);
        pass_cnt=0; fail_cnt=0;

        rst=1; portb_we=0; portb_en=0; portb_addr=0; portb_din=0;
        wb_stb_i=0; wb_cyc_i=0; wb_we_i=0; wb_sel_i=4'hF;
        repeat(5) @(posedge clk); rst=0; repeat(5) @(posedge clk);

        // Known test values (non-trivial to catch address bugs)
        for (i=0; i<N_NEURONS; i=i+1)
            test_vmem[i] = 32'hAA000000 | i;

        // ==========================================================
        // TEST 1: Port B write -> Port A (Wishbone) read
        //         (Accelerator dumps V_mem, CPU reads it back)
        // ==========================================================
        $display("\n=== TEST 1: Port B write then Wishbone read ===");
        for (i=0; i<N_NEURONS; i=i+1)
            portb_write(VMEM_BASE + i[12:0], test_vmem[i]);
        portb_write(SPIKE_BASE, 32'hDEAD_BEEF);

        $display("  Verifying V_mem words via Wishbone:");
        for (i=0; i<N_NEURONS; i=i+1) begin
            wb_read(BASE_ADDR + (VMEM_BASE + i[12:0]) * 4);
            expected = test_vmem[i];
            $display("  vmem[%02d] = 0x%08h (exp 0x%08h) %s",
                     i, wb_result, expected,
                     (wb_result===expected) ? "PASS" : "FAIL");
            if (wb_result===expected) pass_cnt=pass_cnt+1;
            else fail_cnt=fail_cnt+1;
        end

        wb_read(BASE_ADDR + SPIKE_BASE * 4);
        $display("  spike[0] = 0x%08h (exp 0xDEADBEEF) %s",
                 wb_result,
                 (wb_result===32'hDEAD_BEEF) ? "PASS" : "FAIL");
        if (wb_result===32'hDEAD_BEEF) pass_cnt=pass_cnt+1;
        else fail_cnt=fail_cnt+1;

        // ==========================================================
        // TEST 2: Port A write -> Port B read
        //         (CPU writes updated weight, accelerator reads it)
        // ==========================================================
        $display("\n=== TEST 2: Wishbone write then Port B read ===");
        wb_write(BASE_ADDR + 32'h0100, 32'hCAFEBABE);
        @(posedge clk); #1;
        portb_addr = 13'h0040;  // byte 0x100 = word 0x40
        portb_en=1; portb_we=0;
        @(posedge clk); @(posedge clk); #1;
        portb_en=0;
        $display("  portb_dout = 0x%08h (exp 0xCAFEBABE) %s",
                 portb_dout,
                 (portb_dout===32'hCAFEBABE) ? "PASS" : "FAIL");
        if (portb_dout===32'hCAFEBABE) pass_cnt=pass_cnt+1;
        else fail_cnt=fail_cnt+1;

        // ==========================================================
        // TEST 3: No collision
        // ==========================================================
        $display("\n=== TEST 3: No collision detected ===");
        if (!collision_detect) begin $display("  PASS"); pass_cnt=pass_cnt+1; end
        else begin $display("  FAIL"); fail_cnt=fail_cnt+1; end

        $display("\n==============================================");
        $display(" Results: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
        $display("==============================================");
        if (fail_cnt==0)
            $display(" *** ALL PASSED: Shared Memory integration verified ***");
        else
            $display(" *** SOME FAILED ***");
        $finish;
    end

endmodule
