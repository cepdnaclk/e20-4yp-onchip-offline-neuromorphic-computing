# SNN Backprop - Instruction Reference

## Overview

The `snn_backprop()` C function translates to a sequence of custom RISC-V instructions that execute the entire backpropagation process.

---

## Instruction Set

### 1. LIFOPUSH - Push Data to LIFO Buffers

**Purpose:** Load spike pattern or gradient data into LIFO buffers  
**Encoding:** Custom opcode 0001011 | funct3=000

```
| 31-25 | 24-20 | 19-15 | 14-12 | 11-7 | 6-0    |
|-------|-------|-------|-------|------|--------|
| 0000  | rs2   | rs1   | 000   | 0000 | 0001011|
```

**Semantics:**
- rs1 data (32 bits) → spike LIFO OR gradient LIFO (depending on context)
- rs2 unused (usually x0)
- Latency: 1 cycle

**Example Assembly:**
```assembly
addi x3, x0, 0xB0F5    # Load spike pattern into x3
LIFOPUSH x3, x0        # Push to spike LIFO
```

**Encoding:**
```
.word 0x0000003b  # 0001011 | 000xx | 00011 | 000 | 00000 | 0001011
```

---

### 2. LIFOPOP - Start Streaming + Load Weight/Error + Enable

**Purpose:** Initiate gradient streaming from LIFO and enable backprop computation  
**Encoding:** Custom opcode 0001011 | funct3=001

```
| 31-25 | 24-20 | 19-15 | 14-12 | 11-7 | 6-0    |
|-------|-------|-------|-------|------|--------|
| 0000  | rs2   | rs1   | 001   | 0000 | 0001011|
```

**Semantics:**
- rs1 holds initial weight (loaded into hardware weight register)
- rs2 holds error term (loaded into hardware error register)
- Automatically: starts gradient streaming, enables computation
- Latency: 17 cycles (16 streaming + 1 final update)

**Example Assembly:**
```assembly
addi x5, x0, 20        # Initial weight
addi x4, x0, -512      # Error term
LIFOPOP x5, x4         # Load and start computation
```

**Encoding:**
```
.word 0x0008903b  # rd=0, funct3=001, rs1=5, rs2=4
```

---

### 3. LIFOPUSHMG - Load Gradients from Memory

**Purpose:** Stream 16 gradient values from memory directly to gradient LIFO  
**Encoding:** Custom opcode 0001011 | funct3=101

```
| 31-25 | 24-20 | 19-15 | 14-12 | 11-7 | 6-0    |
|-------|-------|-------|-------|------|--------|
| 0000  | rs2   | rs1   | 101   | 0000 | 0001011|
```

**Semantics:**
- rs1: base memory address for gradient data
- rs2[4:0]: count (typically 16 for 16 gradients)
- FSM controller loads data directly from memory (bypasses register file)
- Latency: 62 cycles (includes ~50 cycles BUSYWAIT + ~12 cycles streaming)

**Example Assembly:**
```assembly
addi x1, x0, 0x20000000    # Memory base address
addi x2, x0, 16             # Gradient count
LIFOPUSHMG x1, x2           # Load from memory
```

**Encoding:**
```
.word 0x0000A03b  # rd=0, funct3=101, rs1=1, rs2=2
```

---

### 4. LIFOWB - Write Computed Weight to Register

**Purpose:** Write the computed weight from the custom unit to destination register  
**Encoding:** Custom opcode 0001011 | funct3=110

```
| 31-25 | 24-20 | 19-15 | 14-12 | 11-7 | 6-0    |
|-------|-------|-------|-------|------|--------|
| 0000  | 00000 | 00000 | 110   | rd   | 0001011|
```

**Semantics:**
- Destination register (rd) receives updated weight from custom unit
- rs1 and rs2 ignored (usually 0)
- Goes through memory stage pipeline
- Latency: 4 cycles (through MEM stage + WB stage)

**Example Assembly:**
```assembly
LIFOWB x6    # Write updated weight to x6
```

**Encoding:**
```
.word 0x0000303b  # rd=6, funct3=110, rs1=0, rs2=0
```

---

## Complete Instruction Sequence

### Timeline

```
Cycle 0-4:   Register setup
  addi x1, x0, 0x20000000   # Gradient memory address
  addi x2, x0, 16            # Gradient count
  addi x3, x0, 0xB0F5        # Spike pattern
  addi x4, x0, -512          # Error term
  addi x5, x0, 20            # Initial weight

Cycle 5:     Spike loading
  LIFOPUSH x3, x0            # Push spike to LIFO (1 cycle)

Cycle 6-67:  Gradient loading
  LIFOPUSHMG x1, x2          # Load gradients from memory (62 cycles)
  [62 NOPs while FSM reads memory]

Cycle 68:    Start computation
  LIFOPOP x5, x4             # Load weight, error, enable computation

Cycle 69-85: Computation
  [17 cycles: temporal recurrence, spike gating, weight update]
  [Cycles 0-15: Stream gradients, compute temporal delta]
  [Cycle 16: Apply final weight update]
  [Cycle 17: Output result]

Cycle 86-89: Writeback
  LIFOWB x6                  # Write result to register (4 cycles through pipeline)

Cycle 90-94: Final settle
  [NOPs for pipeline to drain]

Total: ~95 cycles
```

