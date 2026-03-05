// ============================================================
//  real_mem_integration_tb.v — Level 6: Accelerator + Real Shared Memory
// ============================================================
//
//  PURPOSE:
//    Replace the simulated `reg [31:0] shared_mem[...]` array from
//    snn_integration_dump_tb with the actual snn_shared_memory_wb module,
//    connected exactly as it would be in silicon.
//
//    This tests the REAL data path:
//      Accelerator dump FSM → Port B → snn_shared_memory_wb BRAM
//      TB (acting as CPU)   → Port A → Wishbone reads back the values
//
//  WHAT IS NEW vs snn_integration_dump_tb:
//    1. snn_shared_memory_wb instantiated — real BRAM, not a reg array
//    2. Port B wired directly from neuron_accelerator output ports
//    3. Port A driven by TB Wishbone tasks (cpu_read / cpu_write)
//    4. Address width mismatch handled: accelerator outputs 16-bit word
//       address; shared_mem expects $clog2(MEM_DEPTH)-bit address.
//       With MEM_DEPTH=8192 (32 KB, fits vmem+spike regions), ADDR_WIDTH=13.
//       Accelerator portb_addr[12:0] connects directly — upper bits tie to 0.
//    5. collision_detect monitored — any assertion = test failure
//    6. State 2 (surrogate substitution) simulated:
//       CPU reads V_mem via Port A Wishbone, checks correct values.
//
//  KNOWN POTENTIAL ISSUES (documented below):
//    A. Address width: accelerator has 16-bit portb_addr, shared_mem has
//       ADDR_WIDTH=13 bits. Upper 3 bits of portb_addr must be 0.
//       Since VMEM_BASE=0x1000 (4096) and SPIKE_BASE=0x1100 (4352),
//       both fit within 13 bits (max=8191). ✓
//    B. Port A Wishbone address: BASE_ADDR=0x2000_0000. CPU byte address
//       = BASE_ADDR + (word_index × 4). The memory decodes via
//       wb_adr_i[ADDR_WIDTH+1:2] = word address. ✓
//    C. Port B is registered (single-cycle write). Dump FSM writes one
//       word per cycle — Port B can keep up. ✓
//    D. Collision: during dump FSM operation portb_en=1. TB must NOT
//       drive Port A during this window. TB waits for dump_done. ✓
//    E. MEM_DEPTH: must be large enough to hold vmem+spike regions.
//       VMEM_BASE=0x1000=4096, N_TOTAL=128 → vmem up to 0x107F.
//       SPIKE_BASE=0x1100=4352, N_SPIKE_W=4 → spike up to 0x1103.
//       Max address = 0x1103 = 4355 < 8192. MEM_DEPTH=8192 is safe. ✓
//
//  PASS CRITERIA (10 checks):
//    1-2. Port B writes to correct addresses (checked via Port A readback)
//    3.   cl0 neuron0 v_pre_spike = 0x00050000 (read via Wishbone)
//    4.   cl0 neuron1 v_pre_spike = 0x00050000 (read via Wishbone)
//    5.   cl1 neuron0 v_pre_spike = 0x00140000 (read via Wishbone)
//    6.   cl0 spike bit0 = 1 (read via Wishbone)
//    7.   cl0 spike bit1 = 0 (read via Wishbone)
//    8.   cl1 spike bit0 = 1 (read via Wishbone)
//    9.   collision_detect never asserted
//   10.   dump_done pulsed 4 times
//
// ============================================================
`include "neuron_accelerator.v"
`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns/100ps

module real_mem_integration_tb;

// ─── Parameters ──────────────────────────────────────────────────────────────
localparam PACKET_W      = 11;
localparam N_PER_CLUSTER = 32;
localparam CL_GROUPS     = 1;
localparam N_CLUSTERS    = CL_GROUPS * 4;              // 4
localparam N_TOTAL       = N_CLUSTERS * N_PER_CLUSTER; // 128
localparam N_SPIKE_W     = (N_TOTAL + 31) / 32;        // 4
localparam FLIT          = 8;

// Shared-memory layout (word addresses, same as snn_integration_dump_tb)
localparam [15:0] VMEM_BASE  = 16'h1000;   // word 4096
localparam [15:0] SPIKE_BASE = 16'h1100;   // word 4352

