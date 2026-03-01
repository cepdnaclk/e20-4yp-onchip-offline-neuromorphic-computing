// =============================================================================
//  snn_shared_memory_wb.v — Dual-Port Shared Memory (Wishbone Slave)
//  Project: On-Chip Offline Neuromorphic Computing (FYP)
// =============================================================================
//
//  Description:
//      Dual-port BRAM serving as the shared memory between the RISC-V CPU
//      and the neuromorphic inference accelerator.
//
//      Port A: Wishbone Classic Slave — connected to the SoC Wishbone bus.
//              The CPU uses this port to:
//              - Write initial weights (before inference)
//              - Read V_mem history (State 2: surrogate substitution)
//              - Write surrogate gradients back
//              - Read/write weights during learning (State 3)
//
//      Port B: Direct synchronous interface — connected straight to the
//              inference accelerator with no bus overhead.
//              The accelerator uses this port to:
//              - Read weights during forward pass
//              - Write V_mem values at each timestep
//              - Write spike states at each timestep
//
//  Memory Layout (default 192 KB for 784→200→10 SNN, T=8):
//      0x00000 - 0x274FF : Weights       (160,800 B)
//      0x28000 - 0x2BFE0 : V_mem history (15,904 B)
//      0x2C000 - 0x2DF10 : Spike history ( 7,952 B)
//      0x2F000 - 0x2FFFF : Control/Scratch (4 KB)
//
//  Conflict Policy:
//      The 3 SoC states are mutually exclusive — Port A and Port B never
//      write to the same address simultaneously. No hardware arbitration
//      is needed. An optional collision detect output is provided for
//      debug/verification.
//
//  Synthesis Notes:
//      - Coded using a standard dual-port RAM template that infers Block RAM
//        on Xilinx (Vivado), Intel (Quartus), and Lattice (Diamond/Radiant).
//      - No vendor-specific primitives used.
//      - Byte-enable writes on Port A are synthesized as byte-write-enable
//        BRAM on supported devices.
//
//  Parameters:
//      MEM_DEPTH  — number of 32-bit words (default: 49152 = 192 KB)
//      BASE_ADDR  — Wishbone base address (default: 0x2000_0000)
//      INIT_FILE  — optional hex file path for pre-loading weights
// =============================================================================

