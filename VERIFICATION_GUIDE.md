# End-to-End Verification Guide: Testbench ↔ Software Training Alignment

**Goal:** Run inference testbench → dump hardware vmem/spikes → run software trainer → dump software vmem/spikes → compare.

Verify that hardware and software produce **identical spike timings** and **consistent vmem values** for the same input, ensuring full alignment of the all-LIF architecture.

---

## Part 1: Generate Testbench Snapshot (Inference Dump)

The neuron accelerator testbench simulates inference and dumps shared memory snapshots to `smem_snapshot.mem`.

### Prerequisites

Ensure Synopsys VCS is available and licensed, then build the testbench:
```bash
cd inference_accelarator/neuron_accelerator
vcs -full64 -sverilog -timescale=1ns/1ps -o simv_mnist \
  mnist_infertest_tb.v neuron_accelerator.v \
  ../FIFO/fifo.v ../initialization_router/init_router.v \
  ../initialization_router/init_routers_tb.v \
  ../initialization_router/self_data_mng.v \
  ../../shared_memory/snn_shared_memory_wb.v
```

### Run Inference (Single Sample)

```bash
# Dump sample 0 to smem_snapshot.mem
./simv_mnist +dump_sample=0 +input_count=1

# Check the dump was created
ls -la smem_snapshot.mem
file smem_snapshot.mem
```

This generates:
- **smem_snapshot.mem**: Hex dump of shared memory regions:
  - 0x9000: Input spikes (784 neurons → 25 words, 32-bit packed)
  - 0xA000: Hidden+output LUT indices (210 neurons → 210 words, 8-bit each, left-padded)
  - 0xB000: Hidden+output spike bits (210 neurons → 7 words, 32-bit packed)

### Read the Snapshot (Optional Debugging)

```bash
python3 ../../tools/read_smem_snapshot.py smem_snapshot.mem \
  --n-input 784 --n-hidden 200 --n-output 10 --timesteps 16
```

Output shows:
```
Snapshot file header:
  Memory regions: 0x9000 (input spikes), 0xA000 (LUT indices), 0xB000 (output+hidden spikes)

Input spikes (0x9000, 25 words, packed bits):
  ts=0: inp_0=1, inp_1=0, inp_2=1, ...

Hidden LUT indices (0xA000, 200 bytes):
  ts=0: h0_idx=150(v~-106), h1_idx=128(v~0), ...

Output LUT indices (0xA000+200*4, 10 bytes):
  ts=0: o0_idx=128(v~0), ...

Output+hidden spikes (0xB000, 7 words, packed bits):
  ts=0: o0=0, o1=0, ..., h0=1, h1=0, ...
```

---

## Part 2: Run Software Trainer (Software Dump)

The C trainers now include optional dump functionality gated by `-DDUMP_VMEM_SPIKES` compile flag.

### Option A: backpropD_hw.C (200-hidden, LIF24, raw-pixel Poisson)

```bash
cd RISC_V/c_program

# Compile WITH dump output
gcc -O2 -Wall -DDUMP_VMEM_SPIKES -o backpropD_hw backpropD_hw.C -lm

# Prepare MNIST dataset (if not already present)
python3 ../../tools/prepare_mnist_data.py

# Run trainer (first sample only, for quick comparison)
head -c $((1 * (1 + 784))) mnist_full_train.bin | ./backpropD_hw

# OR: to compare 100 samples
head -c $((100 * (1 + 784))) mnist_full_train.bin | ./backpropD_hw
```

This generates: `software_vmem_spikes.csv` with columns:
```
sample,ts,inp_spk_0,inp_spk_1,...,inp_spk_783,h_spk_0,...,h_spk_199,o_spk_0,...,o_spk_9,
       h_lut_0,...,h_lut_199,o_lut_0,...,o_lut_9
```

**Output:**
```
Training with HARDWARE-MATCHED parameters:
  Architecture  : 784 → 200 → 10
  Decay mode    : LIF24  β=0.75  (BETA=192/256)
  ...
 >>> Dumped vmem/spikes to software_vmem_spikes.csv (100 samples) <<<
```

