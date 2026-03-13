# GitHub Copilot Instructions

This file gives GitHub Copilot context about the project so that its suggestions are accurate and consistent with the codebase.

---

## Project Overview

This is an **on-chip offline neuromorphic computing system** that implements a full Spiking Neural Network (SNN) training and inference pipeline in hardware and firmware. The system is designed to run on an FPGA SoC and supports on-chip backpropagation using surrogate gradients — without needing a host PC once deployed.

---

## System Architecture: Three States

The chip operates in three sequential states, orchestrated by a RISC-V CPU on the SoC:

| State | Name | Description |
|-------|------|-------------|
| **1** | **Inference** | The neuromorphic accelerator (Verilog RTL) runs the SNN forward pass. LIF neurons compute membrane potentials (`V_mem`) and spike outputs. Results are stored in shared memory (BRAM). |
| **2** | **Surrogate Substitution** | The RISC-V CPU sweeps `V_mem` values in memory, queries the surrogate gradient LUT hardware over Wishbone bus, and overwrites each `V_mem` slot with `h'(v)` — the pre-computed surrogate gradient value. |
| **3** | **Learning (Backpropagation)** | The RISC-V CPU reads the "V_mem" slots (which now hold surrogate gradients) and runs the backpropagation algorithm, updating synaptic weights in memory. No runtime gradient computation is needed. |

---

## Repository Structure

```
.
├── inference_accelarator/   # Hardware SNN inference accelerator (Verilog RTL)
│   ├── neuron_cluster/      # LIF neuron cluster module + testbenches
│   ├── neuron_accelerator/  # Top-level accelerator, spike network, weight resolver
│   ├── init_router/         # Network initialisation and weight loading
│   └── shared_memory/       # BRAM shared between accelerator and CPU
├── RISC_V/                  # 5-stage pipelined RV32IM processor (Verilog)
│   ├── CPU/                 # Pipeline stages and control units
│   ├── c_program/           # C firmware for backpropagation and SoC control
│   └── docs/                # RISC-V-specific documentation
├── surrogate_lut/           # Surrogate gradient LUT hardware module (Verilog)
├── shared_memory/           # Shared memory controller (Verilog)
├── models/                  # Python: SNN model definitions, compiler, training
│   └── smnist_lif_model/    # Spiking MNIST model
├── tools/                   # Python: weight export, spike generation, assembler
├── soc-config/              # Python/LiteX: custom SoC build scripts
├── custom_rv32im/           # Python/Migen: custom CPU core for LiteX integration
├── firmware/                # Compiled firmware hex files
├── code/                    # RISC-V assembly test programs
├── surrogate_lut/           # Pre-calculated surrogate gradient tables
└── docs/                    # Project documentation
```

---

## Technology Stack

### Hardware (RTL)
- **Language:** Verilog (IEEE 1364-2001 / 2005), some SystemVerilog constructs
- **Simulator:** Icarus Verilog (`iverilog` / `vvp`) is the primary simulator; Synopsys VCS is used for MNIST-scale testbenches
- **Waveform viewer:** GTKWave (`.vcd` files)
- **Fixed-point arithmetic:** `Q16.16` format — 32-bit values where the upper 16 bits are the integer part and lower 16 bits are the fractional part

### Firmware / Embedded Software
- **Language:** C (RV32IM target), RISC-V assembly (`.s`)
- **Toolchain:** RISC-V GCC (`riscv32-unknown-elf-gcc`)
- **Memory layout:** instruction memory and data memory are separate; firmware addresses start from `0x00000000`

### Python Tools
- **Python 3**, NumPy/SciPy for model training and data preparation
- **LiteX / Migen** for SoC generation (`snn_soc.py`, `soc-config/`)
- **Jupyter notebooks** (`.ipynb`) for exploratory analysis in `models/`

---

## Key Technical Concepts

### LIF Neuron (Leaky Integrate-and-Fire)
The hardware neuron model. Each tick:
1. Accumulates weighted input spikes into membrane potential `V_mem`
2. If `V_mem >= V_threshold (VT)`, the neuron **fires** (spike = 1) and `V_mem` resets
3. Otherwise `V_mem` leaks by a configured `leak` factor