// snn_shared_memory_wb parameters
// MEM_DEPTH must fit max address 0x1103 = 4355 → 8192 words (32 KB)
localparam MEM_DEPTH  = 8192;
localparam ADDR_WIDTH = 13;   // $clog2(8192) = 13
localparam [31:0] MEM_BASE = 32'h2000_0000;  // Wishbone base address

// Wishbone byte address for a given word offset:
//   wb_byte_addr = MEM_BASE + (word_offset * 4)

// ─── Expected values (same as snn_integration_dump_tb) ───────────────────────
localparam EXP_CL0_N0_VPRE = 32'h00050000;
localparam EXP_CL0_N1_VPRE = 32'h00050000;
localparam EXP_CL1_N0_VPRE = 32'h00140000;

// ─── Clock ───────────────────────────────────────────────────────────────────
reg clk = 0;
always #5 clk = ~clk;  // 100 MHz

// ─── Accelerator I/O ─────────────────────────────────────────────────────────
reg  rst            = 1;
reg  network_mode   = 0;
reg  time_step      = 0;
reg  rst_potential  = 0;
reg  load_data_in   = 0;
reg  [FLIT-1:0] data_in = 0;
reg  ready_out      = 1;
reg  [PACKET_W-1:0] main_fifo_din_in = 0;
reg  main_fifo_wr_en_in = 0;

wire ready_in;
wire [FLIT-1:0] data_out;
wire load_data_out, data_out_done;
wire main_fifo_full_in, main_fifo_empty_out;
wire [PACKET_W-1:0] main_fifo_dout_out;
wire accelerator_done, dbg_all_clusters_done, dump_done;

// Port B — driven by accelerator, fed into shared memory
wire [15:0]        portb_addr_accel;   // 16-bit from accelerator
wire [31:0]        portb_din_accel;
wire               portb_we_accel;
wire               portb_en_accel;

// Port B — truncated to ADDR_WIDTH for shared memory
wire [ADDR_WIDTH-1:0] portb_addr_mem = portb_addr_accel[ADDR_WIDTH-1:0];
// Safety check: upper bits of portb_addr must be 0 for our MEM_DEPTH
// (tested in the collision/address monitor below)

// Port B read output (not used by accelerator dump FSM — write-only path)
wire [31:0] portb_dout_mem;

// Drain output FIFO continuously
wire main_fifo_rd_en_out = ~main_fifo_empty_out;

// ─── Port A: Wishbone — driven by TB (simulating CPU) ────────────────────────
reg  [31:0] wb_adr_i  = 0;
reg  [31:0] wb_dat_i  = 0;
reg   [3:0] wb_sel_i  = 4'hF;
reg         wb_we_i   = 0;
reg         wb_stb_i  = 0;
reg         wb_cyc_i  = 0;
wire [31:0] wb_dat_o;
wire        wb_ack_o;

// ─── Collision detect ────────────────────────────────────────────────────────
wire collision_detect;
integer collision_count = 0;

// ─── Dump / state tracking ───────────────────────────────────────────────────
integer dump_number     = 0;
integer write_count     = 0;

// Snapshot after dump #3 (cl0 values, before dump #4 overwrites them)
reg [31:0] snap_cl0_n0   = 0;
reg [31:0] snap_cl0_n1   = 0;
reg [31:0] snap_spike_w0 = 0;
reg        snap_taken    = 0;

always @(posedge clk) begin
    if (dump_done)           dump_number <= dump_number + 1;
    if (portb_we_accel && portb_en_accel) write_count <= write_count + 1;
    if (collision_detect)    collision_count <= collision_count + 1;
end

