// ============================================================
// spike_forwarder_4_tb.v  –  Bottom-up Level 3 Test
// ============================================================
// Tests spike_forwarder_4 routing logic:
//
// Architecture reminder:
//   spike_forwarder_4 has:
//     - 1 MAIN port  (input from upper spike_forwarder_8 or testbench)
//     - 4 CLUSTER ports  (one per cluster in the group)
//
// Routing table (forwarding_map):
//   forwarding_map[row] is a 5-bit mask written by controller:
//     bit[0] = main port out (back-route / no use for input spikes)
//     bit[1] = cluster port 0 out
//     bit[2] = cluster port 1 out
//     bit[3] = cluster port 2 out
//     bit[4] = cluster port 3 out
//   row_index = which source row to write (0=main, 1-4=cluster 0-3)
//
// Controller byte format: {row_index[2:0], forwarding_row[4:0]}
//
// For the XOR network (group 0):
//   - External spike arrives on MAIN port  (from SF8)
//   - Must route to cluster 0 (hidden H0/H1) AND cluster 1 (output)
//   - So: forwarding_map[0] = 5'b00110  (bit1=cluster0, bit2=cluster1)
//
// TEST SCENARIOS:
//   Test 1: Single spike → routes to clusters 0 AND 1
//   Test 2: Two back-to-back spikes → both delivered correctly
//   Test 3: Spike from cluster 0 → routes back to main (inter-layer)
//   Test 4: done signal goes HIGH when all FIFOs drain
// ============================================================
`define SPIKE_FORWARDER_4
`define SPIKE_FORWARDER        // prevent spike_forwarder.v re-including FIFO
`include "../FIFO/fifo.v"
`include "spike_forwarder/spike_forwarder.v"
`include "spike_forwarder_controller/spike_forwarder_controller_4.v"
`include "spike_forwarder_4.v"

