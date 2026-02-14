# Testing Guide for Neuron Accelerator (Inference Only)

## Overview
Your neuromorphic accelerator is fully functional for **inference** (forward pass) testing. You don't need the backpropagation learning unit to verify that your accelerator can correctly process neural network computations.

## What Can You Test Right Now?

### ✅ **Inference Testing** (Available Now)
- Forward propagation through neural network layers
- Spike encoding and routing
- Weight memory access and resolution
- Neuron cluster computations (LIF neuron model)
- Spike network forwarding
- Output generation

### ❌ **Training Testing** (Requires Backprop Unit - Future Work)
- Gradient computation
- Weight updates via backpropagation
- On-chip learning algorithms

---

## Testing Options

### **Option 1: Quick Functional Test (5-10 minutes)**

Test basic accelerator functionality with a simple configuration.

```bash
cd rtl/neuron_accelerator

# Compile the testbench with Icarus Verilog
iverilog -o neuron_accelerator_sim neuron_accelerator_tb.v

# Run with minimal test data
./neuron_accelerator_sim
```

**What this tests:**
- Clock and reset functionality
- Initialization data loading
- Basic spike processing
- FIFO operations

---

### **Option 2: Complete Inference Test with Pre-trained Weights**

This is the **recommended** way to fully validate your accelerator. You'll need:
1. A pre-trained neural network (trained in software)
2. Test input data
3. Expected output labels

```bash
cd rtl/neuron_accelerator

# Run the automated simulation script
# This will test with MNIST dataset if you have the model files
./simulation_automation.sh -n 16 32 -t 25 50

# Or for a quick test with minimal config:
./simulation_automation.sh -n 16 -t 25 --quick-test
```

**What this tests:**
- Complete inference pipeline
- Multi-layer neural network processing
- Spike encoding of MNIST images
- Weight memory initialization from trained model
- Output decoding and accuracy calculation
- Performance metrics (latency, throughput)

---

### **Option 3: Controller-Level Test**

Test the accelerator controller interface independently:

```bash
cd rtl/accelerator_controller

# Compile and run controller testbench
iverilog -o controller_sim accelerator_controller_tb.v
./controller_sim

# View waveforms (if you have GTKWave)
gtkwave accelerator_controller_tb.gtkw
```

**What this tests:**
- Controller state machine
- Initialization protocol (INIT_WRITE, INIT_READ)
- Spike input/output operations
- Data buffering and flow control

---

## Required Test Data Files

For full inference testing, you need these files in `rtl/neuron_accelerator/`:

### 1. **`data_mem.mem`** - Initialization Data
Contains network configuration and pre-trained weights in hex format:
```
10  // Example: neuron config
A5  // Weights for connections
3C
...
```

### 2. **`spike_mem.mem`** - Input Spike Patterns
Test input data encoded as spike trains:
```
001  // Spike packet: neuron ID + timestamp
7FF  // End marker
002
...
```

### 3. **Expected Output** - For Validation
The decoder script compares accelerator output against expected labels.

---

## How to Generate Test Data (Without Training)

Since you don't have the backprop unit yet, use **software-trained networks**:

### Method 1: Use Existing Pre-trained Model

If you have a Python/PyTorch trained model:

```python
# Example: export_weights.py
import torch
import numpy as np

# Load your trained model
model = torch.load('trained_model.pth')

# Extract weights and convert to fixed-point
def float_to_fixed(val, frac_bits=16):
    return int(val * (2 ** frac_bits))

# Export weights in hex format for Verilog
with open('data_mem.mem', 'w') as f:
    for layer in model.parameters():
        weights = layer.detach().numpy().flatten()
        for w in weights:
            f.write(f'{float_to_fixed(w):08X}\n')
```

### Method 2: Use Simple Test Patterns

Create synthetic test data for functional verification:

```python
# generate_test_data.py
import numpy as np

# Simple XOR test pattern
def generate_xor_test():
    inputs = [[0,0], [0,1], [1,0], [1,1]]
    expected = [0, 1, 1, 0]
    
    # Convert to spike encoding
    with open('spike_mem.mem', 'w') as f:
        for inp in inputs:
            # Encode: neuron fires if input is 1
            for i, val in enumerate(inp):
                if val == 1:
                    f.write(f'{i:03X}\n')
            f.write('7FF\n')  # End marker

generate_xor_test()
```

---

## Step-by-Step Testing Workflow

### **Step 1: Check Prerequisites**

