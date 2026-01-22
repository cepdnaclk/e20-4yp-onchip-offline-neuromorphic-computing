# Time-Multiplexed Backpropagation Neuron

## Overview

This module implements a **Leaky Integrate-and-Fire (LIF) neuron** that supports both **forward propagation** and **backward propagation** using time multiplexing. The same hardware is reused for both phases, making it efficient for on-chip learning in neuromorphic systems.

## Key Features

✅ **Time-multiplexed operation**: Single neuron hardware for both forward and backward passes  
✅ **Spike-based computation**: Compatible with neuromorphic processing  
✅ **On-chip learning**: Weight updates using backpropagation  
✅ **Spike history tracking**: Stores past activity for temporal gradient calculation  
✅ **Configurable parameters**: Adjustable threshold, leak rate, learning rate  
✅ **Error propagation**: Calculates gradients and propagates error to previous layers  

---

## Architecture

### Forward Pass Flow
```
Input Spikes → Weight Multiplication → Accumulation → Leak/Decay → Threshold Comparison → Output Spike
                                            ↓
                                    Spike History Storage
```

### Backward Pass Flow
```
Error Gradient → Gradient Calculation → Weight Update → Error Propagation
                        ↑
                 Spike History Retrieval
```

---

## Module Interface

### Parameters
| Parameter | Default | Description |
|-----------|---------|-------------|
| `DATA_WIDTH` | 16 | Width of data signals (membrane potential, gradients) |
| `WEIGHT_WIDTH` | 16 | Width of weight values |
| `NUM_INPUTS` | 8 | Number of input synaptic connections |
| `SPIKE_HISTORY_DEPTH` | 32 | Depth of spike history buffer for BPTT |

### Ports

#### Control Signals
- `clk`: System clock
- `rst_n`: Active-low asynchronous reset
- `mode`: Operation mode (0 = Forward, 1 = Backward)
- `enable`: Enable neuron operation
- `weight_init_mode`: Enable weight initialization

#### Forward Pass Inputs
- `spike_in[NUM_INPUTS-1:0]`: Input spike train (1-bit per input)
- `threshold`: Firing threshold for spike generation
- `leak_rate`: Membrane potential leak/decay rate

#### Backward Pass Inputs
- `error_gradient`: Error signal from next layer
- `learning_rate`: Learning rate for weight updates
- `backprop_enable`: Enable backpropagation computation

#### Weight Initialization
- `weight_init_addr`: Address for weight initialization
- `weight_init_data`: Weight value to initialize
- `weight_init_write`: Write enable for weight initialization

#### Forward Pass Outputs
- `spike_out`: Output spike (1 = spike generated)
- `membrane_potential`: Current membrane potential
- `membrane_potential_pre_spike`: Membrane potential before spike check

#### Backward Pass Outputs
- `error_out`: Error to propagate to previous layer
- `weight_update_done`: Flag indicating weight update completion

#### Monitoring Outputs
- `spike_count`: Total number of spikes generated
- `total_weight_change`: Accumulated magnitude of weight changes

---

## Operation Modes

### 1. Weight Initialization Mode
Before operation, weights must be initialized:

```verilog
weight_init_mode = 1;
for (i = 0; i < NUM_INPUTS; i++) {
    weight_init_addr = i;
    weight_init_data = initial_weight_value;
    weight_init_write = 1;
    @(posedge clk);
}
weight_init_write = 0;
weight_init_mode = 0;
```

### 2. Forward Pass Mode
Set `mode = 0` and `enable = 1`:

1. **Input Integration**: Weighted sum of input spikes is calculated
2. **Membrane Update**: Current membrane potential is updated with:
   - Added: weighted input sum
   - Subtracted: leak rate (membrane decay)
3. **Spike Generation**: If membrane ≥ threshold, output spike is generated and membrane resets
4. **History Recording**: Spike status, input spikes, and membrane potential are stored

**Example Timeline:**
```
Cycle 1: spike_in = 8'b00000011 → weights[0] + weights[1] added to membrane
Cycle 2: spike_in = 8'b00000000 → only leak applied
Cycle 3: spike_in = 8'b10000000 → weights[7] added
...
```

### 3. Backward Pass Mode
Set `mode = 1` and `backprop_enable = 1`:

The backward pass operates as a state machine:

#### State 1: CALC_GRADIENT
- Retrieves spike history (most recent timestep)
- Calculates weight gradients using surrogate gradient approach:
  - If neuron spiked: `gradient = error × learning_rate`
  - If no spike: `gradient = error × learning_rate × membrane_proximity_to_threshold`

#### State 2: UPDATE_WEIGHTS
- Updates each weight: `W_new = W_old - gradient`
- Tracks total weight change for monitoring

#### State 3: PROPAGATE_ERROR
- Calculates error for previous layer: `error_out = Σ(error × weight)`

#### State 4: DONE
- Sets `weight_update_done = 1`
- Returns to IDLE

---

## Data Storage

### Weight Memory
- **Storage**: `NUM_INPUTS` signed weights
- **Initialization**: Via weight initialization interface
- **Updates**: During backward pass

### Spike History Buffers
Three circular buffers store temporal information:

1. **spike_history**: Records whether neuron fired (1-bit per timestep)
2. **input_spike_history**: Records input spike patterns (NUM_INPUTS bits per timestep)
3. **membrane_history**: Records membrane potential values (DATA_WIDTH bits per timestep)

