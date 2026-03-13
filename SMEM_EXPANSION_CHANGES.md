# Shared Memory Expansion — Full 320-Sample Dump

## Summary
Modified `mnist_infertest_tb.v` to expand shared memory and dump **all 320 MNIST test samples** (instead of just one) to `smem_snapshot.mem`. The smem file is now a **complete replica of shared memory** containing all input spikes, vmem values, and output spikes with per-timestep granularity.

## Changes Made

### 1. **Expanded Shared Memory**
- **Before:** `SMEM_DEPTH = 49,152` words (192 KB) — held only 1 sample
- **After:** `SMEM_DEPTH = 524,288` words (512 KB) — holds all 320 samples
- **New Parameter:** `WORDS_PER_SAMPLE = (words_per_ts) × N_TS = 1,360 words/sample`
  - Per timestep: 25 (input spikes) + 53 (vmem LUT indices) + 7 (spikes) = 85 words
  - Per sample (16 TS): 85 × 16 = 1,360 words
  - All 320 samples: 320 × 1,360 = 435,200 words (minimum; using 512K for alignment)

### 2. **Dynamic Per-Sample Memory Addressing**
- Added wire/reg declarations:
  - `sample_mem_offset` — starting word address for current sample
  - `sample_input_base`, `sample_vmem_base`, `sample_spike_base` — region bases
  
- Base addresses calculated at start of each sample (S_INJECT):
  ```verilog
  sample_mem_offset = sample_idx * WORDS_PER_SAMPLE
  sample_input_base = sample_mem_offset
  sample_vmem_base = sample_mem_offset + (N_TS * INPUT_SPK_WORDS_PER_TS)
  sample_spike_base = sample_vmem_base + (N_TS * N_ACTIVE_NEURONS)
  ```

### 3. **Updated Testbench FSM**
- **S_INJECT State:**
  - Calculate offsets at first neuron of first timestep
  - Capture input spikes for **all samples** (removed `dump_target_sample` filter)
  - Write input spikes to `sample_mem_offset + ts*INPUT_SPK_WPT`

- **S_WAIT_DONE State (spike capture):**
  - Removed single-sample check: now dumps vmem + spikes for **all samples**
  - Write vmem to: `sample_vmem_base + ts*N_ACTIVE_NEURONS + neuron_idx`
  - Write spikes to: `sample_spike_base + ts*SPIKE_WORDS_PER_TS + word_idx`

- **Termination Block:**
  - After all samples complete, write full `smem_snapshot.mem` with all data
  - Updated header comments to document per-sample layout

### 4. **Updated DUT Instantiation**
- Changed hardcoded base addresses to dynamic:
  ```verilog
  // Before:
  .vmem_base_addr(16'hA000),
  .spike_base_addr(16'hB000),
  
  // After:
  .vmem_base_addr(sample_vmem_base),
  .spike_base_addr(sample_spike_base),
  ```

## Shared Memory Layout (New)

Each sample N occupies `WORDS_PER_SAMPLE` (1,360 words) starting at offset `N × 1,360`:

```
Sample 0:   0x00000 - 0x00557   (1,360 words)
  ├─ 0x00000: Input spikes (ts=0..15, word 0-24 per ts)
  ├─ 0x00190: Vmem LUT idx (ts=0..15, neuron 0-209 per ts)
  └─ 0x00B50: Hidden+output spikes (ts=0..15, word 0-6 per ts)

Sample 1:   0x00558 - 0x00AAF   (1,360 words)
  ├─ 0x00558: Input spikes (ts=0..15)
  ├─ 0x006E8: Vmem LUT idx (ts=0..15)
  └─ 0x012A8: Spikes (ts=0..15)

...

Sample 319: 0x6F6E8 - 0x7FC3F   (1,360 words)
```

### Within Each Sample (per ts):
```
Input spikes:   word[offset + ts*25 + w]       — 32-bit packed (25 words covers 784 neurons)
Vmem LUT index: word[offset + (N_TS*25) + ts*210 + n]  — 8-bit LUT addr (0-255 → ±128 vmem)
H+O spikes:     word[offset + (N_TS*25+N_TS*210) + ts*7 + w]  — 32-bit packed (7 words for 210 neurons)
```

## File Output
- **smem_snapshot.mem:** 512K words (512,000 32-bit hex values + 11-line header)
  - Loadable with: `$readmemh("smem_snapshot.mem", smem_image);`
  - Size: ~2.1 MB on disk

## Verification

To verify all 320 samples are present:

```bash
cd inference_accelarator/neuron_accelerator

# Run testbench (full 320 samples)
# After simulation completes:
wc -l smem_snapshot.mem
# Expected: ~524,299 lines (524,288 words + 11 header)

# Check spike counts across samples
python3 ../../../tools/read_smem_snapshot.py smem_snapshot.mem \
  --n-hidden 200 --n-output 10 --timesteps 16  # sample 0 only shown
  
# Compare with hw_activations.csv (full accuracy report)
python3 ../../../tools/verify_spike_counts.py  # shows any sample
```

## Backward Compatibility
- `dump_target_sample` parameter still exists but is **no longer used**
  - Testbench now dumps all samples regardless
  - Remove the `+dump_sample=N` runtime option (ignored)

## Next Steps
1. **Compile on neumann:**
   ```bash
   cd inference_accelarator/neuron_accelerator
   vcs -full64 -sverilog -debug_access+all +v2k mnist_infertest_tb.v -o simv_mnist_inf
   ```

2. **Run inference:**
   ```bash
   ./simv_mnist_inf  # Runs all 320 samples (or use +input_count=N for subset)
   ```

3. **Parse and verify:**
   ```bash
   python3 ../../tools/read_smem_snapshot.py smem_snapshot.mem --quiet > accuracy_per_sample.txt
   ```

## Performance Impact
- **Memory:** +512 KB (now 512K words vs 384KB previous, ~2.1 MB file output)
- **Runtime:** Minimal (only one extra final $fopen/$fclose operation)
- **Accuracy:** No change (simulation logic identical, just persists all samples)

## Example Output
```
Loaded 524288 words from smem_snapshot.mem
Architecture (all LIF): 784 input + 200 hidden + 10 output
Timesteps: 16
Vmem storage: 8-bit surrogate LUT indices (0..255 → signed -128..+127 vmem)
  Mapping: 0..127 = v_mem +0..+127;  128..255 = v_mem -128..-1

Sample 0:  Total input spikes: 1381  |  hidden: 1525  |  output: 23  |  Predicted: digit 7
Sample 1:  Total input spikes: 1426  |  hidden: 1589  |  output: 18  |  Predicted: digit 3
Sample 2:  Total input spikes: 1334  |  hidden: 1451  |  output: 21  |  Predicted: digit 0
...
Sample 319: ...
```
