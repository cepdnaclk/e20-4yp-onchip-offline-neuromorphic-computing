// =============================================================================
// CPU_wb_tb.v — Optimized Testbench for CPU_wb (Wishbone RISC-V CPU)
// =============================================================================
// Uses 0-WAIT-STATE combinational SRAM (same as LiteX on-chip SRAM).
// This gives 1 instruction per cycle — matching original CPU speed.
// =============================================================================

`include "CPU_wb.v"

module CPU_wb_tb;
    reg CLK, RESET;

    // Instruction Bus
    wire        ibus_cyc, ibus_stb;
    wire [31:0] ibus_adr;
    wire [31:0] ibus_dat_r;
    wire        ibus_ack;

    // Data Bus
    wire        dbus_cyc, dbus_stb, dbus_we;
    wire [31:0] dbus_adr, dbus_dat_w;
    wire [3:0]  dbus_sel;
    wire [31:0] dbus_dat_r;
    wire        dbus_ack;

    // CPU
    CPU_wb cpu_wb_inst(
        .CLK(CLK), .RESET(RESET),
        .ibus_cyc_o(ibus_cyc), .ibus_stb_o(ibus_stb),
        .ibus_adr_o(ibus_adr), .ibus_dat_i(ibus_dat_r), .ibus_ack_i(ibus_ack),
        .dbus_cyc_o(dbus_cyc), .dbus_stb_o(dbus_stb), .dbus_we_o(dbus_we),
        .dbus_adr_o(dbus_adr), .dbus_dat_o(dbus_dat_w), .dbus_sel_o(dbus_sel),
        .dbus_dat_i(dbus_dat_r), .dbus_ack_i(dbus_ack)
    );

    // =========================================================================
    // 0-WAIT-STATE Instruction SRAM (Combinational — like LiteX on-chip SRAM)
    // Responds in the SAME cycle — no pipeline stalls for instruction fetch!
    // =========================================================================
    reg [31:0] imem [0:1023];

    initial begin
        $readmemh("../c_program/mini_snn.hex", imem);
    end

    // Combinational: ack and data available immediately
    assign ibus_dat_r = (ibus_cyc && ibus_stb) ? imem[ibus_adr[11:2]] : 32'b0;
    assign ibus_ack   = ibus_cyc && ibus_stb;

    // =========================================================================
    // 0-WAIT-STATE Data SRAM (Combinational — like LiteX on-chip SRAM)
    // Responds in the SAME cycle — no pipeline stalls for load/store!
    // =========================================================================
    reg [7:0] dmem [0:4095];

    integer k;
    initial begin
        for (k = 0; k < 4096; k = k + 1)
            dmem[k] = 8'b0;
    end

    // Combinational read
    assign dbus_dat_r = {dmem[dbus_adr[11:0] + 3], dmem[dbus_adr[11:0] + 2], 
                         dmem[dbus_adr[11:0] + 1], dmem[dbus_adr[11:0] + 0]};
    assign dbus_ack   = dbus_cyc && dbus_stb;

    // Synchronous write (must be clocked for proper behavior)
    always @(negedge CLK) begin
        if (dbus_cyc && dbus_stb && dbus_we) begin
            if (dbus_sel[0]) dmem[dbus_adr[11:0] + 0] <= dbus_dat_w[7:0];
            if (dbus_sel[1]) dmem[dbus_adr[11:0] + 1] <= dbus_dat_w[15:8];
            if (dbus_sel[2]) dmem[dbus_adr[11:0] + 2] <= dbus_dat_w[23:16];
            if (dbus_sel[3]) dmem[dbus_adr[11:0] + 3] <= dbus_dat_w[31:24];
        end
    end

    // Clock (same as original)
    initial begin
        CLK = 0;
        forever #4 CLK = ~CLK;
    end

    // =========================================================================
    // Test Stimulus — LIF NEURON (same as original CPU_tb.v)
    // =========================================================================
    initial begin
        RESET = 1;
        #5 RESET = 0;

        #500000;  // Same time as original CPU_tb.v — should be enough now!

        // Print results — matching original CPU_tb.v format
        $display("\n╔══════════════════════════════════════════════════════════════╗");
        $display("║  CPU_wb — SINGLE LIF NEURON — WISHBONE VERIFICATION        ║");
        $display("╚══════════════════════════════════════════════════════════════╝");
        
        $display("\n--- Neuron Configuration ---");
        $display("  Input Current : 10 | Decay : 2 | Threshold : 30");
        
        $display("\n--- Execution Status ---");
        $display("  DEBUG (0x200): 0x%h%h%h%h", 
            dmem[515], dmem[514], dmem[513], dmem[512]);
        $display("  [0x1111=Start | 0xAAAA=Done]");
        
        $display("\n--- Membrane Potential Trace (0x100) ---");
        $display("  t=0: v_mem = %0d  (Expected: 0  - Initial State)", 
            $signed({dmem[259], dmem[258], dmem[257], dmem[256]}));
        $display("  t=1: v_mem = %0d  (Expected: 8  - Integrate +10, Decay -2)", 
            $signed({dmem[263], dmem[262], dmem[261], dmem[260]}));
        $display("  t=2: v_mem = %0d  (Expected: 16 - Integrate +10, Decay -2)", 
            $signed({dmem[267], dmem[266], dmem[265], dmem[264]}));
        $display("  t=3: v_mem = %0d  (Expected: 24 - Integrate +10, Decay -2)", 
            $signed({dmem[271], dmem[270], dmem[269], dmem[268]}));
        $display("  t=4: v_mem = %0d  (Expected: 0  - SPIKE! Reset to 0)", 
            $signed({dmem[275], dmem[274], dmem[273], dmem[272]}));

        $display("\n--- Spike Output (0x1B0) ---");
        $display("  Last RESULT: 0x%h%h%h%h  (0x0000FFFF=Spike fired, 0x00000000=No spike)", 
            dmem[435], dmem[434], dmem[433], dmem[432]);

        $display("\n══════════════════════════════════════════════════════════════\n");
        
        $finish;
    end

    // Waveform
    initial begin
        $dumpfile("cpu_wb_test.vcd");
        $dumpvars(0, CPU_wb_tb);
    end

endmodule