### Fixed-Point Format (Q16.16)
All membrane potentials, weights, and threshold values are stored as signed 32-bit Q16.16:
- Bit 31 = sign
- Bits 30–16 = integer part
- Bits 15–0 = fractional part
- Example: `32'h00010000` = `1.0`, `32'h00008000` = `0.5`

### Surrogate Gradient
Because the Heaviside spike function is non-differentiable, backpropagation uses a smooth surrogate `h'(v)`. This value is pre-computed for a range of `V_mem` levels and stored in a hardware LUT. The LUT is accessed via Wishbone bus from the RISC-V CPU.

### Wishbone Bus
The standard on-chip bus used for CPU ↔ peripheral communication. The surrogate LUT and shared memory are Wishbone slaves. The RISC-V CPU is the master.

---

## Coding Conventions

### Verilog
- Module names match file names (e.g., `neuron_cluster.v` defines `module neuron_cluster`)
- Use `parameter` for configurable constants; put them at the top of the module
- Use `localparam` for internal constants
- Prefer synchronous resets (`if (!rst_n)`) — active-low reset is named `rst_n`
- Clock signal is always named `clk`
- Fixed-point values are 32-bit (`[31:0]`); use signed arithmetic where appropriate
- `include` guards use the module name uppercased, e.g., `` `ifndef NEURON_CLUSTER ``
- Testbenches end in `_tb.v` and are in the same directory as the module they test
- Use `$display` / `$monitor` for simulation output; use `[PASS]` / `[FAIL]` prefix for check results

### Python
- Use snake_case for variables and functions
- NumPy arrays for weight matrices and spike trains
- Fixed-point conversion helper: multiply float by `65536` (2^16) and cast to `int32`
- Memory files (`.mem`) use hex values, one word per line, compatible with `$readmemh`

### C (Firmware)
- Target: bare-metal RV32IM (no OS, no stdlib unless explicitly linked)
- Use `volatile` for memory-mapped I/O registers
- Wishbone peripheral base addresses are defined as macros in a header
- Function names: `snake_case`; constants: `UPPER_SNAKE_CASE`

---

## Running Tests

### Icarus Verilog (standard for all RTL tests)
```bash
# Generic pattern — substitute actual paths
iverilog -g2012 -Wno-timescale -o <module>_tb.vvp <module>_tb.v
vvp -n <module>_tb.vvp
```

### Test levels (see TESTING.md for full details)
| Level | Description | File |
|-------|-------------|------|
| L2a | Neuron cluster spike + V_mem | `inference_accelarator/neuron_cluster/neuron_cluster_tb.v` |
| L2b | Cluster v_pre_spike wiring | `inference_accelarator/neuron_cluster/neuron_cluster_vmem_tb.v` |
| L4 | Accelerator known-value dump | `inference_accelarator/neuron_accelerator/known_value_dump_tb.v` |
| L5 | SNN inter-cluster + dump | `inference_accelarator/neuron_accelerator/snn_integration_dump_tb.v` |
| L6 | Accelerator + real BRAM | `inference_accelarator/neuron_accelerator/real_mem_integration_tb.v` |
| L7 | STATE 2 surrogate substitution | `surrogate_lut/state2_integration_tb.v` |
| L8 | Full pipeline (CPU + accel) | `blackbox/pipeline_integration_tb.v` |

Run all tests at once:
```bash
bash run_tests.sh
```

---

## Using GitHub Copilot in This Project

### Setup

1. **Install the GitHub Copilot extension** in VS Code:
   - Open VS Code → Extensions (`Ctrl+Shift+X`) → search **"GitHub Copilot"** → Install
   - Sign in with your GitHub account (you need a Copilot licence or the free tier)

2. **Open the repository root** in VS Code so Copilot picks up this instructions file automatically:
   ```
   code /path/to/e20-4yp-onchip-offline-neuromorphic-computing
   ```

3. **Recommended VS Code extensions for this project** (install manually or add to `.vscode/extensions.json` locally):
   - `mshr-h.veriloghdl` — Verilog syntax highlighting and linting
   - `eirikpre.systemverilog` — SystemVerilog / Verilog language support
   - `ms-python.python` — Python language support
   - `github.copilot` — GitHub Copilot
   - `github.copilot-chat` — GitHub Copilot Chat

### Recommended VS Code settings (add to your local `.vscode/settings.json`)

```json
{
  "github.copilot.enable": {
    "*": true,
    "verilog": true,
    "systemverilog": true,
    "python": true,
    "c": true,
    "asm": true
  },
  "editor.inlineSuggest.enabled": true,
  "[verilog]": {
    "editor.tabSize": 4,
    "editor.insertSpaces": true
  },
  "[python]": {
    "editor.tabSize": 4
  },
  "[c]": {
    "editor.tabSize": 4
  }
}
```

> **Note:** `.vscode/` is listed in `.gitignore` so your local editor settings are not committed.

### Effective Copilot Usage Tips

#### Verilog / RTL modules
- Start a new module with a header comment describing its purpose and interface. Copilot will infer the port list and internal logic:
  ```verilog
  // Module: weight_resolver
  // Reads synaptic weights from BRAM and distributes them to neuron clusters.
  // Inputs: clk, rst_n, neuron_id [7:0], read_en
  // Outputs: weight_out [31:0], valid
  module weight_resolver #(
  ```
- Describe what a `always @(posedge clk)` block should do in a comment immediately above it. Copilot will suggest the body.
- Use `// Q16.16` in comments near arithmetic signals to remind Copilot of the fixed-point format.

