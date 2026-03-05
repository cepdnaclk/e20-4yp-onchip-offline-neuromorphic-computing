// ============================================================
// neuron_cluster_tb.v  – Bottom-up Level 2 Test (Complex)
// ============================================================
// Tests 4 neurons simultaneously with mixed fire / no-fire:
//   Neuron 0: weight=5.0  VT=3.0 → FIRES   (spike bit 0 = 1, V_mem = 0)
//   Neuron 1: weight=2.0  VT=3.0 → NO FIRE (spike bit 1 = 0, V_mem = 2.0 Q16.16)
//   Neuron 3: weight=8.0  VT=6.0 → FIRES   (spike bit 3 = 1, V_mem = 0)
//   Neuron 5: weight=1.5  VT=6.0 → NO FIRE (spike bit 5 = 0, V_mem = 1.5 Q16.16)
//
// Expected spikes_out_raw = 0b...00_0010_1001 (bits 0,3 set)
// ============================================================
`include "neuron_cluster.v"
`timescale 1ns/100ps

module neuron_cluster_tb;

    // ── Clock & Reset ──────────────────────────────────────────
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;   // 100 MHz

    // ── Cluster parameters ─────────────────────────────────────
    localparam NEURONS      = 32;
    localparam CLUSTER_ID   = 6'd0;
    localparam EXT_CLUSTER  = 6'd62;

    // ── Opcodes ────────────────────────────────────────────────
    localparam OPCODE_LOAD_NI      = 8'h01;
    localparam OPCODE_LOAD_IF_BASE = 8'h02;
    localparam OPCODE_LOAD_IF_ADDR = 8'h03;
    localparam DECAY_INIT    = 8'hFE;
    localparam ADDER_VT_INIT = 8'hF9;
    localparam WORK_MODE_CMD = 8'hF7;
    localparam END_PACKET    = 8'hFF;
    localparam LIF2_MODE     = 8'h01;

    // ── DUT signals ────────────────────────────────────────────
    reg  chip_mode    = 0;
    reg  time_step    = 0;
    reg  rst_potential= 0;
    reg  [10:0] packet_in = 11'h7FF;
    wire [10:0] packet_out;
    reg  fifo_empty   = 1;
    reg  fifo_full    = 0;
    wire fifo_rd_en, fifo_wr_en;
    wire cluster_done;
    reg  load_data = 0;
    reg  [7:0] data_byte = 0;
    reg  [32*NEURONS-1:0] weights_in = 0;
    reg  load_weight_in = 0;
    reg  [2:0] address_buffer_count = 0;
    wire [32*NEURONS-1:0] v_pre_spike_out; // pre-fire (all neurons retain their potential)
    wire [NEURONS-1:0]    spikes_out_raw;
    wire [$clog2(32)-1:0] weight_address_out;
    wire                  address_buffer_wr_en;

    // ── DUT ────────────────────────────────────────────────────
    neuron_cluster #(
        .packet_width(11),
        .cluster_id(CLUSTER_ID),
        .number_of_clusters(64),
        .neurons_per_cluster(NEURONS),
        .incoming_weight_table_rows(32),
        .max_weight_table_rows(32),
        .address_buffer_depth(8)
    ) dut (
        .clk(clk), .rst(rst),
        .time_step(time_step),
        .chip_mode(chip_mode),
        .rst_potential(rst_potential),
        .packet_in(packet_in),
        .packet_out(packet_out),
        .fifo_empty(fifo_empty),
        .fifo_full(fifo_full),
        .fifo_rd_en(fifo_rd_en),
        .fifo_wr_en(fifo_wr_en),
        .cluster_done(cluster_done),
        .v_pre_spike_out(v_pre_spike_out),  // pre-fire for backprop
        .spikes_out_raw(spikes_out_raw),
        .load_data(load_data),
        .data(data_byte),
        .weight_address_out(weight_address_out),
        .address_buffer_wr_en(address_buffer_wr_en),
        .weights_in(weights_in),
        .load_weight_in(load_weight_in),
        .address_buffer_count(address_buffer_count)
    );

    // ── Helper: send one byte ───────────────────────────────────
    task send_byte;
        input [7:0] b;
        begin
            @(posedge clk); #1;
            data_byte <= b;
            load_data <= 1;
            @(posedge clk); #1;
            load_data <= 0;
        end
    endtask

    // ── Helper: configure one neuron ────────────────────────────
    // vt_high = bits [23:16] of Q16.16 VT value
    // e.g. VT=3.0 → 0x00030000 → vt_high=0x03
    task configure_neuron;
        input [7:0] nid;
        input [7:0] vt_high;   // only needed for simple integer thresholds
        begin
            send_byte(OPCODE_LOAD_NI);
            send_byte(nid);
            send_byte(8'd14);   // flit_count = 14

            // DECAY: 0.0 (four zero bytes)
            send_byte(DECAY_INIT);
            send_byte(8'h00); send_byte(8'h00);
            send_byte(8'h00); send_byte(8'h00);
            send_byte(END_PACKET);

            // VT: 0x00_vt_high_0000 little-endian = [0x00, 0x00, vt_high, 0x00]
            send_byte(ADDER_VT_INIT);
            send_byte(8'h00); send_byte(8'h00);
            send_byte(vt_high); send_byte(8'h00);
            send_byte(END_PACKET);

            // WORK_MODE: LIF2
            send_byte(WORK_MODE_CMD);
            send_byte(LIF2_MODE);

            repeat(3) @(posedge clk);
        end
    endtask

    // ── VCD ────────────────────────────────────────────────────
    initial begin
        $dumpfile("neuron_cluster_tb.vcd");
        $dumpvars(0, neuron_cluster_tb);
    end

    // ── Test ───────────────────────────────────────────────────
    integer pass_count = 0;
    integer fail_count = 0;

    initial begin
        $display("=======================================================");
        $display(" Neuron Cluster Level 2 Test - Multi-Neuron");
        $display("=======================================================");
        $display(" N0: weight=5.0 VT=3.0 → FIRES   (spk[0]=1 vmem=0)");
        $display(" N1: weight=2.0 VT=3.0 → NO FIRE (spk[1]=0 vmem=2.0)");
        $display(" N3: weight=8.0 VT=6.0 → FIRES   (spk[3]=1 vmem=0)");
        $display(" N5: weight=1.5 VT=6.0 → NO FIRE (spk[5]=0 vmem=1.5)");
        $display("=======================================================\n");

        chip_mode = 1;
        rst = 1;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ── incoming_forwarder init ─────────────────────────────
        $display("[INIT] incoming_forwarder: base=0, register cluster 62");
        send_byte(OPCODE_LOAD_IF_BASE);
        send_byte(8'h00); send_byte(8'h00);
        repeat(2) @(posedge clk);
        send_byte(OPCODE_LOAD_IF_ADDR);
        send_byte(EXT_CLUSTER);
        repeat(2) @(posedge clk);

        // ── neuron configurations ───────────────────────────────
        $display("[INIT] Configuring neurons 0,1,3,5...");
        configure_neuron(8'h00, 8'h03);   // N0: VT=3.0
        configure_neuron(8'h01, 8'h03);   // N1: VT=3.0
        configure_neuron(8'h03, 8'h06);   // N3: VT=6.0
        configure_neuron(8'h05, 8'h06);   // N5: VT=6.0

        // ── switch to inference ─────────────────────────────────
        $display("[MODE] Switching to inference (chip_mode=0)");
        chip_mode = 0;
        repeat(2) @(posedge clk);

        // ── set weights directly on weights_in ─────────────────
        // weights_in[n*32 +: 32] = weight for neuron n (from src neuron 0)
        // Q16.16: 5.0=0x00050000, 2.0=0x00020000, 8.0=0x00080000, 1.5=0x00018000
        $display("[WEIGHT] Setting weights: N0=5.0  N1=2.0  N3=8.0  N5=1.5");
        weights_in = 0;
        weights_in[0*32 +: 32] = 32'h00050000;   // N0: 5.0 Q16.16
        weights_in[1*32 +: 32] = 32'h00020000;   // N1: 2.0 Q16.16
        weights_in[3*32 +: 32] = 32'h00080000;   // N3: 8.0 Q16.16
        weights_in[5*32 +: 32] = 32'h00018000;   // N5: 1.5 Q16.16

        // ── inject spike: cluster 62, neuron 0 ─────────────────
        $display("[SPIKE] Injecting spike: cluster=62, neuron=0");
        packet_in  = {EXT_CLUSTER, 5'd0};  // 0x7C0
        fifo_empty = 0;
        @(posedge fifo_rd_en);
        @(posedge clk); #1;
        fifo_empty = 1;
        packet_in  = 11'h7FF;

        // ── assert time_step ────────────────────────────────────
        $display("[TS] Asserting time_step");
        load_weight_in = 1;
        @(posedge clk); #1;
        time_step = 1;
        @(posedge clk); #1;
        time_step = 0;
        load_weight_in = 0;

        // ── wait for computation ────────────────────────────────
        $display("[WAIT] Waiting for cluster_done...");
        @(posedge cluster_done);
        repeat(2) @(posedge clk);

        // ── RESULTS ─────────────────────────────────────────────
        $display("\n=======================================================");
        $display(" RESULTS:");
        $display("-------------------------------------------------------");
        $display("  spikes_out_raw = %032b", spikes_out_raw);
        $display("  (expected)     = 00000000000000000000000000001001");
        $display("                   ← bit5=0 bit3=1 bit1=0 bit0=1");
        $display("-------------------------------------------------------");
        $display(" [PRE-FIRE v_pre_spike_out - for backprop surrogate gradient]");
        $display("   N0: 0x%08h (expect 0x00050000 = 5.0 Q16.16)", v_pre_spike_out[0*32 +: 32]);
        $display("   N1: 0x%08h (expect 0x00020000 = 2.0 Q16.16)", v_pre_spike_out[1*32 +: 32]);
        $display("   N3: 0x%08h (expect 0x00080000 = 8.0 Q16.16)", v_pre_spike_out[3*32 +: 32]);
        $display("   N5: 0x%08h (expect 0x00018000 = 1.5 Q16.16)", v_pre_spike_out[5*32 +: 32]);
        $display("-------------------------------------------------------");

        // Neuron 0: should fire
        if (spikes_out_raw[0] == 1'b1) begin
            $display("  N0 spike [PASS] bit0=1 (fired)"); pass_count = pass_count + 1;
        end else begin
            $display("  N0 spike [FAIL] bit0=0 (should fire)"); fail_count = fail_count + 1;
        end

        // Neuron 1: should NOT fire
        if (spikes_out_raw[1] == 1'b0) begin
            $display("  N1 spike [PASS] bit1=0 (no fire)"); pass_count = pass_count + 1;
        end else begin
            $display("  N1 spike [FAIL] bit1=1 (should not fire)"); fail_count = fail_count + 1;
        end

        // Neuron 3: should fire
        if (spikes_out_raw[3] == 1'b1) begin
            $display("  N3 spike [PASS] bit3=1 (fired)"); pass_count = pass_count + 1;
        end else begin
            $display("  N3 spike [FAIL] bit3=0 (should fire)"); fail_count = fail_count + 1;
        end

        // Neuron 5: should NOT fire
        if (spikes_out_raw[5] == 1'b0) begin
            $display("  N5 spike [PASS] bit5=0 (no fire)"); pass_count = pass_count + 1;
        end else begin
            $display("  N5 spike [FAIL] bit5=1 (should not fire)"); fail_count = fail_count + 1;
        end

        $display("--- Pre-fire V_mem checks (critical for backprop) ---");
        // N0: pre-fire should be 5.0 Q16.16 = 0x00050000
        if (v_pre_spike_out[0*32 +: 32] == 32'h00050000) begin
            $display("  N0 pre-fire [PASS] 0x%08h = 5.0 Q16.16", v_pre_spike_out[0*32+:32]);
            pass_count = pass_count + 1;
        end else begin
            $display("  N0 pre-fire [FAIL] got 0x%08h, expected 0x00050000", v_pre_spike_out[0*32+:32]);
            fail_count = fail_count + 1;
        end

        // N1: pre-fire should be 2.0 Q16.16 = 0x00020000
        if (v_pre_spike_out[1*32 +: 32] == 32'h00020000) begin
            $display("  N1 pre-fire [PASS] 0x%08h = 2.0 Q16.16", v_pre_spike_out[1*32+:32]);
            pass_count = pass_count + 1;
        end else begin
            $display("  N1 pre-fire [FAIL] got 0x%08h, expected 0x00020000", v_pre_spike_out[1*32+:32]);
            fail_count = fail_count + 1;
        end

        // N3: pre-fire should be 8.0 Q16.16 = 0x00080000
        if (v_pre_spike_out[3*32 +: 32] == 32'h00080000) begin
            $display("  N3 pre-fire [PASS] 0x%08h = 8.0 Q16.16", v_pre_spike_out[3*32+:32]);
            pass_count = pass_count + 1;
        end else begin
            $display("  N3 pre-fire [FAIL] got 0x%08h, expected 0x00080000", v_pre_spike_out[3*32+:32]);
            fail_count = fail_count + 1;
        end

        // N5: pre-fire should be 1.5 Q16.16 = 0x00018000
        if (v_pre_spike_out[5*32 +: 32] == 32'h00018000) begin
            $display("  N5 pre-fire [PASS] 0x%08h = 1.5 Q16.16", v_pre_spike_out[5*32+:32]);
            pass_count = pass_count + 1;
        end else begin
            $display("  N5 pre-fire [FAIL] got 0x%08h, expected 0x00018000", v_pre_spike_out[5*32+:32]);
            fail_count = fail_count + 1;
        end

        $display("-------------------------------------------------------");
        $display(" SUMMARY: %0d passed, %0d failed", pass_count, fail_count);
        $display("=======================================================");

        repeat(50) @(posedge clk);
        $finish;
    end

    // ── Watchdog ───────────────────────────────────────────────
    initial begin
        #1000000;
        $display("[TIMEOUT] Exceeded 1ms - deadlock?");
        $finish;
    end

endmodule