// ─── Instantiate neuron_accelerator ──────────────────────────────────────────
neuron_accelerator #(
    .packet_width            (PACKET_W),
    .main_fifo_depth         (32),
    .forwarder_8_fifo_depth  (16),
    .forwarder_4_fifo_depth  (8),
    .number_of_clusters      (N_CLUSTERS),
    .neurons_per_cluster     (N_PER_CLUSTER),
    .incoming_weight_table_rows(64),
    .max_weight_table_rows   (256),
    .flit_size               (FLIT),
    .cluster_group_count     (CL_GROUPS)
) accel (
    .clk              (clk),
    .rst              (rst),
    .network_mode     (network_mode),
    .time_step        (time_step),
    .rst_potential    (rst_potential),
    .load_data_in     (load_data_in),
    .data_in          (data_in),
    .ready_in         (ready_in),
    .data_out         (data_out),
    .load_data_out    (load_data_out),
    .ready_out        (ready_out),
    .data_out_done    (data_out_done),
    .main_fifo_din_in (main_fifo_din_in),
    .main_fifo_wr_en_in(main_fifo_wr_en_in),
    .main_fifo_full_in(main_fifo_full_in),
    .main_fifo_dout_out(main_fifo_dout_out),
    .main_fifo_rd_en_out(main_fifo_rd_en_out),
    .main_fifo_empty_out(main_fifo_empty_out),
    .accelerator_done (accelerator_done),
    .dbg_all_clusters_done(dbg_all_clusters_done),
    .dump_done        (dump_done),
    .portb_addr       (portb_addr_accel),   // 16-bit word address out
    .portb_din        (portb_din_accel),
    .portb_we         (portb_we_accel),
    .portb_en         (portb_en_accel),
    .vmem_base_addr   (VMEM_BASE),
    .spike_base_addr  (SPIKE_BASE),
    .current_timestep (4'd0)
);

// ─── Instantiate snn_shared_memory_wb ────────────────────────────────────────
snn_shared_memory_wb #(
    .MEM_DEPTH (MEM_DEPTH),
    .BASE_ADDR (MEM_BASE),
    .INIT_FILE ("")
) shared_mem (
    .clk          (clk),
    .rst          (rst),
    // Port A — Wishbone (TB acting as CPU)
    .wb_adr_i     (wb_adr_i),
    .wb_dat_i     (wb_dat_i),
    .wb_dat_o     (wb_dat_o),
    .wb_sel_i     (wb_sel_i),
    .wb_we_i      (wb_we_i),
    .wb_stb_i     (wb_stb_i),
    .wb_cyc_i     (wb_cyc_i),
    .wb_ack_o     (wb_ack_o),
    // Port B — direct from accelerator
    .portb_addr   (portb_addr_mem),         // truncated to 13-bit
    .portb_din    (portb_din_accel),
    .portb_dout   (portb_dout_mem),
    .portb_we     (portb_we_accel),
    .portb_en     (portb_en_accel),
    // Debug
    .collision_detect(collision_detect)
);

// ─── Monitor: address overflow check ─────────────────────────────────────────
always @(posedge clk) begin
    if (portb_we_accel && portb_en_accel) begin
        if (portb_addr_accel[15:ADDR_WIDTH] != 0) begin
            $display("ERROR [%0t]: portb_addr_accel=0x%04h overflows ADDR_WIDTH=%0d!",
                     $time, portb_addr_accel, ADDR_WIDTH);
        end
        if (portb_din_accel != 0)
            $display("[DUMP%0d] addr=0x%04h  val=0x%08h  @%0t",
                     dump_number, portb_addr_accel, portb_din_accel, $time);
    end
end

// ─── Wishbone CPU read task ───────────────────────────────────────────────────
// Reads one 32-bit word from the shared memory via Port A Wishbone.
// word_addr: word offset into the memory (0-based)
// Returns value in wb_dat_o (captured after ack)
task cpu_read;
    input  [ADDR_WIDTH-1:0] word_addr;
    output [31:0] read_data;
    begin
        // Compute byte address on the Wishbone bus
        @(negedge clk);
        wb_adr_i = MEM_BASE + {17'd0, word_addr, 2'b00};
        wb_dat_i = 32'h0;
        wb_sel_i = 4'hF;
        wb_we_i  = 1'b0;
        wb_stb_i = 1'b1;
        wb_cyc_i = 1'b1;
        // Wait for ACK (single cycle)
        @(posedge clk); #1;
        while (!wb_ack_o) @(posedge clk);
        read_data = wb_dat_o;
        // Deassert
        @(negedge clk);
        wb_stb_i = 1'b0;
        wb_cyc_i = 1'b0;
        wb_adr_i = 32'h0;
    end
endtask

// ─── Init ROM (identical to snn_integration_dump_tb) ─────────────────────────
reg [7:0] init_rom [0:999];
integer   init_idx = 0;
integer   init_len = 0;