### Option B: backprop_pymatched.C (16-hidden, LIF2, normalized Poisson)

```bash
# Compile WITH dump output
gcc -O2 -Wall -DDUMP_VMEM_SPIKES -o backprop_pymatched backprop_pymatched.C -lm

# Run trainer (single sample for quick comparison)
head -c $((1 * (1 + 784))) mnist_full_train.bin | ./backprop_pymatched

# Output: software_vmem_spikes.csv with columns:
#   sample,ts,inp_spk_0..783,h_spk_0..15,o_spk_0..9,h_lut_0..15,o_lut_0..9
```

---

## Part 3: Compare Dumps (Alignment Verification)

### Run Comparison Tool

```bash
cd tools

# Compare testbench snapshot vs software dump (backpropD_hw: 200 hidden)
python3 compare_dumps.py ../inference_accelarator/neuron_accelerator/smem_snapshot.mem \
  software_vmem_spikes.csv --sample 0 --n-hidden 200 --n-output 10 --verbose

# OR for backprop_pymatched (16 hidden):
python3 compare_dumps.py ../inference_accelarator/neuron_accelerator/smem_snapshot.mem \
  software_vmem_spikes.csv --sample 0 --n-hidden 16 --n-output 10 --verbose
```

### Expected Output (PASS Case)

```
Loading testbench dump from inference_accelarator/neuron_accelerator/smem_snapshot.mem...
Loading software dump from software_vmem_spikes.csv...

Comparing dumps...

======================================================================
✓ ALL PASS (5/5 checks passed)
======================================================================
```

### If Comparison Fails

Check:
1. **Neuron count mismatch**: Ensure `backpropD_hw.C` matches testbench (200 hidden, 10 output)
2. **Timestep count**: Ensure both have TIMESTEPS=16
3. **Input encoding**: Check that both use same Poisson scheme (raw or normalized)
4. **Input data**: Testbench uses random/synthetic; software uses MNIST dataset samples

---

## Part 4: Detailed Alignment Checklist

Verify all 5 components match:

| Component          | Testbench (HW)           | Software (C)             | Expected Status |
|--------------------|--------------------------|--------------------------|-----------------|
| Input spikes       | 0x9000 region (packed)   | inp_spk_0..784 (CSV)     | ✓ Exact match   |
| Hidden spikes      | 0xB000 bits[10:209]      | h_spk_0..199 (CSV)       | ✓ Exact match   |
| Output spikes      | 0xB000 bits[0:9]         | o_spk_0..9 (CSV)         | ✓ Exact match   |
| Hidden LUT indices | 0xA000 words[0:199]      | h_lut_0..199 (CSV)       | ~ Close (±1)    |
| Output LUT indices | 0xA000 words[200:209]    | o_lut_0..9 (CSV)         | ✓ Exact match   |

**Notes:**
- LUT indices may differ ±1–2 due to Q16.16 (hardware) → float (C) → int conversion
- If **all spikes match**, vmem is consistent enough; LUT differences are acceptable
- Spikes must match **perfectly** for architecture validation

---

## Part 5: Quick Verification Workflow (Copy-Paste)

### Testbench Only (No Training)

```bash
# 1. Build testbench
cd inference_accelarator/neuron_accelerator
vcs -full64 -sverilog -timescale=1ns/1ps -o simv_mnist \
  mnist_infertest_tb.v neuron_accelerator.v \
  ../FIFO/fifo.v ../initialization_router/init_router.v \
  ../initialization_router/init_routers_tb.v ../initialization_router/self_data_mng.v \
  ../../shared_memory/snn_shared_memory_wb.v

# 2. Run inference dump
./simv_mnist +dump_sample=0 +input_count=1

# 3. Read snapshot
python3 ../../tools/read_smem_snapshot.py smem_snapshot.mem --timesteps 16
```

### Software Only (No Hardware)