`timescale 1ns/100ps

module snn_shared_memory_wb #(
    parameter MEM_DEPTH  = 49152,                   // 192 KB (49152 × 32-bit words)
    parameter BASE_ADDR  = 32'h2000_0000,           // Wishbone base address
    parameter INIT_FILE  = "",                       // Optional: path to .hex init file
    parameter ADDR_WIDTH = $clog2(MEM_DEPTH)         // Auto-calculated (16 bits for 49152)
)(
    // ==================== Clock & Reset ====================
    input  wire        clk,
    input  wire        rst,

    // ==================== Port A: Wishbone Slave (CPU) ====================
    input  wire [31:0] wb_adr_i,    // Full 32-bit bus address
    input  wire [31:0] wb_dat_i,    // Write data from CPU
    output reg  [31:0] wb_dat_o,    // Read data to CPU
    input  wire  [3:0] wb_sel_i,    // Byte-select (SB=0001, SH=0011, SW=1111)
    input  wire        wb_we_i,     // Write enable
    input  wire        wb_stb_i,    // Strobe (transaction valid)
    input  wire        wb_cyc_i,    // Bus cycle active
    output reg         wb_ack_o,    // Acknowledge

    // ==================== Port B: Direct Accelerator Interface ====================
    input  wire [ADDR_WIDTH-1:0] portb_addr,    // Word address
    input  wire [31:0]           portb_din,     // Write data
    output reg  [31:0]           portb_dout,    // Read data
    input  wire                  portb_we,      // Write enable
    input  wire                  portb_en,      // Port enable

    // ==================== Debug ====================
    output wire                  collision_detect   // High when both ports write simultaneously
);

    // =========================================================================
    //  Address Decode
    // =========================================================================
    // The memory occupies a 256 KB window (2^18 bytes = 2^16 words).
    // Chip-select: compare upper bits of the bus address against BASE_ADDR.
    // Word address: extract bits [ADDR_WIDTH+1:2] from the byte address.
    // =========================================================================

    localparam WINDOW_BITS = ADDR_WIDTH + 2;    // 18 bits for byte address window

    wire        cs;                              // Chip select
    wire [ADDR_WIDTH-1:0] porta_addr;            // Word address for Port A

    assign cs = wb_cyc_i & wb_stb_i &
                (wb_adr_i[31:WINDOW_BITS] == BASE_ADDR[31:WINDOW_BITS]);

    assign porta_addr = wb_adr_i[WINDOW_BITS-1:2];  // Byte addr → word addr

    // =========================================================================
    //  Memory Array
    // =========================================================================
    // Declared as a 2D reg array. Synthesis tools infer this as Block RAM.
    // Using 4 separate byte arrays enables byte-write-enable BRAM inference
    // on Xilinx and Intel FPGAs.
    // =========================================================================

    reg [7:0] mem_byte0 [0:MEM_DEPTH-1];    // Bits [7:0]
    reg [7:0] mem_byte1 [0:MEM_DEPTH-1];    // Bits [15:8]
    reg [7:0] mem_byte2 [0:MEM_DEPTH-1];    // Bits [23:16]
    reg [7:0] mem_byte3 [0:MEM_DEPTH-1];    // Bits [31:24]

    // =========================================================================
    //  Optional Initialization
    // =========================================================================

    integer i;
    initial begin
        // Zero-initialize all memory
        for (i = 0; i < MEM_DEPTH; i = i + 1) begin
            mem_byte0[i] = 8'h00;
            mem_byte1[i] = 8'h00;
            mem_byte2[i] = 8'h00;
            mem_byte3[i] = 8'h00;
        end

        // Optionally load from hex file
        // Format: each line is one 32-bit word in hex (e.g., "DEADBEEF")
        // Usage: set INIT_FILE parameter to the file path
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem_byte0);
            // Note: For proper 4-byte init, a custom loading script
            // should split the hex file into per-byte arrays.
            // For simulation, a unified load is sufficient.
        end
    end

    // =========================================================================
    //  Port A: Wishbone Slave — CPU Access
    // =========================================================================
    //  Timing: Single-cycle ACK (registered read).
    //  - Write: wb_sel_i controls which bytes are written.
    //  - Read:  Full 32-bit word returned; CPU handles byte extraction.
    //
    //  ACK protocol: ACK is asserted for exactly 1 clock cycle per transaction.
    //  The !wb_ack_o guard prevents double-ACK on back-to-back cycles.
    // =========================================================================

    always @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            wb_dat_o <= 32'h0;
        end
        else if (cs && !wb_ack_o) begin
            // --- WRITE ---
            if (wb_we_i) begin
                if (wb_sel_i[0]) mem_byte0[porta_addr] <= wb_dat_i[7:0];
                if (wb_sel_i[1]) mem_byte1[porta_addr] <= wb_dat_i[15:8];
                if (wb_sel_i[2]) mem_byte2[porta_addr] <= wb_dat_i[23:16];
                if (wb_sel_i[3]) mem_byte3[porta_addr] <= wb_dat_i[31:24];
            end

            // --- READ (always return full word, even on writes for read-after-write) ---
            wb_dat_o <= {mem_byte3[porta_addr],
                         mem_byte2[porta_addr],
                         mem_byte1[porta_addr],
                         mem_byte0[porta_addr]};

            wb_ack_o <= 1'b1;
        end
        else begin
            wb_ack_o <= 1'b0;   // Deassert ACK after 1 cycle
        end
    end

    // =========================================================================
    //  Port B: Direct Accelerator Access
    // =========================================================================
    //  Timing: Single-cycle synchronous read/write.
    //  - Always operates on full 32-bit words (no byte select needed).
    //  - portb_en gates all access (set to 0 when accelerator is idle
    //    to reduce switching power).
    // =========================================================================

    always @(posedge clk) begin
        if (portb_en) begin
            if (portb_we) begin
                mem_byte0[portb_addr] <= portb_din[7:0];
                mem_byte1[portb_addr] <= portb_din[15:8];
                mem_byte2[portb_addr] <= portb_din[23:16];
                mem_byte3[portb_addr] <= portb_din[31:24];
            end

            portb_dout <= {mem_byte3[portb_addr],
                           mem_byte2[portb_addr],
                           mem_byte1[portb_addr],
                           mem_byte0[portb_addr]};
        end
    end

    // =========================================================================
    //  Collision Detection (Debug Only)
    // =========================================================================
    //  Asserts when both ports attempt to write simultaneously.
    //  Should NEVER happen during normal operation (states are exclusive).
    //  Use in simulation to catch integration bugs.
    // =========================================================================

    wire porta_writing = cs & wb_we_i & !wb_ack_o;
    wire portb_writing = portb_en & portb_we;

    assign collision_detect = porta_writing & portb_writing &
                              (porta_addr == portb_addr);

    // Simulation-only warning
    // synthesis translate_off
    always @(posedge clk) begin
        if (collision_detect) begin
            $display("WARNING [snn_shared_memory_wb @ %0t]: Write collision detected!", $time);
            $display("  Port A addr=0x%08h data=0x%08h", {wb_adr_i[31:2], 2'b00}, wb_dat_i);
            $display("  Port B addr=0x%04h data=0x%08h", portb_addr, portb_din);
        end
    end
    // synthesis translate_on

endmodule
