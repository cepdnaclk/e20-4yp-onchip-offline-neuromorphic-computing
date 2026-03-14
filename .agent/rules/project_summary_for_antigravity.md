# Full Project Summary for Antigravity

## 1. Project Identity
- Repository: e20-4yp-onchip-offline-neuromorphic-computing
- Owner: cepdnaclk
- Active branch: litex-soc
- Default branch: main
- Domain: On-chip offline neuromorphic computing (Spiking Neural Networks)

## 2. Problem and Goal
This project builds a complete hardware-software pipeline to run Spiking Neural Network (SNN) inference and on-chip learning on an FPGA SoC without needing a host computer during runtime learning.

Main objective:
- Execute forward inference in dedicated neuromorphic RTL hardware.
- Convert membrane potentials to surrogate gradients using a LUT peripheral.
- Run backpropagation and weight updates on an embedded RISC-V CPU.

## 3. End-to-End System Architecture
The system runs in three sequential states:

### State 1: Inference
- A neuromorphic accelerator performs forward pass on spike inputs.
- Leaky Integrate-and-Fire (LIF) neurons compute membrane potential and spike outputs.
- Relevant outputs (including pre-spike membrane values) are dumped into shared memory.

### State 2: Surrogate Substitution
- CPU reads each stored membrane value from shared memory.
- CPU queries surrogate LUT hardware over Wishbone.
- CPU overwrites each memory slot with h'(v) from LUT.
- Shared memory now contains surrogate gradients instead of raw membrane values.

### State 3: Learning (Backpropagation)
- CPU executes backpropagation using substituted surrogate values.
- Weights are updated in memory for subsequent inference/training cycles.

## 4. Core Technical Concepts
- Neuron model: Leaky Integrate-and-Fire (LIF).
- Number format: Signed Q16.16 fixed-point (32-bit).
- Bus protocol: Wishbone interconnect for CPU-peripheral communication.
- Surrogate gradient strategy: precomputed LUT values to avoid expensive runtime derivative computation.

## 5. Repository Structure (Functional View)
- inference_accelarator/
  - Neuron compute datapaths, spike routing, initialization router, and accelerator-level integration.
- surrogate_lut/
  - Surrogate LUT RTL and integration testbenches.
- shared_memory/
  - Shared BRAM controller and Wishbone-accessible memory modules.
- RISC_V/
  - 5-stage RV32IM CPU and custom extensions for SNN/backprop acceleration.
  - c_program/ for firmware-side control/backprop logic.
- custom_rv32im/ and soc-config/
  - LiteX/Migen-based SoC integration and custom CPU hookup.
- models/
  - Python training/data/model scripts and hardware export pipeline.
- tools/
  - Utilities for data generation, conversion, verification, and hardware/software comparison.
- firmware/ and code/
  - Bare-metal firmware and assembly test programs.

## 6. RISC-V Custom Backprop Extensions
The processor is RV32IM plus custom neuromorphic extensions for learning acceleration:
- Dual LIFO buffers (spike status + gradient values) for temporal storage/reverse-order replay.
- Memory-to-LIFO loader to stream memory directly into LIFO buffers.
- Custom backprop unit for weight update computation.
- Surrogate LUT integration for derivative substitution.
- Custom instruction support and pipeline integration around these operations.

Why this matters:
- Reduces software overhead for training-related data movement.
- Preserves temporal ordering needed by backward pass.
- Moves expensive operations into dedicated hardware blocks.

## 7. Verification and Test Status
Primary simulation stack uses Icarus Verilog (iverilog/vvp), with waveform inspection via GTKWave.

Documented test progression includes:
- L2a: Neuron cluster spike + V_mem checks: PASS.
- L2b: Cluster v_pre_spike wiring checks: PASS.
- L4: Accelerator known-value dump: functional checks pass; one known pre-existing write-count mismatch.
- L5: SNN inter-cluster propagation + dump: PASS.
- L6: Accelerator with real shared BRAM integration: PASS.
- L7: State-2 surrogate substitution integration: PASS.
- L8: Full pipeline (CPU + accelerator): work in progress.

## 8. Build/Run Toolchain Summary
- RTL simulation: iverilog + vvp.
- Waveform debug: gtkwave.
- Firmware target: bare-metal RV32IM.
- Python tooling: dataset prep, weight export, conversion checks, and hardware/software consistency analysis.
- SoC generation/integration: LiteX/Migen scripts.

Typical full regression entrypoint:
- run_tests.sh at repository root.

## 9. Data and Memory Flow (High-Level)
1. Spike inputs and configured weights drive inference accelerator.
2. Accelerator emits spike decisions and pre-spike membrane values.
3. Dump FSM writes these values to shared memory.
4. CPU reads each value and requests LUT output over Wishbone.
5. CPU writes surrogate outputs back to the same addresses.
6. CPU executes backprop using substituted values and updates weights.

## 10. Key Strengths of Current Design
- Full hardware/firmware co-design for offline on-chip learning.
- Deterministic fixed-point pipeline suitable for FPGA deployment.
- Clear separation of inference, surrogate substitution, and learning phases.
- Progressive verification ladder from unit-level to integrated tests.
- Architecture prepared for end-to-end autonomous training loops.

## 11. Current Gaps / Active Work
- Full L8 end-to-end pipeline closure remains in progress.
- Existing known discrepancy in one L4 bookkeeping metric (not currently functional correctness impact).
- Documentation in docs/README.md is still template-level and can be updated for publication-quality external documentation.

## 12. Suggested One-Line Positioning for External Audience
A hardware-software co-designed neuromorphic platform that performs SNN inference, surrogate-gradient substitution, and backpropagation fully on-chip using a custom RV32IM-based SoC.
