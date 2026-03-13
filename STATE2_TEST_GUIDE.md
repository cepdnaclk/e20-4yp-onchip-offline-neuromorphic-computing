# STATE 2 (Surrogate Substitution) Test — Step-by-Step Guide

## Overview

This guide walks you through testing **STATE 2** of your neuromorphic accelerator system. In STATE 2, the RISC-V CPU must:

1. **Read V_mem** (membrane potential) from the shared memory
2. **Query the Surrogate LUT** to get the pre-calculated gradient
3. **Write the result back** to shared memory

This is the core computational task that enables gradient-based learning without runtime surrogate computation.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    RISC-V CPU (rv32im)                       │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│   Task: Read V_mem → Query LUT → Write result back          │
│                                                               │
└──────┬──────────────────────────┬──────────────────────────┬─┘
       │                          │                          │
       │ Wishbone Bus (32-bit)    │                          │
       ↓                          ↓                          ↓
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  Shared Memory   │    │  Surrogate LUT   │    │   Other Periphs  │
│  (Port A: WB)    │    │  (Wishbone)      │    │                  │
│                  │    │                  │    │                  │
│  0x2000_0000 +   │    │  0xA000_0000 +   │    │                  │
│  Contains:       │    │  256×8-bit ROM   │    │                  │
│  - V_mem (R/W)   │    │  h(v) pre-calc   │    │                  │
│  - Spikes (R/W)  │    │                  │    │                  │
│  - Weights (R/W) │    │  Read: wb_adr    │    │                  │
│                  │    │  word = v_mem*4  │    │                  │
└──────────────────┘    └──────────────────┘    └──────────────────┘
```

---

## Step 1: Generate the LUT Hex File

The surrogate LUT values must be pre-calculated and loaded into the test.

```bash
cd /home/ravindu/FYP/e20-4yp-onchip-offline-neuromorphic-computing/surrogate_lut

# Run the Python script to generate surrogate_lut.hex
python3 gen_lut_for_test.py

# Verify output
head -20 surrogate_lut.hex
```

**Expected output (first 20 lines):**
```
ff      # Index 0,   v = 0,   h(0) = 1.0 → 0xFF
fc      # Index 1,   v = +1,  h = ~0.987 → 0xFC
fa      # Index 2,   v = +2,  h = ~0.948 → 0xFA
f5      # Index 3,   v = +3,  ...
f0      # Index 4,   v = +4,
eb      # Index 5,   v = +5,  h = ~0.921 → 0xEB
...
```

---

## Step 2: Understand the Test Scenario

The test (`test_state2_cpu_lut.v`) simulates this sequence:

### **Test Scenario:**
- Pre-load shared memory at address **0x28000** with V_mem value **0x00000005**
- CPU reads from 0x28000 → gets 0x00000005
- CPU calculates LUT address: **0xA000_0000 + (5 × 4) = 0xA000_0014**
- CPU reads from 0xA000_0014 → gets surrogate(5) = 0xEB (from LUT)
- CPU writes 0xEB back to shared memory at 0x28004
- Test verifies:
  - ✓ Initial read returns 0x00000005
  - ✓ LUT read at offset 0x14 returns 0xEB
  - ✓ Result correctly written to 0x28004

### **Why These Addresses?**

| Component | Base | Offset | Final Address | Content |
|-----------|------|--------|---------------|---------|
| Shared Memory | 0x2000_0000 | 0x28000 | 0x2002_8000 | V_mem values |
| Surrogate LUT | 0xA000_0000 | v_mem×4 | 0xA000_0014 | h(v_mem=5) |

---

## Step 3: Compile and Run the Test

### **Option A: Using Icarus Verilog (recommended)**

```bash
cd /home/ravindu/FYP/e20-4yp-onchip-offline-neuromorphic-computing/RISC_V/snn_tests

# Compile
iverilog -g2012 -Wno-timescale \
  -o test_state2_cpu_lut.vvp \
  ../../surrogate_lut/surrogate_lut_wb.v \
  ../../shared_memory/snn_shared_memory_wb.v \
  test_state2_cpu_lut.v

# Run
vvp -n test_state2_cpu_lut.vvp
```

**Expected output:**
```
[TEST 1] Pre-load shared memory at 0x28000 with V_mem=0x00000005
  [PASS] Test 1

[TEST 2] Read V_mem from 0x28000
  ✓ Read V_mem = 0x05 (expected 0x05)
  [PASS] Test 2

[TEST 3] Query surrogate LUT at address 0xA000_0014 (index 5)
  ✓ Read surrogate = 0xeb (expected 0xeb)
  [PASS] Test 3

[TEST 4] Write surrogate result back to 0x28004
  [PASS] Test 4

[TEST 5] Read back result from 0x28004 and verify
  ✓ Surrogate value correctly written: 0xeb
  [PASS] Test 5