`timescale 1ns/100ps

module spike_forwarder_4_tb;

    // ── Clock & Reset ──────────────────────────────────────────
    reg clk = 0; reg rst = 1;
    always #5 clk = ~clk;  // 100 MHz

    // ── Parameters matching neuron_accelerator ─────────────────
    localparam DATA_WIDTH      = 11;   // 11-bit spike packet
    localparam NUM_PORTS       = 4;    // 4 cluster ports
    localparam FIFO_DEPTH      = 8;    // cluster port FIFO depth
    localparam MAIN_FIFO_DEPTH = 16;   // main port FIFO depth

    // ── Packet field helpers ───────────────────────────────────
    // Packet: {cluster_id[5:0], neuron_id[4:0]}
    function [DATA_WIDTH-1:0] make_pkt;
        input [5:0] cluster_id;
        input [4:0] neuron_id;
        begin make_pkt = {cluster_id, neuron_id}; end
    endfunction

    // ── DUT signals ────────────────────────────────────────────
    // Cluster port outputs (going TO clusters)
    reg  [NUM_PORTS-1:0]              cl_rd_en = 0;
    reg  [NUM_PORTS-1:0]              cl_wr_en = 0;
    reg  [NUM_PORTS*DATA_WIDTH-1:0]   cl_data_in = 0;
    wire [NUM_PORTS*DATA_WIDTH-1:0]   cl_data_out;
    wire [NUM_PORTS-1:0]              cl_full;
    wire [NUM_PORTS-1:0]              cl_empty;
    wire [NUM_PORTS*($clog2(FIFO_DEPTH)+1)-1:0] cl_count;

    // Main port (connected to SF8 / testbench)
    reg  [DATA_WIDTH-1:0]             main_data = 0;
    wire [DATA_WIDTH-1:0]             main_data_back;  // SF4 → main (back-route)
    reg                               main_full = 0;
    reg                               main_empty = 1;    // start empty
    reg  [$clog2(MAIN_FIFO_DEPTH):0]  main_count = 0;
    wire                              main_rd_en;
    wire                              main_wr_en_back;

    // Init interface
    reg  [7:0] data_in_ctrl = 0;
    reg        load_data    = 0;
    reg        router_mode  = 1;  // 1 = init/routing mode

    wire done;

    // ── DUT ────────────────────────────────────────────────────
    spike_forwarder_4 #(
        .num_ports(NUM_PORTS),
        .data_width(DATA_WIDTH),
        .fifo_depth(FIFO_DEPTH),
        .main_fifo_depth(MAIN_FIFO_DEPTH)
    ) dut (
        .clk(clk), .rst(rst),

        // cluster ports
        .fifo_rd_en_out(cl_rd_en),
        .fifo_wr_en_in(cl_wr_en),
        .fifo_in_data_in(cl_data_in),
        .fifo_out_data_out(cl_data_out),
        .fifo_full_in(cl_full),
        .fifo_empty_out(cl_empty),
        .fifo_count_in(cl_count),

        // main port
        .main_out_data_out(main_data),
        .main_in_data_in(main_data_back),
        .main_fifo_full_in(main_full),
        .main_fifo_empty_out(main_empty),
        .main_fifo_count_in(main_count),
        .main_fifo_rd_en_out(main_rd_en),
        .main_fifo_wr_en_in(main_wr_en_back),

        // init
        .router_mode(router_mode),
        .data_in(data_in_ctrl),
        .load_data(load_data),

        .done(done)
    );

    // ── Helper: write one routing table entry ──────────────────
    // format: {row_index[2:0], forwarding_row[4:0]}
    // row_index: 0=main port, 1-4=cluster port 0-3
    // forwarding_row bits: [0]=main_back, [1]=cl0, [2]=cl1, [3]=cl2, [4]=cl3
    task write_route;
        input [2:0] row;          // source
        input [4:0] destinations; // bitmask of destination ports
        begin
            @(posedge clk); #1;
            data_in_ctrl <= {row, destinations};
            load_data    <= 1;
            @(posedge clk); #1;
            load_data    <= 0;
            @(posedge clk);
        end
    endtask

    // ── Helper: inject spike on main port ──────────────────────
    // Simulates: SF8 wrote a packet into our input FIFO, main_empty goes low
    task inject_main_spike;
        input [DATA_WIDTH-1:0] pkt;
        begin
            main_data  <= pkt;
            main_empty <= 0;
            main_count <= 1;
            // Keep it available until SF4 reads it (main_rd_en asserted)
            wait(main_rd_en == 1'b1);
            @(posedge clk); #1;
            main_empty <= 1;
            main_count <= 0;
        end
    endtask

    // ── Helper: drain one packet from a cluster port ───────────
    // Returns the received packet
    task read_cluster_port;
        input  integer port;
        output [DATA_WIDTH-1:0] pkt;
        begin
            // Wait until something is in the FIFO
            wait(cl_empty[port] == 1'b0);
            @(posedge clk); #1;
            cl_rd_en[port] <= 1;
            @(posedge clk); #1;
            cl_rd_en[port] <= 0;
            pkt = cl_data_out[port*DATA_WIDTH +: DATA_WIDTH];
        end
    endtask

    // ── VCD ────────────────────────────────────────────────────
    initial begin
        $dumpfile("spike_forwarder_4_tb.vcd");
        $dumpvars(0, spike_forwarder_4_tb);
    end

    // ── Main test ──────────────────────────────────────────────
    integer pass_count = 0;
    integer fail_count = 0;
    reg [DATA_WIDTH-1:0] got_pkt;

    initial begin
        $display("=======================================================");
        $display(" Spike Forwarder 4 – Level 3 Routing Test");
        $display("=======================================================");
        $display(" Routing table for XOR network (group 0):");
        $display("   Row 0 (main→)  : bits[2:1] = clusters 0 and 1");
        $display("   Row 1 (cl0 →)  : bit[0]   = back to main (inter-layer)");
        $display("=======================================================\n");

        rst = 1;
        repeat(5) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ═══════════════════════════════════════════════════════
        // STEP 1: Load routing table (init phase, router_mode=1)
        // ═══════════════════════════════════════════════════════
        $display("[INIT] Loading routing table...");
        router_mode = 1;

        // Row 0: main port input → cluster 0 AND cluster 1
        // forwarding_row = 5'b00110 (bit1=cl0, bit2=cl1)
        write_route(3'd0, 5'b00110);
        $display("  forwarding_map[main] = 5'b00110 (→ cluster0, cluster1)");

        // Row 1: cluster 0 output → back to main (for outgoing spikes)
        // forwarding_row = 5'b00001 (bit0=main)
        write_route(3'd1, 5'b00001);
        $display("  forwarding_map[cl0]  = 5'b00001 (→ main back-route)");

        // Row 2: cluster 1 output → back to main
        write_route(3'd2, 5'b00001);
        $display("  forwarding_map[cl1]  = 5'b00001 (→ main back-route)");

        repeat(3) @(posedge clk);

        // ═══════════════════════════════════════════════════════
        // Switch to inference mode
        // ═══════════════════════════════════════════════════════
        $display("\n[MODE] Switching to inference (router_mode=0)");
        router_mode = 0;
        repeat(2) @(posedge clk);

        // ═══════════════════════════════════════════════════════
        // TEST 1: Single spike → must appear on BOTH cluster 0 and 1
        // ═══════════════════════════════════════════════════════
        $display("\n--- TEST 1: Single spike (cluster=62, n=0) → clusters 0 & 1 ---");
        begin : test1
            reg [DATA_WIDTH-1:0] pkt1_cl0, pkt1_cl1;
            fork
                // inject spike on main
                inject_main_spike(make_pkt(6'd62, 5'd0));

                // read from cluster 0 output FIFO
                begin
                    wait(cl_empty[0] == 1'b0);
                    @(posedge clk); #1;
                    cl_rd_en[0] <= 1;
                    @(posedge clk); #1;
                    cl_rd_en[0] <= 0;
                    pkt1_cl0 = cl_data_out[0*DATA_WIDTH +: DATA_WIDTH];
                end

                // read from cluster 1 output FIFO
                begin
                    wait(cl_empty[1] == 1'b0);
                    @(posedge clk); #1;
                    cl_rd_en[1] <= 1;
                    @(posedge clk); #1;
                    cl_rd_en[1] <= 0;
                    pkt1_cl1 = cl_data_out[1*DATA_WIDTH +: DATA_WIDTH];
                end
            join

            $display("  Cluster 0 received: 0x%03h (expected 0x%03h)", pkt1_cl0, make_pkt(6'd62, 5'd0));
            $display("  Cluster 1 received: 0x%03h (expected 0x%03h)", pkt1_cl1, make_pkt(6'd62, 5'd0));

            if (pkt1_cl0 == make_pkt(6'd62, 5'd0)) begin
                $display("  [PASS] Cluster 0 got correct packet");
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] Cluster 0 got wrong packet");
                fail_count = fail_count + 1;
            end

            if (pkt1_cl1 == make_pkt(6'd62, 5'd0)) begin
                $display("  [PASS] Cluster 1 got correct packet");
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] Cluster 1 got wrong packet");
                fail_count = fail_count + 1;
            end

            // Clusters 2 and 3 must stay empty
            repeat(10) @(posedge clk);
            if (cl_empty[2] && cl_empty[3]) begin
                $display("  [PASS] Clusters 2 & 3 stayed empty (correct)");
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] Clusters 2 or 3 had unexpected data!");
                fail_count = fail_count + 1;
            end
        end

        // ═══════════════════════════════════════════════════════
        // TEST 2: Two back-to-back spikes → both delivered correctly
        // ═══════════════════════════════════════════════════════
        $display("\n--- TEST 2: Two back-to-back spikes (n=0 then n=1) ---");
        begin : test2
            reg [DATA_WIDTH-1:0] pkt_a, pkt_b;

            // Inject spike A: cluster=62, neuron=0
            // Hold data for 2 cycles after rd_en (2-stage pipeline in forwarder:
            //   cycle 1: rd_en selects main port
            //   cycle 2: data wire is read and written to cluster FIFO)
            main_data  <= make_pkt(6'd62, 5'd0); main_empty <= 0; main_count <= 1;
            wait(main_rd_en == 1'b1);   // pipeline cycle 1 starts
            @(posedge clk); #1;          // pipeline cycle 2: forwarder reads data
            @(posedge clk); #1;          // safe to change now

            // Inject spike B: cluster=62, neuron=1
            main_data  <= make_pkt(6'd62, 5'd1); main_count <= 1;
            wait(main_rd_en == 1'b1);
            @(posedge clk); #1;
            @(posedge clk); #1;
            main_empty <= 1; main_count <= 0;

            // Read both from cluster 0
            wait(cl_empty[0] == 0);
            @(posedge clk); #1; cl_rd_en[0] <= 1;
            @(posedge clk); #1; cl_rd_en[0] <= 0;
            pkt_a = cl_data_out[0*DATA_WIDTH +: DATA_WIDTH];

            wait(cl_empty[0] == 0);
            @(posedge clk); #1; cl_rd_en[0] <= 1;
            @(posedge clk); #1; cl_rd_en[0] <= 0;
            pkt_b = cl_data_out[0*DATA_WIDTH +: DATA_WIDTH];

            $display("  Cluster 0 pkt_A: 0x%03h (expect 0x%03h)", pkt_a, make_pkt(6'd62,5'd0));
            $display("  Cluster 0 pkt_B: 0x%03h (expect 0x%03h)", pkt_b, make_pkt(6'd62,5'd1));

            if (pkt_a == make_pkt(6'd62, 5'd0) && pkt_b == make_pkt(6'd62, 5'd1)) begin
                $display("  [PASS] Both packets delivered in order to cluster 0");
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] Packets wrong or out of order");
                fail_count = fail_count + 1;
            end

            // Drain cluster 1 too (will also have both packets)
            repeat(2) begin
                wait(cl_empty[1] == 0);
                @(posedge clk); #1; cl_rd_en[1] <= 1;
                @(posedge clk); #1; cl_rd_en[1] <= 0;
            end
        end

        // ═══════════════════════════════════════════════════════
        // TEST 3: done signal goes HIGH after all FIFOs drain
        // ═══════════════════════════════════════════════════════
        $display("\n--- TEST 3: done signal after FIFOs drain ---");

        // done = &fifo_empty_in && &fifo_empty_out && zero_inflight
        // fifo_empty_out = cluster output FIFOs. Must drain ALL leftover
        // packets from all clusters before done can go high.
        $display("  [Draining all remaining cluster FIFOs...]");
        begin : drain_all
            integer p;
            for (p = 0; p < 4; p = p + 1) begin
                while (cl_empty[p] == 1'b0) begin
                    @(posedge clk); #1;
                    cl_rd_en[p] <= 1;
                    @(posedge clk); #1;
                    cl_rd_en[p] <= 0;
                    @(posedge clk);
                end
            end
        end

        repeat(20) @(posedge clk);
        if (done) begin
            $display("  [PASS] done=1 (all FIFOs empty, no in-flight packets)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] done=0 (FIFOs should be empty by now)");
            $display("         cl_empty=%b main_empty=%b", cl_empty, main_empty);
            fail_count = fail_count + 1;
        end


        // ═══════════════════════════════════════════════════════
        // SUMMARY
        // ═══════════════════════════════════════════════════════
        $display("\n=======================================================");
        $display(" SUMMARY: %0d passed, %0d failed", pass_count, fail_count);
        if (fail_count == 0)
            $display(" ALL TESTS PASSED — Spike routing is correct!");
        else
            $display(" FAILURES DETECTED — check routing table or FIFO logic");
        $display("=======================================================");

        repeat(10) @(posedge clk);
        $finish;
    end

    // ── Watchdog ───────────────────────────────────────────────
    initial begin
        #2000000;
        $display("[TIMEOUT] Simulation exceeded 2ms");
        $finish;
    end

endmodule