```bash
# Check if Icarus Verilog is installed
iverilog -v

# Or if you have VCS (commercial simulator)
vcs -ID

# Check directory structure
ls -la rtl/neuron_accelerator/
```

### **Step 2: Prepare Minimal Test Data**

Create simple test files if you don't have them:

```bash
cd rtl/neuron_accelerator

# Create minimal initialization data (8 bytes)
echo "01" > data_mem.mem
echo "02" >> data_mem.mem
echo "03" >> data_mem.mem
echo "xx" >> data_mem.mem  # End marker

# Create minimal spike data
echo "001" > spike_mem.mem
echo "002" >> spike_mem.mem
echo "7FF" >> spike_mem.mem  # End marker
```

### **Step 3: Run Simulation**

```bash
# Compile
iverilog -g2009 -o sim neuron_accelerator_tb.v

# Run with parameters
./sim +time_step_window=10 +input_neurons=4 +nn_layers=1 +input_count=1

# Check output
cat output.txt
```

### **Step 4: Analyze Results**

Check for:
- ✅ Initialization completed without errors
- ✅ Spikes propagated through network
- ✅ Output generated
- ✅ No X (unknown) values in outputs
- ✅ Timing constraints met

---

## Expected Simulation Output

### Successful Inference Test:
```
==============================================
Simulation Parameters:
  time_step_window = 20
  input_neurons    = 784
  nn_layers        = 3
  input_count      = 960
==============================================
Loading init data: 1
Loading init data: 2
...
Initialization data loading completed.
Initialization completed.
Time step: 0, Input: 0
Time step: 1, Input: 0
...
Inference completed successfully.
Final accuracy: 95.3%
```

### Common Issues and Fixes:

**Issue 1:** `data_mem.mem: No such file`
```bash
# Create empty test files
touch data_mem.mem spike_mem.mem
echo "xx" > data_mem.mem
echo "7FF" > spike_mem.mem
```

**Issue 2:** Simulation hangs
- Check that FIFO depths are sufficient
- Verify spike_mem.mem has proper end markers (7FF)
- Increase simulation timeout

**Issue 3:** Unknown (X) values in output
- Verify all registers are properly initialized
- Check reset signal timing
- Ensure weights are loaded before inference

---

## Benchmarking Your Accelerator

### Performance Metrics to Collect:

1. **Latency**: Time from input spike to output spike
2. **Throughput**: Spikes processed per cycle
3. **Accuracy**: Match with software inference (should be ~100% for fixed-point quantized model)
4. **Resource Utilization**: 
   - FIFO usage
   - Memory bandwidth
   - Neuron cluster utilization

### Example Benchmark Script:

```bash
# Test different configurations
for neurons in 16 32 64 128; do
    for timesteps in 25 50 100; do
        echo "Testing: $neurons neurons, $timesteps timesteps"
        ./sim +input_neurons=$neurons +time_step_window=$timesteps
    done
done
```

---

## Integration with RISC-V (Next Steps)

Once basic inference works, you can add RISC-V control:

```
Current Testing:          With RISC-V:
┌─────────────────┐      ┌──────────────┐
│   Testbench     │      │   RISC-V     │
│   (Verilog)     │      │   Firmware   │
│                 │      │   (C code)   │
└────────┬────────┘      └──────┬───────┘
         │                      │
         │ Control Signals      │ Memory-mapped I/O
         ▼                      ▼
┌─────────────────────────────────────┐
│      Neuron Accelerator             │
│   (Your current working design)     │
└─────────────────────────────────────┘
```

The accelerator core remains the same - you just change how it's controlled.

---

## Summary

**You can fully test your accelerator NOW for:**
- ✅ Inference with pre-trained weights
- ✅ Functional verification
- ✅ Performance benchmarking
- ✅ Accuracy validation against software models

**You need the backprop unit for:**
- ❌ On-chip training
- ❌ Weight updates during execution
- ❌ Online learning experiments

**Next immediate steps:**
1. Run basic functional test (Option 1)
2. Verify with simple XOR or small dataset
3. Scale up to MNIST with pre-trained weights
4. Collect performance metrics
5. Then add RISC-V controller for better control
6. Finally add backprop unit for training capability

Would you like me to help you:
1. **Create test data files** for a simple XOR test?
2. **Run the simulation** and debug any issues?
3. **Set up a Python script** to export weights from a trained model?
4. **Create a benchmark suite** for performance testing?
