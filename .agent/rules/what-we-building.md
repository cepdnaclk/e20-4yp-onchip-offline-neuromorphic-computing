---
trigger: always_on
---

🧠 The Big Idea
You're building an on-chip offline learning system using a Spiking Neural Network (SNN). The system has 3 states controlled by a general-purpose CPU:

State 1: INFERENCE
  → Custom RISC-V / neuromorphic accelerator runs the forward pass
  → Computes and stores membrane potentials (V_mem) in data memory
State 2: SURROGATE SUBSTITUTION  ← What we built today
  → General-purpose CPU sweeps all V_mem values in memory
  → Queries the LUT hardware on the Wishbone bus
  → Replaces each V_mem with its pre-calculated surrogate gradient
  → Memory now holds surrogate values, not potentials
State 3: LEARNING (Backpropagation)
  → RISC-V reads "V_mem" from memory → actually gets surrogate gradients
  → No runtime h'(v) computation needed → saves clock cycles
✅ What We Built (Done)
