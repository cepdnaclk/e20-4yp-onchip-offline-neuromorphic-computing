# RV32IM + Custom Neuromorphic Extension Pipeline Implementation - Group 2

A 5-stage pipelined RISC-V processor implementation in Verilog supporting the RV32I base integer instruction set, M extension (multiplication/division), and a **custom neuromorphic backpropagation extension** for on-chip SNN learning.

> **ISA scope**: `RV32IM + custom neuromorphic extension` — this CPU does **not** implement RV32F (floating-point).  All weight and gradient arithmetic uses 16-bit fixed-point (Q8.8 scaled) integers.

---

## 📋 Table of Contents
- [Overview](#overview)
- [ISA Scope and Custom Extension](#isa-scope-and-custom-extension)
- [Features](#features)
- [Pipeline Architecture](#pipeline-architecture)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Simulation](#simulation)
- [Testing](#testing)
- [Team](#team)
- [Links](#links)

---

## 🔍 Overview

This project implements an **in-order 5-stage pipelined CPU** that conforms to the RISC-V ISA specification. The processor supports:
- **RV32I Base Integer Instruction Set**: The fundamental 32-bit RISC-V integer instruction set
- **M Extension**: Integer multiplication and division instructions
- **Custom Neuromorphic Extension** (opcode `0x0B` / `7'b0001011`): LIFO-based backpropagation instructions for on-chip SNN learning

The implementation is written in Verilog HDL and includes comprehensive testbenches for verification and validation.

---

## 🧩 ISA Scope and Custom Extension

### ISA Contract

This processor implements **RV32IM + custom neuromorphic extension only**.

| Extension | Status | Notes |
|-----------|--------|-------|
| RV32I     | ✅ Full | Base integer ISA |
| M         | ✅ Full | `mul`, `mulh`, `div`, `rem`, and variants |
| Custom 0x0B | ✅ Implemented | Neuromorphic backprop instructions |
| RV32F     | ❌ Not implemented | No floating-point hardware or register file |
| RV32D     | ❌ Not implemented | No double-precision |
| RV32C     | ❌ Not implemented | No compressed instructions |

The GCC toolchain is invoked with `-march=rv32i2p0_m -mabi=ilp32`, confirming no floating-point flag is set.  All learned weights and gradients are represented as **16-bit signed fixed-point (Q8.8)**, stored in the standard integer register file.

---

### Minimal Instruction Contract for Backprop Firmware

On-chip learning firmware (STATE 3) uses only the following instruction groups:

**Integer control flow** (RV32I)
- `beq`, `bne`, `blt`, `bge` — loop and conditional branching
- `jal`, `jalr` — function calls and computed jumps

**Memory ops** (RV32I)
- `lw`, `sw` — weight and gradient load/store from shared memory

**Arithmetic / bit ops** (RV32I + M)
- `add`, `sub`, `addi` — accumulation, pointer arithmetic
- `mul`, `mulh` — fixed-point scaling
- `slli`, `srli`, `srai` — fixed-point shift (×2ⁿ / ÷2ⁿ)
- `andi`, `ori` — bitmask operations (spike extraction)
- `lui`, `auipc` — large constant / address materialization

**Custom neuromorphic extension** (opcode `7'b0001011`)

| Mnemonic     | funct3 | Operation |
|--------------|--------|-----------|
| `LIFOPUSH`   | `000`  | Push rs1 (spike word) to spike LIFO buffer |
| `LIFOPUSHMG` | `101`  | DMA: stream gradient words from memory[rs1..rs1+4×rs2] into gradient LIFO |
| `LIFOPOP`    | `001`  | Start gradient/spike streaming; latch initial weight (rs1) and error term (rs2) into FU |
| `BKPROP`     | `010`  | Enable custom backprop unit to consume next serial element from LIFO streams |
| `LOADWT`     | `011`  | Load a fresh weight from rs1 into the backprop FU accumulator |
| `LIFOWB`     | `110`  | Write-back computed updated weight from FU accumulator to rd |

No RV32F instructions (`fadd.s`, `fmul.s`, `flw`, `fsw`, etc.) are used or decoded.

---



## ✨ Features

- **5-Stage Pipeline**:
  - Instruction Fetch (IF)
  - Instruction Decode (ID)
  - Execute (EX)
  - Memory Access (MEM)
  - Write Back (WB)

- **Hazard Handling**:
  - Data forwarding mechanism
  - Load-use hazard detection and resolution
  - Control hazard handling for branches and jumps

- **Complete Instruction Support**:
  - Arithmetic and logical operations
  - Load and store instructions
  - Branch and jump instructions
  - Multiplication and division (M extension)
  - Custom neuromorphic backpropagation instructions (opcode `0x0B`)

- **Components**:
  - ALU with multiple operations
  - Register file (32 registers)
  - Instruction and data memory
  - Branch controller
  - Control unit
  - Pipeline registers between stages
  - PISO LIFO buffers (spike and gradient streams)
  - Memory-to-LIFO DMA loader
  - Custom backpropagation functional unit (`custom_backprop_unit`)

---

## 🏗️ Pipeline Architecture

The processor implements a classic 5-stage RISC pipeline:

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│    IF    │ -> │    ID    │ -> │    EX    │ -> │   MEM    │ -> │    WB    │
│  Stage   │    │  Stage   │    │  Stage   │    │  Stage   │    │  Stage   │
└──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
     │               │                │               │               │
  Fetch         Decode          Execute         Memory          Write
Instruction   Instruction      ALU Ops         Access          Back to
from Memory   & Read Regs      & Branch        Data Mem        Registers
```

### Pipeline Stages:
1. **IF (Instruction Fetch)**: Fetches instruction from instruction memory using program counter
2. **ID (Instruction Decode)**: Decodes instruction, reads source registers, generates immediate values
3. **EX (Execute)**: Performs ALU operations, calculates branch targets
4. **MEM (Memory Access)**: Accesses data memory for load/store instructions
5. **WB (Write Back)**: Writes results back to register file

---

## 📁 Project Structure

```
.
├── ALUunit/              # Arithmetic Logic Unit implementation
├── Adder/                # Adder module for PC increment
├── BranchController/     # Branch decision logic
├── ControlUnit/          # Main control unit (instruction decoder)
├── CPU/                  # Top-level CPU module and testbench
├── Data Memory/          # Data memory and cache implementation
├── EX_MEM_pipeline/      # Execute-Memory pipeline register
├── HazardHandling/       # Forwarding unit and hazard detection
├── ID_EXPipeline/        # Decode-Execute pipeline register
├── ID_IF_pipeLIne/       # Fetch-Decode pipeline register
├── ImidiateGenarator/    # Immediate value generator
├── InstructionMemory/    # Instruction memory module
├── MEM_WBPipline/        # Memory-WriteBack pipeline register
├── MUX_32bit/            # Multiplexer modules
├── ProgramCounter/       # Program counter implementation
├── RegisterFile/         # 32-register register file
└── docs/                 # Project documentation
```

---

## 🔧 Prerequisites

To build and simulate this project, you need:

- **Icarus Verilog** (iverilog) - Verilog compiler/simulator
- **GTKWave** - Waveform viewer for analyzing simulation results
- **Make** (optional) - For automated build scripts

### Installation on Ubuntu/Debian:
```bash
sudo apt-get update
sudo apt-get install iverilog gtkwave
```

### Installation on macOS:
```bash
brew install icarus-verilog gtkwave
```

### Installation on Windows:
- Download Icarus Verilog from [bleyer.org/icarus](http://bleyer.org/icarus/)
- Download GTKWave from [gtkwave.sourceforge.net](http://gtkwave.sourceforge.net/)

---

## 🚀 Getting Started

### 1. Clone the Repository
```bash
git clone https://github.com/cepdnaclk/e20-co502-RV32IM-pipeline-implementation-group-2.git
cd e20-co502-RV32IM-pipeline-implementation-group-2
```

### 2. Navigate to CPU Directory
```bash
cd CPU
```

---

## 🎮 Simulation

### Compile and Run Simulation

To compile the CPU design and run the testbench:

```bash
# Compile the Verilog files
iverilog -o CPU_tb.out CPU_tb.v

# Run the simulation
vvp CPU_tb.out
```

This will generate a `cpu_pipeline.vcd` file containing the waveform data.

### View Waveforms

To analyze the simulation results using GTKWave:

```bash
gtkwave cpu_pipeline.vcd
```

Alternatively, if you have a saved GTKWave configuration:

```bash
gtkwave "file for gtk wave.gtkw"
```

---

## 🧪 Testing

The project includes testbenches for individual modules and the complete CPU:

- **CPU Testbench**: `CPU/CPU_tb.v` - Tests the complete pipeline
- **Module Testbenches**: Each major component has its own testbench in its respective directory
- **Custom Unit Testbench**: `extention/customUnit_tb.v` - Validates the backprop FU (5 test cases with [PASS]/[FAIL] output)
- **Benchmark Testbench**: `CPU/CPU_tb_benchmark.v` - Compares custom-unit path vs pure-software RV32I backprop on 16 neurons

### Running Module Tests

Example for testing the ALU:
```bash
cd ALUunit
iverilog -o alu_tb.out alu_tb.v
vvp alu_tb.out
```

### Running the Custom Backprop Unit Test

```bash
cd extention
iverilog -o backprop_tb customUnit_tb.v customUnit.v
vvp backprop_tb
```

Expected output (all 5 cases must show `[PASS]`):
```
[PASS] TC1 spike=1  error= 100 grad=128 | delta_out=50
[PASS] TC2 spike=0  error= 200 grad= 64 | delta_out=0
[PASS] TC3 spike=1  error=  50 grad= 64 (with temporal) | delta_out=21
[PASS] TC4 spike=1  error=-100 grad=128 (neg grad) | delta_out=-50
[PASS] TC5 grad_valid=0 (output must be 0) | delta_out=0
Results: 5 PASS, 0 FAIL
[PASS] All custom_backprop_unit tests passed.
```

### Running the CPU Benchmark (Custom Unit vs Software)

```bash
cd CPU
iverilog -o cpu_benchmark CPU_tb_benchmark.v
vvp cpu_benchmark
```

Expected summary (approximate cycle counts):
```
Custom unit : ~89 cycles
Software    : ~595 cycles
Speedup     : ~6.7x
```

### Verification Methodology

The testbench:
1. Initializes the CPU with a reset signal
2. Loads instructions into instruction memory
3. Runs the simulation for a specified number of clock cycles
4. Dumps register and memory contents for verification

---

## 👥 Team

### Team Members
- **E/20/419** - Wakkumbura M.M.S.S. ([e20419@eng.pdn.ac.lk](mailto:e20419@eng.pdn.ac.lk))
- **E/20/439** - Wickramasinghe J.M.W.G.R.L. ([e20439@eng.pdn.ac.lk](mailto:e20439@eng.pdn.ac.lk))
- **E/20/036** - Bandara K.G.R.I. ([e20036@eng.pdn.ac.lk](mailto:e20036@eng.pdn.ac.lk))

### Supervisors
- **Dr. Isuru Nawinne** ([isurunawinne@eng.pdn.ac.lk](mailto:isurunawinne@eng.pdn.ac.lk))

---

## 🔗 Links

- **Project Repository**: [GitHub](https://github.com/cepdnaclk/e20-co502-RV32IM-pipeline-implementation-group-2)
- **Project Page**: [GitHub Pages](https://cepdnaclk.github.io/e20-co502-RV32IM-pipeline-implementation-group-2)
- **Department**: [Computer Engineering, UoP](http://www.ce.pdn.ac.lk/)
- **University**: [University of Peradeniya](https://eng.pdn.ac.lk/)
- **RISC-V Specifications**: [RISC-V ISA Manual](https://riscv.org/technical/specifications/)

---

## 📄 License

This project is part of the CO502 Advanced Computer Architecture course at the University of Peradeniya.

---

## 🙏 Acknowledgments

- University of Peradeniya, Department of Computer Engineering
- CO502 - Advanced Computer Architecture course instructors
- RISC-V Foundation for the ISA specifications