#### Python tools
- Add a docstring at the top of a function describing inputs and expected output format:
  ```python
  def export_weights_to_mem(weights: np.ndarray, output_path: str) -> None:
      """Export a NumPy weight matrix as a hex memory file (.mem) for $readmemh.
      Weights are converted from float32 to Q16.16 fixed-point signed integers.
      Each word is written as an 8-digit hex value, one per line.
      """
  ```

#### C firmware
- Keep a comment near memory-mapped register macros; Copilot uses them for context:
  ```c
  // Wishbone base address for surrogate LUT peripheral
  #define SURROGATE_LUT_BASE  0x82000000
  #define SURROGATE_LUT_INPUT  (*(volatile uint32_t *)(SURROGATE_LUT_BASE + 0x00))
  #define SURROGATE_LUT_OUTPUT (*(volatile uint32_t *)(SURROGATE_LUT_BASE + 0x04))
  ```

#### Copilot Chat (inline or panel)
Use `@workspace` to ask questions about the whole codebase:
- *"@workspace explain how V_mem values flow from the inference accelerator to the surrogate LUT"*
- *"@workspace how does the neuron_cluster module handle the spike threshold comparison?"*
- *"@workspace write a testbench for the weight_resolver module following the existing testbench pattern"*

Use `/explain` to understand a selected block, `/fix` to fix a bug, `/tests` to generate a testbench.

---

## Important Files for Copilot Context

When asking Copilot Chat questions, opening these files first gives it the best context:

| File | Why it matters |
|------|---------------|
| `inference_accelarator/neuron_cluster/neuron_cluster.v` | Core LIF neuron cluster RTL |
| `inference_accelarator/neuron_accelerator/neuron_accelerator.v` | Top-level inference accelerator |
| `surrogate_lut/surrogate_lut.v` | Surrogate gradient LUT hardware |
| `shared_memory/snn_shared_mem.v` | Shared BRAM controller |
| `RISC_V/CPU/` | 5-stage pipeline stages |
| `RISC_V/c_program/` | Backpropagation firmware |
| `models/smnist_lif_model/` | Python SNN model definition |
| `tools/generate_spike_input.py` | Spike input generation utility |
| `snn_soc.py` | LiteX SoC top-level integration |
| `TESTING.md` | Full RTL test guide |
| `CUSTOM_BACKPROP_ARCHITECTURE.md` | Deep-dive: custom CPU extensions for backprop |
