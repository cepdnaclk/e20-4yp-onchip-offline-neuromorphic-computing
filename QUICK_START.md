# Quick Start Guide: Testing Your Accelerator

## ✅ Yes! You Can Test Now Without Backpropagation

Your neuromorphic accelerator is **fully functional for inference testing**. You don't need the backpropagation learning unit to verify your hardware works correctly.

---

## What You're Testing

**Current Capability: Inference (Forward Pass)**
- ✅ Load pre-trained weights from software
- ✅ Process input spikes through neural network
- ✅ Compute neuron activations
- ✅ Generate output predictions
- ✅ Validate accuracy against expected results

**Future Capability: Training (Requires Backprop Unit)**
- ❌ Weight updates during execution
- ❌ Gradient computation
- ❌ On-chip learning

---

## Three Testing Approaches

### 🚀 Quick Test (5 minutes)

Test basic functionality with minimal setup:

```bash
# Run the setup script
./quick_test_setup.sh

# This creates minimal test files and checks for simulators
```

**What gets tested:**
- Clock/reset functionality
- FIFO operations
- Basic data flow
- Controller state machine

---

### 🎯 XOR Test (Recommended First Test)

Test with a simple 2-input XOR network:

```bash
# Step 1: Generate XOR network weights
python3 tools/export_weights_for_hardware.py --test-xor --output rtl/neuron_accelerator/data_mem.mem

# Step 2: Generate XOR input spikes
python3 tools/generate_spike_input.py --dataset xor --output rtl/neuron_accelerator/spike_mem.mem

# Step 3: Run simulation (if you have iverilog)
cd rtl/neuron_accelerator
iverilog -g2009 -o sim neuron_accelerator_tb.v
./sim +time_step_window=10 +input_neurons=2 +nn_layers=2 +input_count=4

# Step 4: Check results
cat output.txt
```

**Expected Results:**
```
Input: [0, 0] → Output: 0
Input: [0, 1] → Output: 1
Input: [1, 0] → Output: 1
Input: [1, 1] → Output: 0
Accuracy: 100%
```

---

### 🧠 MNIST Test (Full-Scale Test)

Test with real MNIST handwritten digit recognition:

```bash
# Step 1: Train a model in PyTorch/TensorFlow (or use pre-trained)
# Example: train_mnist.py → saves 'mnist_model.pth'

# Step 2: Export trained weights
python3 tools/export_weights_for_hardware.py \
    --model mnist_model.pth \
    --framework pytorch \
    --output rtl/neuron_accelerator/data_mem.mem

# Step 3: Generate MNIST spike inputs
python3 tools/generate_spike_input.py \
    --dataset mnist \
    --samples 100 \
    --timesteps 20 \
    --encoding rate \
    --output rtl/neuron_accelerator/spike_mem.mem \
    --labels-output rtl/neuron_accelerator/labels.txt

# Step 4: Run simulation
cd rtl/neuron_accelerator
./simulation_automation.sh -n 128 256 -t 20 50

# Step 5: Check accuracy
# Results saved in simulations/accelerator_simulation_results.csv
```

**Expected Results:**
- Accuracy should match software inference (~95-98% for MNIST)
- Small differences (<1%) acceptable due to fixed-point quantization

---

## Test Data Format

### `data_mem.mem` - Network Weights

Hex-encoded fixed-point weights (Q16.16 format):

```
00010000    # Weight value: 1.0
FFFF0000    # Weight value: -1.0
00008000    # Weight value: 0.5
xx          # End marker
```

### `spike_mem.mem` - Input Spikes

Spike packets (11 bits: neuron_id + timestamp):

```
001    # Neuron 1 fires
002    # Neuron 2 fires
003    # Neuron 3 fires
7FF    # End of timestep/sample
004    # Next sample...
7FF    # End marker
```

---

## Validation Checklist

After running simulation, verify:

