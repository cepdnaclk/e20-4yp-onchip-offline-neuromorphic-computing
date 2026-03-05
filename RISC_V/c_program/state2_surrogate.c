// =============================================================================
//  state2_surrogate.c — STATE 2: Surrogate Gradient Substitution
//  Project: On-Chip Offline Neuromorphic Computing (FYP)
// =============================================================================
//
//  PURPOSE:
//      After the accelerator dump FSM (STATE 1) writes V_mem (Q16.16) and
//      spike bits into snn_shared_memory_wb, this CPU firmware:
//
//        1. Reads each neuron's V_mem word from shared memory via Wishbone.
//        2. Extracts bits [23:16] as an 8-bit unsigned LUT index
//           (the integer part of Q16.16 is bits [31:16]; we take the lower
//            8 bits of that, i.e. bits [23:16], matching the LUT's signed
//            two's-complement 8-bit v encoding).
//        3. Queries the surrogate_lut_wb peripheral at:
//               lut_addr = SURROGATE_BASE + (lut_index * 4)
//        4. Reads the 8-bit surrogate gradient from bits [7:0] of the
//           LUT response word.
//        5. Writes the gradient (as a 32-bit word, zero-extended) back to
//           the same shared-memory location, overwriting the raw V_mem.
//
//  After this loop, the shared memory VMEM region contains surrogate
//  gradients ready for STATE 3 (weight update).
//
//  Memory Map (must match SoC integration):
//      SHARED_MEM_BASE  = 0x2000_0000   snn_shared_memory_wb Port A
//      SURROGATE_BASE   = 0xA000_0000   surrogate_lut_wb
//
//  Shared-memory layout (word addresses set by CPU before STATE 1):
//      VMEM_BASE  = 0x1000  (word offset; byte addr = SHARED_MEM_BASE + 0x4000)
//      SPIKE_BASE = 0x1100  (word offset; byte addr = SHARED_MEM_BASE + 0x4400)
//
//  Network parameters:
//      N_TOTAL    = total number of neurons across all clusters
//                   (must be configured to match the hardware instantiation)
//
//  LUT index encoding (matches surrogate_lut_wb.v):
//      Index  0..127  → v_mem =   0..+127  (positive or zero potential)
//      Index 128..255 → v_mem = -128..-1   (negative potential, two's complement)
//      This is exactly the raw uint8 reinterpretation of the signed 8-bit
//      integer part, which is what v[23:16] gives for Q16.16.
//
//  Compile (RV32IM, bare-metal):
//      riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O1 -nostdlib \
//          -T link.ld crt0.s state2_surrogate.c -o state2_surrogate.elf
//      riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 \
//          state2_surrogate.elf state2_surrogate.hex
//      riscv64-unknown-elf-objdump -d state2_surrogate.elf > state2_surrogate.dump
//
// =============================================================================

// ---------------------------------------------------------------------------
//  SoC Memory Map
// ---------------------------------------------------------------------------
#define SHARED_MEM_BASE   0x20000000u   // snn_shared_memory_wb Wishbone base
#define SURROGATE_BASE    0xA0000000u   // surrogate_lut_wb Wishbone base

// Shared-memory word offsets (must match vmem_base_addr / spike_base_addr
// inputs driven into neuron_accelerator before STATE 1 starts)
#define VMEM_WORD_OFFSET  0x1000u       // V_mem region starts at word 4096
#define SPIKE_WORD_OFFSET 0x1100u       // Spike region starts at word 4352

// Debug/status register (write-only, visible in simulation via $monitor)
#define DEBUG_REG         ((volatile unsigned int *)0x00000200u)

// ---------------------------------------------------------------------------
//  Network size — adjust to match hardware instantiation
//  Default: 4 clusters × 32 neurons = 128 total neurons
// ---------------------------------------------------------------------------
#define N_TOTAL           128

// ---------------------------------------------------------------------------
//  Derived byte addresses
// ---------------------------------------------------------------------------
// Byte address of word N in shared memory:
//   byte_addr = SHARED_MEM_BASE + (VMEM_WORD_OFFSET + N) * 4
#define VMEM_BYTE_BASE    (SHARED_MEM_BASE + (VMEM_WORD_OFFSET * 4u))

// Byte address for a surrogate LUT query with index I:
//   byte_addr = SURROGATE_BASE + I * 4
// (each LUT entry is one 32-bit word; gradient is in bits [7:0])

// ---------------------------------------------------------------------------
//  state2_surrogate_pass()
//
//  Iterates over all N_TOTAL neurons' V_mem entries in shared memory,
//  performs the LUT lookup, and writes the gradient back in-place.
//
//  Timing: 1 Wishbone read (V_mem) + 1 Wishbone read (LUT) +
//           1 Wishbone write (gradient) per neuron.
//          For N_TOTAL=128: 384 Wishbone transactions.
// ---------------------------------------------------------------------------
void state2_surrogate_pass(void)
{
    volatile unsigned int *vmem_region =
        (volatile unsigned int *)VMEM_BYTE_BASE;

    volatile unsigned int *lut_base =
        (volatile unsigned int *)SURROGATE_BASE;

    unsigned int i;

    *DEBUG_REG = 0xA200;   // STATE 2 start marker

    for (i = 0; i < N_TOTAL; i++) {

        // ── Step 1: Read V_mem (Q16.16) from shared memory ──────────────
        // Port A Wishbone single-cycle read.
        unsigned int vmem_word = vmem_region[i];

        // ── Step 2: Extract 8-bit LUT index from bits [23:16] ───────────
        // Q16.16 layout:  [31:16] = integer part,  [15:0] = fraction
        //                 [31:24] = upper integer byte (sign extension)
        //                 [23:16] = lower integer byte  ← LUT index
        //
        // Two's complement 8-bit: index 0=v0, 127=+127, 128=-128, 255=-1
        // This naturally encodes signed integers as unsigned LUT addresses.
        unsigned int lut_index = (vmem_word >> 16) & 0xFFu;

        // ── Step 3: Query surrogate LUT ──────────────────────────────────
        // The LUT is a 256-word ROM at SURROGATE_BASE.
        // Word-indexed: lut_base[lut_index] → 32-bit word, gradient in [7:0]
        unsigned int lut_word = lut_base[lut_index];

        // ── Step 4: Extract 8-bit gradient ──────────────────────────────
        unsigned int gradient = lut_word & 0xFFu;

        // ── Step 5: Write gradient back (overwrites V_mem in-place) ─────
        // Zero-extended to 32 bits. STATE 3 reads this as a uint8 gradient.
        vmem_region[i] = gradient;
    }

    *DEBUG_REG = 0xA2FF;   // STATE 2 done marker
}

// ---------------------------------------------------------------------------
//  main — called by crt0.s after stack init
//
//  In the real SoC this function is called by the scheduler/state-machine
//  driver after STATE 1 completes (dump_done interrupt or polled).
//  Here it runs as a standalone demo.
// ---------------------------------------------------------------------------
void main(void)
{
    *DEBUG_REG = 0xBEEF;   // Power-on marker

    // Run surrogate substitution pass
    state2_surrogate_pass();

    *DEBUG_REG = 0xD0AE;   // All done

    // Halt
    while (1)
        ;
}