========================================
 SUMMARY: 5 passed, 0 failed
========================================
```

### **If Tests Fail — Debug Checklist:**

1. **Did surrogate_lut.hex get generated?**
   ```bash
   ls -la surrogate_lut.hex
   head -10 surrogate_lut.hex
   ```

2. **Are the peripherals instantiating without errors?**
   ```bash
   vvp -n test_state2_cpu_lut.vvp 2>&1 | grep -i "error\|warning\|undefined"
   ```

3. **Is the Wishbone bus working?**
   - Add `$monitor` statements to print `wb_adr`, `wb_dat_i`, `wb_ack`
   - Verify clock and reset timing

4. **Are the LUT values correct?**
   ```bash
   python3 -c "
   import math
   v = 5
   h = 1.0 / (1.0 + 4.0*(v/128.0)**2)**2
   print(f'h({v}) = {h:.4f}, as 8-bit = {int(h*255):02x}')
   "
   ```

---

## Step 4: Next — Integrate with Real RISC-V CPU

Once the testbench passes, you'll need to:

1. **Create a RISC-V assembly program** (`state2_program.s`) that:
   ```asm
   # Load V_mem from 0x28000
   li   x10, 0x28000
   lw   x11, 0(x10)        # x11 = V_mem value
   
   # Calculate LUT address: 0xA0000000 + (V_mem & 0xFF) * 4
   andi x12, x11, 0xFF     # x12 = V_mem & 0xFF (byte offset)
   slli x13, x12, 2        # x13 = V_mem * 4
   li   x14, 0xA0000000
   add  x14, x14, x13
   
   # Read LUT
   lw   x15, 0(x14)        # x15 = surrogate(V_mem)
   
   # Write result back
   li   x16, 0x28004
   sw   x15, 0(x16)
   ```

2. **Connect your CPU to the testbench** as a proper Wishbone master
3. **Run program** and capture results

---

## Step 5: Verification Checklist

After tests pass, verify these conditions:

- [ ] Shared memory reads return correct V_mem values
- [ ] LUT queries return values in range [0x00, 0xFF]
- [ ] LUT peak (0xFF) is at V_mem=0
- [ ] LUT values decrease symmetrically for positive/negative V_mem
- [ ] Write-back to shared memory completes without errors
- [ ] No X/Z values propagate on bus signals
- [ ] Wishbone ACK timing is correct (1-2 cycles per transaction)

---

## Understanding the Surrogate Function

```
h(v) = 1 / (1 + 4 * (v/128)^2)^2

Key Points:
  - h(0) = 1.0 (peak) → maps to 0xFF in 8-bit
  - h(±128) ≈ 0.06 (minimal) → maps to ~0x0F in 8-bit
  - Symmetric around v=0
  - Used in gradient descent: dL/dV_mem ≈ h(v) * upstream_gradient

Example values:
  v = 0:    h = 1.000 → 0xFF
  v = ±5:   h = 0.921 → 0xEB
  v = ±10:  h = 0.852 → 0xDA
  v = ±50:  h = 0.269 → 0x44
  v = ±127: h = 0.002 → 0x00
```

---

## Files Involved

| File | Purpose | Status |
|------|---------|--------|
| `test_state2_cpu_lut.v` | Main testbench | ✏️ Create |
| `gen_lut_for_test.py` | Generate hex values | ✏️ Create |
| `surrogate_lut_wb.v` | LUT Wishbone slave | ✅ Exists |
| `snn_shared_memory_wb.v` | Shared memory | ✅ Exists |
| `surrogate_lut.hex` | Pre-calculated values | 🔄 To generate |

---

## Troubleshooting Common Issues

### **Issue: "Module not found: snn_shared_memory_wb"**
**Fix:** Check include paths. Add to iverilog command:
```bash
-I../../shared_memory \
-I../../surrogate_lut
```

### **Issue: "Wishbone ACK never asserts"**
**Fix:** Check `cs_mem` and `cs_lut` address decode. Print them:
```verilog
$monitor("@%t cs_mem=%b cs_lut=%b wb_ack=%b", $time, cs_mem, cs_lut, wb_ack);
```

### **Issue: "LUT returns 0x00 for all reads"**
**Fix:** Verify `surrogate_lut.hex` was loaded and addresses are correct.

### **Issue: "Shared memory never acknowledges"**
**Fix:** Ensure `wb_cyc` and `wb_stb` are asserted **before** the ACK is expected.

---

## Next Phase: RISC-V Integration

Once this testbench passes 5/5, you can:

1. Build a full SoC testbench with CPU as Wishbone master
2. Load the assembly program into CPU instruction memory
3. Run the CPU and have it execute STATE 2 operations
4. Capture waveforms for debugging

Would you like me to create the assembly program next?
