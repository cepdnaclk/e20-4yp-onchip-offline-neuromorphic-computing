# Important Commands (Inference / Weight Conversion / C Builds)

This file is a **copy‑paste cheat sheet** for the most important workflows in this repo.

> Assumption: run commands from the **repo root** unless a `cd` is shown.

---

## 0) Quick tool sanity checks

```bash
python3 --version
gcc --version
iverilog -V
vvp -V
```

Optional:
```bash
gtkwave --version
```

---

## 1) RTL regression tests (Icarus)

Run all verified accelerator tests (L2a–L7):

```bash
bash run_tests.sh
```

Run a single level (example L6):

```bash
bash run_tests.sh L6
```

---

## 2) MNIST inference (Icarus “one click” pipeline)

This runs the full flow:
- weights → `data_mem.mem`
- MNIST → `spike_mem.mem` + `test_labels.txt`
- compile + simulate (`iverilog` + `vvp`)
- decode and print accuracy

```bash
cd tools
python3 sim_runner/run_mnist_inference.py
```

Common options:

```bash
cd tools
# Fewer samples / faster
python3 sim_runner/run_mnist_inference.py --samples 50 --timesteps 16

# Reuse existing generated files
python3 sim_runner/run_mnist_inference.py --skip_datamem --skip_spikes

# Skip compile (reuse existing sim.vvp)
python3 sim_runner/run_mnist_inference.py --skip_compile
```

---

## 3) Weight conversion

### 3A) Convert **C‑trainer weight dump** → hardware `data_mem_*.mem`

Input: a text file produced by the C trainers (e.g. `best_weights_hw.txt`).
Output: a byte‑per‑line `.mem` file compatible with `$readmemh`.

```bash
python3 tools/weights/convert_ccode_weights_to_datamem.py \
  RISC_V/c_program/best_weights_hw.txt \
  -o inference_accelarator/neuron_accelerator/data_mem_mnist_new.mem \
  --int-scale 256 --decay lif24 --reset-mode zero
```

Notes:
- `--int-scale 256` must match the C trainer’s `#define SCALE 256`.
- `--decay lif24` matches the hardware β=0.75 mode.

### 3B) Convert **Python/legacy weights** → hardware `data_mem.mem`

This is used by the Icarus inference pipeline by default.

```bash
python3 tools/weights/convert_weights_to_datamem.py \
  --weights tools/best_weights_epoch_1.txt \
  --output inference_accelarator/neuron_accelerator/data_mem.mem \
  --hidden_threshold 30 \
  --output_threshold 1 \
  --scale 1
```

---

## 4) C trainer / dump generation (host build)

### 4A) Build + run `backpropD_hw.C` (hardware‑matched trainer)

This program reads `mnist_full_train.bin` from the current directory.

```bash
cd RISC_V/c_program

# (Optional) generate mnist_full_train.bin
python3 prepare_mnist_data.py --train-count 60000 --output mnist_full_train.bin

# Compile
gcc -O2 -Wall -o backpropD_hw backpropD_hw.C -lm

# Run
./backpropD_hw
```

Enable the CSV dump (`software_vmem_spikes.csv`):

```bash
cd RISC_V/c_program

gcc -O2 -Wall -DDUMP_VMEM_SPIKES -o backpropD_hw backpropD_hw.C -lm
./backpropD_hw
```

Make a **small** dataset for quick debug (e.g. 1 or 100 samples):

```bash
cd RISC_V/c_program
python3 prepare_mnist_data.py --train-count 100 --output mnist_full_train.bin
./backpropD_hw
```

Output files (typical):
- `software_vmem_spikes.csv` (when compiled with `-DDUMP_VMEM_SPIKES`)
- `best_weights_hw.txt` (when it prints “Best weights saved …”)

### 4B) Full backprop pipeline helper script

This script can: prepare MNIST → compile/train `backpropD.C` → convert weights → run VCS testbench (if available).

```bash
cd RISC_V/c_program
bash run_backprop_training.sh
```

Common flags:

```bash
cd RISC_V/c_program
# Skip dataset preparation
bash run_backprop_training.sh --no-prepare

# Train only (no hardware test)
bash run_backprop_training.sh --no-test

# Only convert + test (no training)
bash run_backprop_training.sh --no-train
```

---

## 5) STATE 2 firmware build (RISC-V cross compile)

Used by the full pipeline integration test (L8).

```bash
cd RISC_V/c_program

riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O1 -nostdlib \
  -T link.ld crt0.s state2_surrogate.c \
  -o state2_surrogate.elf

riscv64-unknown-elf-objcopy -O verilog --verilog-data-width=4 \
  state2_surrogate.elf state2_surrogate.hex

riscv64-unknown-elf-objdump -d state2_surrogate.elf > state2_surrogate.dump
```

---

## 6) Hardware snapshot dump + SW/HW alignment compare (VCS path)

If you have Synopsys VCS set up, you can dump a single sample snapshot from the inference testbench:

```bash
cd inference_accelarator/neuron_accelerator

# Build
vcs -full64 -sverilog -timescale=1ns/1ps -o simv_mnist \
  mnist_infertest_tb.v neuron_accelerator.v \
  ../FIFO/fifo.v ../initialization_router/init_router.v \
  ../initialization_router/init_routers_tb.v \
  ../initialization_router/self_data_mng.v \
  ../../shared_memory/snn_shared_memory_wb.v

# Run (dump sample 0)
./simv_mnist +dump_sample=0 +input_count=1
```

Then generate the software dump and compare:

```bash
# Software dump
cd ../../RISC_V/c_program
python3 prepare_mnist_data.py --train-count 1 --output mnist_full_train.bin

gcc -O2 -Wall -DDUMP_VMEM_SPIKES -o backpropD_hw backpropD_hw.C -lm
./backpropD_hw

# Compare
cd ../../tools
python3 compare_hw_sw_dumps.py \
  --hw ../inference_accelarator/neuron_accelerator/smem_all_samples.csv \
  --sw ../RISC_V/c_program/software_vmem_spikes.csv
```

Notes:
- The compare tool works on **CSV ↔ CSV**. It expects the hardware side to be a file like
  `smem_all_samples.csv` (same schema as `software_vmem_spikes.csv`).
- Some older docs mention `compare_dumps.py` / `read_smem_snapshot.py`; those scripts are not present in this branch.