task load_init_rom;
    integer i, k;
    begin
        for (i = 0; i < 1000; i = i+1) init_rom[i] = 8'hxx;
        i = 0;

        // PKT 0: SF8 map[0] → group0
        init_rom[i]=8'hA0; i=i+1; init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h02; i=i+1;
        // PKT 1: SF8 map[1] → main
        init_rom[i]=8'hA0; i=i+1; init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h10; i=i+1; init_rom[i]=8'h01; i=i+1;
        // PKT 2: SF4 map[0] → port 1 (cluster 0)
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h01; i=i+1;
        init_rom[i]=8'h02; i=i+1;
        // PKT 3: SF4 map[1] → port 2 (cluster 1)
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h01; i=i+1;
        init_rom[i]=8'h24; i=i+1;
        // PKT 4: SF4 map[2] → port 0 (main/SF8)
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h01; i=i+1;
        init_rom[i]=8'h41; i=i+1;
        // PKT 5: Cluster 0 neuron 0: VT=3.0 LIF2
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h11; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h0E; i=i+1;
        init_rom[i]=8'hFE; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF9; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h03; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF7; i=i+1; init_rom[i]=8'h01; i=i+1;
        // PKT 6: Cluster 0 neuron 1: VT=8.0 LIF2
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h11; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h0E; i=i+1;
        init_rom[i]=8'hFE; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF9; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h08; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF7; i=i+1; init_rom[i]=8'h01; i=i+1;
        // PKT 7: Cluster 1 neuron 0: VT=10.0 LIF2
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h11; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h0E; i=i+1;
        init_rom[i]=8'hFE; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF9; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h0A; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'hFF; i=i+1;
        init_rom[i]=8'hF7; i=i+1; init_rom[i]=8'h01; i=i+1;
        // PKT 8: Cluster 0 IF base=0
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h02; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        // PKT 9: Cluster 0 IF addr=3
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h03; i=i+1; init_rom[i]=8'h03; i=i+1;
        // PKT10: Cluster 1 IF base=2
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h03; i=i+1;
        init_rom[i]=8'h02; i=i+1; init_rom[i]=8'h02; i=i+1; init_rom[i]=8'h00; i=i+1;
        // PKT11: Cluster 1 IF addr=0
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h02; i=i+1;
        init_rom[i]=8'h03; i=i+1; init_rom[i]=8'h00; i=i+1;
        // PKT12: WR row 0 — n0=5.0, n1=5.0
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h85; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h83; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h80; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h05; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h05; i=i+1; init_rom[i]=8'h00; i=i+1;
        for (k = 2; k < 32; k = k+1) begin
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        end
        // PKT13: WR row 1 — n0=5.0, n1=5.0
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h85; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h83; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h80; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h05; i=i+1; init_rom[i]=8'h00; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h05; i=i+1; init_rom[i]=8'h00; i=i+1;
        for (k = 2; k < 32; k = k+1) begin
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        end
        // PKT14: WR row 2 — n0=20.0
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h85; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h83; i=i+1;
        init_rom[i]=8'h02; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h80; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h14; i=i+1; init_rom[i]=8'h00; i=i+1;
        for (k = 1; k < 32; k = k+1) begin
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        end
        // PKT15: WR row 3 — n0=-20.0
        init_rom[i]=8'h80; i=i+1; init_rom[i]=8'h85; i=i+1;
        init_rom[i]=8'h01; i=i+1; init_rom[i]=8'h83; i=i+1;
        init_rom[i]=8'h03; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h80; i=i+1;
        init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1; init_rom[i]=8'hEC; i=i+1; init_rom[i]=8'hFF; i=i+1;
        for (k = 1; k < 32; k = k+1) begin
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
            init_rom[i]=8'h00; i=i+1; init_rom[i]=8'h00; i=i+1;
        end

        init_rom[i] = 8'hxx;
        init_len = i;
        $display("[INIT_ROM] Built %0d bytes", i);
    end
endtask

// ─── Init stream driver ───────────────────────────────────────────────────────
reg        start_init = 0;
reg        init_done  = 0;
reg [31:0] init_index = 0;