- [ ] **Initialization Complete**: "Initialization completed" message appears
- [ ] **No X Values**: No unknown (X) values in output.txt
- [ ] **Spikes Processed**: Input spikes appear in output
- [ ] **Output Generated**: Output spikes or activations produced
- [ ] **Accuracy Match**: Results match software inference (±2%)
- [ ] **No Hangs**: Simulation completes without timeout
- [ ] **FIFO Status**: No FIFO overflow/underflow errors

---

## Troubleshooting

### Problem: No simulator installed

**Solution:**
```bash
# Ubuntu/Debian
sudo apt-get install iverilog gtkwave

# macOS
brew install icarus-verilog gtkwave

# Or use Docker
docker run -it -v $(pwd):/work hdlc/sim:osvb
```

### Problem: Simulation hangs

**Causes:**
- Missing end markers in .mem files
- FIFO depth too small
- Incorrect parameters

**Solution:**
```bash
# Check for end markers
tail spike_mem.mem  # Should end with 7FF
tail data_mem.mem   # Should end with xx

# Increase FIFO depths in neuron_accelerator.v
# parameter main_fifo_depth = 64  (increase if needed)
```

### Problem: Wrong output values

**Causes:**
- Incorrect fixed-point conversion
- Weight quantization errors
- Neuron parameter mismatch

**Solution:**
```bash
# Check fixed-point format
python3 -c "print(hex(int(1.5 * (2**16))))"  # Should be 0x00018000

# Compare with software inference first
# Ensure both use same activation functions
```

### Problem: File not found errors

**Solution:**
```bash
# Generate all required files
python3 tools/export_weights_for_hardware.py --test-xor
python3 tools/generate_spike_input.py --dataset xor

# Check they exist
ls -la rtl/neuron_accelerator/*.mem
```

---

## Performance Metrics to Collect

When testing, measure:

1. **Latency**: Time from first input spike to first output spike
2. **Throughput**: Samples processed per second
3. **Accuracy**: Percentage of correct predictions
4. **Resource Usage**: FIFO utilization, memory bandwidth
5. **Power** (if using synthesis tools): Estimated power consumption

Example analysis:
```bash
# Extract timing from simulation
grep "Time step:" output.txt | tail -n 1

# Calculate throughput
# throughput = (total_samples * clock_freq) / total_cycles
```

---

## Next Steps After Successful Testing

Once basic inference works:

### Phase 1: Controller Integration (Current Focus)
- ✅ **Test basic inference** ← You are here
- ⬜ Add RISC-V controller for better control
- ⬜ Implement memory-mapped interface
- ⬜ Test with C firmware instead of Verilog testbench

### Phase 2: Learning Unit (Future)
- ⬜ Design gradient calculator
- ⬜ Implement weight updater
- ⬜ Add backpropagation logic
- ⬜ Test on-chip training

### Phase 3: Full SoC (Final Goal)
- ⬜ Integrate all components
- ⬜ Add DMA controller
- ⬜ Implement complete training pipeline
- ⬜ Tape-out or FPGA implementation

---

## Common Questions

**Q: Can I train networks without the backprop unit?**
A: No, you need to train in software (PyTorch/TensorFlow) and export weights.

**Q: What accuracy should I expect?**
A: Should match software inference within 1-2% (fixed-point quantization loss).

**Q: How long does simulation take?**
A: XOR test: <1 minute, MNIST (100 samples): 5-30 minutes depending on simulator.

**Q: Can I use this with FPGAs?**
A: Yes! The Verilog is synthesizable. Test in simulation first, then synthesize.

**Q: Do I need the RISC-V controller for testing?**
A: No, the Verilog testbench can control the accelerator directly.

---

## Support & Documentation

- **Full Testing Guide**: `TESTING_GUIDE.md`
- **Architecture Overview**: See diagram in project README
- **Tool Documentation**:
  - `tools/export_weights_for_hardware.py --help`
  - `tools/generate_spike_input.py --help`

---

## Summary

✅ **You can test your accelerator NOW for inference**
✅ **Use pre-trained weights from software**
✅ **Validate functionality before adding complex features**
✅ **Start simple (XOR), then scale up (MNIST)**

The backpropagation unit is only needed for **on-chip training**, not for verifying that your accelerator hardware works correctly!