**Buffer Management:**
- `history_write_ptr`: Points to next write location (increments during forward pass)
- `history_read_ptr`: Points to read location (set during backward pass)
- Circular buffer wraps at `SPIKE_HISTORY_DEPTH`

---

## Usage Example

### Complete Training Cycle

```verilog
// 1. Initialize weights
weight_init_mode = 1;
// ... initialize weights ...
weight_init_mode = 0;

// 2. Forward pass (20 timesteps)
mode = 0;
enable = 1;
for (i = 0; i < 20; i++) {
    spike_in = input_pattern[i];
    @(posedge clk);
}
enable = 0;

// 3. Backward pass
mode = 1;
backprop_enable = 1;
error_gradient = calculated_error;
learning_rate = 256; // 1.0 in fixed point
@(posedge clk);

// Wait for completion
while (!weight_update_done) {
    @(posedge clk);
}

// 4. Retrieve propagated error
propagated_error = error_out;
backprop_enable = 0;
```

---

## Testing

### Running the Testbench

```bash
# Using iverilog
iverilog -o backprop_neuron_tb.vvp backprop_neuron.v backprop_neuron_tb.v
vvp backprop_neuron_tb.vvp

# View waveforms
gtkwave backprop_neuron_tb.vcd
```

### Test Coverage

The provided testbench (`backprop_neuron_tb.v`) includes:

1. ✅ Weight initialization
2. ✅ Forward pass with no spikes
3. ✅ Forward pass with single spike input
4. ✅ Forward pass with multiple spike inputs
5. ✅ Spike generation when threshold exceeded
6. ✅ Membrane potential decay
7. ✅ Extended forward pass (spike history building)
8. ✅ Backward pass gradient calculation
9. ✅ Weight updates
10. ✅ Error propagation
11. ✅ Complete forward-backward training cycle

---

## Fixed-Point Representation

All arithmetic uses signed fixed-point representation:

- **Weights**: 16-bit signed integers
- **Membrane Potential**: 16-bit signed integers
- **Learning Rate**: 16-bit signed (scaled by 256, so LR=256 means 1.0)
- **Gradients**: Scaled by right shifts (>>> operator) to prevent overflow

### Example Scaling
- `learning_rate = 256` → effective LR = 1.0
- `learning_rate = 128` → effective LR = 0.5
- `learning_rate = 512` → effective LR = 2.0

---

## How Backpropagation Works in This Design

### Surrogate Gradient Method

Spiking neurons have discontinuous activation functions, making traditional backprop difficult. This design uses a **surrogate gradient** approach:

1. **When neuron spikes**: Use simplified gradient approximation
   ```
   ∂L/∂w_i = error × learning_rate
   ```

2. **When neuron doesn't spike**: Use membrane potential proximity
   ```
   ∂L/∂w_i = error × learning_rate × (membrane / scale_factor)
   ```

This provides differentiable approximations suitable for hardware implementation.

### Gradient Descent Update Rule
```
W_new = W_old - ∂L/∂w
```

Where `∂L/∂w` is the calculated gradient.

---

## Time Multiplexing Strategy

The same hardware is reused for both passes:

| Component | Forward Pass Use | Backward Pass Use |
|-----------|------------------|-------------------|
| Weight Memory | Read for input weighting | Read/Write for updates |
| Accumulator/Adder | Sum weighted inputs | Sum gradients |
| Comparator | Threshold check | Error calculation |
| History Buffers | Write mode | Read mode |

This approach **reduces hardware cost** by ~50% compared to separate forward/backward circuits.

---

## Integration with Neural Network

### Layer Connection Example

```
Layer 0          Layer 1          Layer 2
(8 neurons)  →  (8 neurons)  →  (4 neurons)
```

**Forward Pass:**
1. Layer 0 generates output spikes
2. Layer 1 receives spikes, processes, generates outputs
3. Layer 2 receives spikes, produces final outputs

**Backward Pass:**
1. Calculate error at Layer 2 (compare output with target)
2. Layer 2 backpropagates error to Layer 1
3. Layer 1 backpropagates error to Layer 0
4. Each layer updates its weights

---

## Performance Considerations

### Timing
- **Forward Pass**: 1 clock cycle per timestep
- **Backward Pass**: ~(NUM_INPUTS + 5) clock cycles per backprop
- **Weight Init**: 1 clock cycle per weight

### Resource Usage
- **Memory**: 
  - Weights: `NUM_INPUTS × WEIGHT_WIDTH` bits
  - History: `3 × SPIKE_HISTORY_DEPTH × (NUM_INPUTS + DATA_WIDTH + 1)` bits
- **Combinational Logic**: Multipliers (reused), adders, comparators

### Scalability
- Easily scales to different `NUM_INPUTS` (synaptic connections)
- Adjustable `SPIKE_HISTORY_DEPTH` for longer temporal dependencies
- Can be instantiated multiple times for multi-neuron layers

---

## Future Enhancements

🔧 **Potential Improvements:**
- Adaptive threshold
- Multiple learning rate schedules
- Batch processing for multiple samples
- Weight regularization (L1/L2)
- Momentum-based updates
- Advanced surrogate gradient functions

---

## References

Based on neuromorphic computing principles and Spiking Neural Networks (SNNs):

- LIF Neuron Model
- Backpropagation Through Time (BPTT)
- Surrogate Gradient Methods for SNNs
- On-chip learning for neuromorphic hardware

---

## Contact

For questions or issues, refer to the main project documentation or repository.

**Module Version**: 1.0  
**Last Updated**: January 2026