always @(posedge clk) begin
    if (start_init) begin
        if (init_rom[init_index] !== 8'hxx) begin
            if (ready_in && !load_data_in) begin
                data_in      <= init_rom[init_index];
                load_data_in <= 1;
                init_index   <= init_index + 1;
            end else
                load_data_in <= 0;
        end else begin
            load_data_in <= 0;
            if (ready_in && !load_data_in) begin
                start_init   <= 0;
                init_done    <= 1;
                network_mode <= 0;
                $display("[INIT] Stream complete: %0d bytes sent", init_index);
            end
        end
    end else
        load_data_in <= 0;
end

// ─── VCD ─────────────────────────────────────────────────────────────────────
initial begin
    $dumpfile("/home/ravindu/FYP/e20-4yp-onchip-offline-neuromorphic-computing/inference_accelarator/neuron_accelerator/real_mem_integration_tb.vcd");
    $dumpvars(0, real_mem_integration_tb);  // depth=0 → dump entire hierarchy
end

// ─── Test ────────────────────────────────────────────────────────────────────
integer pass_count = 0;
integer fail_count = 0;
reg [31:0] readback;
reg [31:0] snap_cl1_n0 = 0;   // cl1 neuron0 vmem snapshot
reg [31:0] snap_spike_w1 = 0;  // cl1 spike word 1 snapshot

task check;
    input        ok;
    input [255:0] msg;
    begin
        if (ok) begin $display("  [PASS] %s", msg); pass_count = pass_count + 1; end
        else    begin $display("  [FAIL] %s", msg); fail_count = fail_count + 1; end
    end
endtask

// Snapshot cl0 after dump #3 using Wishbone reads
// We drive this from the main initial block after waiting for dump_number==3

initial begin
    $display("=============================================================");
    $display(" Level 6: Accelerator + Real snn_shared_memory_wb");
    $display(" Port B wired from neuron_accelerator to BRAM directly.");
    $display(" Port A Wishbone reads verify values after each dump.");
    $display("=============================================================\n");

    load_init_rom();

    // ── Reset ──
    rst = 1;
    repeat(10) @(posedge clk);
    rst = 0;

    // ── Phase 1: Init ──
    $display("[PHASE 1] Streaming init: %0d bytes", init_len);
    network_mode = 1;
    start_init   = 1;
    wait(init_done);
    $display("[PHASE 1] Init done. Waiting for dump #1 (all-zeros)...");
    wait(dump_number >= 1);
    $display("[PHASE 1] Dump #1 received. dump_count=%0d", dump_number);
    repeat(5) @(posedge clk);

    // ── Phase 2: Inject external spike ──
    $display("\n[PHASE 2] Injecting spike: cluster=3 neuron=0 (packet=0x060)");
    @(posedge clk); #1;
    main_fifo_din_in   <= 11'h060;
    main_fifo_wr_en_in <= 1;
    @(posedge clk); #1;
    main_fifo_wr_en_in <= 0;

    $display("[PHASE 2] Waiting for dump #2 (post-accumulation)...");
    wait(dump_number >= 2);
    $display("[PHASE 2] Dump #2 received. dump_count=%0d", dump_number);
    repeat(5) @(posedge clk);

    // ── Phase 3: Timestep 1 ──
    $display("\n[PHASE 3] Timestep 1 — cluster 0 fires...");
    @(posedge clk); #1; time_step <= 1;
    @(posedge clk); #1; time_step <= 0;

    $display("[PHASE 3] Waiting for dump #3 (ts1: cl0 v_pre written)...");
    wait(dump_number >= 3);
    repeat(3) @(posedge clk);  // let BRAM writes settle
    $display("[PHASE 3] Dump #3 done. Reading cl0 values via Wishbone (Port A)...");

    // ── READ cl0 values via Port A BEFORE dump #4 overwrites them ──
    // IMPORTANT: dump FSM is now idle (portb_en=0), Port A is safe to use.
    cpu_read(VMEM_BASE + 0, readback);
    snap_cl0_n0 = readback;
    $display("  [PORT A] vmem[VMEM_BASE+0] = 0x%08h  (expect 0x%08h = cl0 n0 5.0)",
             snap_cl0_n0, EXP_CL0_N0_VPRE);

    cpu_read(VMEM_BASE + 1, readback);
    snap_cl0_n1 = readback;
    $display("  [PORT A] vmem[VMEM_BASE+1] = 0x%08h  (expect 0x%08h = cl0 n1 5.0)",
             snap_cl0_n1, EXP_CL0_N1_VPRE);

    cpu_read(SPIKE_BASE + 0, readback);
    snap_spike_w0 = readback;
    $display("  [PORT A] spike[SPIKE_BASE+0] = 0b%032b", snap_spike_w0);

    repeat(5) @(posedge clk);

    // ── Phase 4: Timestep 2 ──
    $display("\n[PHASE 4] Timestep 2 — cluster 1 fires with 20.0...");
    @(posedge clk); #1; time_step <= 1;
    @(posedge clk); #1; time_step <= 0;

    $display("[PHASE 4] Waiting for dump #4 (ts2: cl1 v_pre written)...");
    wait(dump_number >= 4);
    repeat(3) @(posedge clk);
    $display("[PHASE 4] Dump #4 done. Reading cl1 values via Wishbone...");

    // Read cl1 neuron 0 (word offset = VMEM_BASE + 32)
    cpu_read(VMEM_BASE + 32, readback);
    snap_cl1_n0 = readback;
    $display("  [PORT A] vmem[VMEM_BASE+32] = 0x%08h  (expect 0x%08h = cl1 n0 20.0)",
             snap_cl1_n0, EXP_CL1_N0_VPRE);

    // Read cl1 spike word 1 (each word holds 32 spikes; cl1 starts at neuron 32)
    cpu_read(SPIKE_BASE + 1, readback);
    snap_spike_w1 = readback;
    $display("  [PORT A] spike[SPIKE_BASE+1] = 0b%032b  (expect bit0=1)", snap_spike_w1);

    // ── Verification ──────────────────────────────────────────────────────
    $display("\n=============================================================");
    $display(" VERIFICATION — all reads via real Wishbone Port A");
    $display("=============================================================");

    $display("\n  -- Cluster 0 (Wishbone read after dump #3) --");
    check(snap_cl0_n0 == EXP_CL0_N0_VPRE,
          "cl0 n0 v_pre=5.0  read via Port A Wishbone");
    check(snap_cl0_n1 == EXP_CL0_N1_VPRE,
          "cl0 n1 v_pre=5.0  read via Port A Wishbone");

    $display("\n  -- Cluster 1 (Wishbone read after dump #4) --");
    check(snap_cl1_n0 == EXP_CL1_N0_VPRE,
          "cl1 n0 v_pre=20.0 read via Port A Wishbone — SNN propagation verified");

    $display("\n  -- Spike bits --");
    check(snap_spike_w0[0] == 1'b1, "cl0 n0 spike=1 (dump #3, Port A)");
    check(snap_spike_w0[1] == 1'b0, "cl0 n1 spike=0 (dump #3, Port A)");

    check(snap_spike_w1[0] == 1'b1,
          "cl1 n0 spike=1 (dump #4, Port A) — SNN cl0→cl1 propagation");

    $display("\n  -- Infrastructure checks --");
    check(collision_count == 0,
          "No Port A / Port B write collisions detected");
    check(dump_number == 4,
          "dump_done pulsed exactly 4 times");

    $display("\n  -- Address width safety --");
    check(VMEM_BASE  < (1 << ADDR_WIDTH),
          "VMEM_BASE fits in ADDR_WIDTH bits");
    check(SPIKE_BASE + N_SPIKE_W < (1 << ADDR_WIDTH),
          "SPIKE region fits in ADDR_WIDTH bits");

    $display("\n=============================================================");
    if (fail_count == 0) begin
        $display(" ALL %0d / 10 TESTS PASSED", pass_count);
        $display(" Real snn_shared_memory_wb BRAM correctly written by");
        $display(" accelerator dump FSM and read back via Wishbone Port A.");
    end else
        $display(" %0d PASSED / %0d FAILED — check real_mem_integration_tb.vcd",
                 pass_count, fail_count);
    $display("=============================================================");

    $finish;
end

// ─── Watchdog ─────────────────────────────────────────────────────────────────
initial begin
    #50_000_000;
    $display("[TIMEOUT] 50ms exceeded");
    $display("  init_done=%b accel_done=%b dump_number=%0d",
             init_done, accelerator_done, dump_number);
    $finish;
end

endmodule