```bash
# 1. Build C trainer
cd RISC_V/c_program
gcc -O2 -Wall -DDUMP_VMEM_SPIKES -o backpropD_hw backpropD_hw.C -lm

# 2. Prepare data
python3 ../../tools/prepare_mnist_data.py

# 3. Run inference simulation + dump
head -c $((1 * (1 + 784))) mnist_full_train.bin | ./backpropD_hw

# 4. Check output
head -5 software_vmem_spikes.csv
```

### Full End-to-End Comparison

```bash
# 1. Testbench dump
cd inference_accelarator/neuron_accelerator
./simv_mnist +dump_sample=0 +input_count=1

# 2. Software dump
cd ../../../RISC_V/c_program
head -c $((1 * (1 + 784))) mnist_full_train.bin | ./backpropD_hw

# 3. Compare
cd ../../tools
python3 compare_dumps.py ../inference_accelarator/neuron_accelerator/smem_snapshot.mem \
  software_vmem_spikes.csv --sample 0 --n-hidden 200 --verbose
```

---

## Part 6: Troubleshooting

| Issue                           | Check                                       | Fix                                       |
|--------------------------------|---------------------------------------------|-------------------------------------------|
| smem_snapshot.mem not found    | Testbench finished?                         | Rerun: `./simv_mnist +dump_sample=0 +input_count=1` |
| smem_snapshot.mem empty (0 bytes) | Dump FSM not triggered                   | Check `smem_cap` block in testbench fires  |
| software_vmem_spikes.csv blank/missing | Compiled without `-DDUMP_VMEM_SPIKES`? | Recompile: `gcc -DDUMP_VMEM_SPIKES ...` |
| software_vmem_spikes.csv has 0 rows | No samples processed                      | Check input data: `ls -lh mnist_full_train.bin` |
| Input spikes all 0 (both HW/SW) | Data not loaded                            | Regenerate: `python3 tools/generate_xor_test.py` |
| Spike mismatch: HW peaks but SW flat | Encoding mismatch (raw vs normalized)   | Ensure using same trainer version |
| LUT index off-by-many (>2)     | Vmem format mismatch                       | Check `mem_to_lut_idx()` rounding in compare_dumps.py |
| compare_dumps.py fails         | CSV parse error                            | Inspect first 10 rows: `head software_vmem_spikes.csv` |
| VCS compile fails              | VCS license / env not set                  | Verify `LM_LICENSE_FILE` and run `vcs -ID` |

---

## Files Reference

| File                            | Purpose                           | Created By      |
|---------------------------------|-----------------------------------|-----------------|
| inference_accelarator/neuron_accelerator/mnist_infertest_tb.v | Testbench, dumps shared memory to 0x9000/0xA000/0xB000 | Hardware team |
| inference_accelarator/neuron_accelerator/smem_snapshot.mem | Testbench output (hex dump)       | VCS `simv_mnist` |
| RISC_V/c_program/backpropD_hw.C | 200H trainer (LIF24) with optional dump | Session 11  |
| RISC_V/c_program/backprop_pymatched.C | 16H trainer (LIF2) with optional dump | Session 11   |
| software_vmem_spikes.csv        | Software trainer output (CSV)     | C trainer flag  |
| tools/compare_dumps.py          | Side-by-side comparison tool      | Session 11      |
| tools/read_smem_snapshot.py     | Human-readable snapshot display   | Session 10      |

---

## Summary

✅ **Architecture:** 784 input (LIF) → 200 hidden (LIF, or 16 for pymatched) → 10 output (LIF)
✅ **Testbench** outputs smem_snapshot.mem (3 memory regions: input spikes, LUT indices, output+hidden spikes)
✅ **Software trainers** output software_vmem_spikes.csv (per-sample, per-timestep spike/LUT history)
✅ **Comparison tool** aligns the two and reports match/mismatch for each of 5 components
✅ **Verification complete** when spikes match perfectly across both platforms

This enables **end-to-end validation of the all-LIF SNN architecture** in both hardware (inference) and software (training).