---

## Register Allocation

| Register | Purpose | Bit Width | Value Range |
|----------|---------|-----------|-------------|
| x1 | Gradient memory base address | 32-bit | 0x00000000 - 0xFFFFFFFF |
| x2 | Gradient count | 5-bit (in rs2) | 1-31 (typically 16) |
| x3 | Spike pattern | 16-bit | 0x0000 - 0xFFFF |
| x4 | Error term | 16-bit | -32768 to 32767 |
| x5 | Initial weight | 16-bit | -32768 to 32767 |
| x6 | Updated weight output | 32-bit | -32768 to 32767 (saturated) |

---

## Hardware Operation

### Spike LIFO
```
Input:  x3[15:0] (16 bits)
Output: 1 bit per clock (serial)
Format: Parallel-to-serial converter
```

### Gradient LIFO
```
Input:  Memory stream (parallel load)
Output: 16 bits per clock (word-wise)
Format: Memory-to-LIFO FSM reads from memory address (x1)
```

### Custom Backprop Unit
```
Inputs:
  - spike_bit: 1 bit per cycle (from spike LIFO)
  - gradient: 16 bits (from gradient LIFO)
  - error_in: Initial 16-bit error
  - weight_in: Initial 16-bit weight

State machines:
  - Temporal delta accumulation (16 cycles)
  - Weight update application (1 cycle final)

Output:
  - updated_weight: 32 bits (16-bit sat)
```

---

## Control Signals

### Generated by Control Unit

```
PUSH = 1        # LIFOPUSH instruction
POP = 1         # LIFOPOP instruction
CUSTOM_ENABLE = 1
LOAD_NEW_WEIGHT = 1
MEM_TO_LIFO_START = 1    # LIFOPUSHMG instruction
CUSTOM_WRITEBACK = 1     # LIFOWB instruction
```

### Used by Pipeline

```
CUSTOM_WRITEBACK_IDOUT → CUSTOM_WRITEBACK_EXOUT → CUSTOM_WRITEBACK_MEMOUT
                         flows through EX_MEM and MEM_WB pipelines
```

---

## Computation Formula

### Temporal Delta

For each timestep t ∈ [0, 15]:
```
if spike[t] == 1:
    delta[t] = 0  (gated by spike)
else:
    delta[t] = (243/256) * delta[t-1] + grad[t]
    where 243/256 ≈ 0.95 (BETA in Q8 format)
```

### Weight Update

After 17 cycles:
```
weight_updated = weight_initial - (150/256) * delta_final
where 150/256 ≈ 0.586 (learning rate in Q8 format)
Saturated to int16 range: [-32768, 32767]
```

---

## Example Encoding

For the test case `weight=20, spike=0xB0F5, error=-512`:

```assembly
# Setup
addi x1, x0, 0x20000000    # 0x20000013 (base address)
addi x2, x0, 16            # 0x01000113 (gradient count)
addi x3, x0, 0xB0F5        # 0xB0F0A193 (spike pattern)
addi x4, x0, -512          # 0xFE000213 (error: -512)
addi x5, x0, 20            # 0x01400293 (weight: 20)

# Streaming instructions
.word 0x0000003b           # LIFOPUSH x3, x0
.word 0x0000A03b           # LIFOPUSHMG x1, x2

# Computation
.word 0x0008903b           # LIFOPOP x5, x4

# Writeback
.word 0x0000303b           # LIFOWB x6
```

**Expected result in x6:** 398 (decimal)

---

## Debugging Tips

1. **Check LIFOPUSH works**: Monitor spike LIFO contents
2. **Check LIFOPUSHMG works**: Monitor memory accesses, gradient LIFO fill
3. **Check LIFOPOP works**: Monitor custom unit activation
4. **Check LIFOWB works**: Monitor x6 register for final value

Use waveform viewer:
```bash
gtkwave cpu_mem_loader.vcd
```

---

## Performance Metrics

| Metric | Value |
|--------|-------|
| Instructions | 10 (5 ADDI + 4 custom + 1 data flow |
| Latency | 95 cycles |
| Throughput | 1 update per 95 cycles |
| IPC (Instructions/Cycle) | 0.105 |
| Memory access | 1 burst of 16×16-bit = 256 bits |

---

## See Also

- `SNN_BACKPROP_USAGE.md` - Usage guide
- `QUICK_REFERENCE.md` - One-line examples
- `training_example.c` - Complete training code
- `CPU_tb_mem_loader.v` - Hardware testbench
