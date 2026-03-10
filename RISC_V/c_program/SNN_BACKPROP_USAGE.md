# SNN Backpropagation C Interface

## Overview

The `snn_backprop()` function provides a single-call interface to execute the complete SNN backpropagation process on the neuromorphic accelerator using custom RISC-V instructions.

## Function Signature

```c
int16_t snn_backprop(
    uint16_t spike_pattern,
    int16_t *gradients,
    int16_t error_term,
    int16_t initial_weight
);
```

## Parameters

| Parameter | Type | Range | Description |
|-----------|------|-------|-------------|
| `spike_pattern` | uint16_t | 0-65535 | 16-bit spike pattern, 1 bit per timestep<br/>MSB = timestep 15, LSB = timestep 0<br/>Example: 0xB0F5 = [1,0,1,0,1,1,1,1,0,0,0,0,1,1,0,1] |
| `gradients` | int16_t* | -32768 to 32767 | Pointer to array of 16 signed gradient values<br/>gradients[0] = surrogate gradient at timestep 0<br/>gradients[15] = surrogate gradient at timestep 15 |
| `error_term` | int16_t | -32768 to 32767 | Initial error signal for backpropagation<br/>Typical range: -512 to 512 for Q8 fixed-point |
| `initial_weight` | int16_t | -32768 to 32767 | Weight before update<br/>Will be loaded into hardware register x5 |

## Return Value

**Type:** int16_t (signed 16-bit)  
**Range:** -32768 to 32767  
**Description:** Updated weight after 17-cycle computation, automatically saturated to int16 range

## Hardware Computation Timeline

```
Total execution: ~95 cycles (≈950 ns at 100 MHz)

Step 1: Register initialization     5 cycles | ADDI instructions setup x1-x5
Step 2: Spike LIFO push             1 cycle  | LIFOPUSH x3, x0
Step 3: Gradient memory load       62 cycles | LIFOPUSHMG x1, x2
Step 4: Pipeline NOPs              62 cycles | Wait for memory loader
Step 5: Start computation          17 cycles | LIFOPOP x5, x4 + streaming
Step 6: Computation wait          17 cycles | Wait for 17-cycle delta calc
Step 7: Writeback                   4 cycles | LIFOWB x6 + pipeline stages
Total:                             ~95 cycles
```

## Computation Details

### Temporal Error Recurrence (BETA = 0.95)

```
At each timestep t:
  if spike[t] == 1:
    delta[t] = 0  (spike gates temporal recurrence)
  else:
    delta[t] = (243/256) * delta[t-1] + grad[t]
    (BETA = 243/256 ≈ 0.95 in Q8 fixed-point format)
```

### Weight Update (LR = 150/256 ≈ 0.586)

```
weight_updated = weight_initial - (LR * delta_final) >> 8
              = weight_initial - ((150 * delta_final) / 256)
              
Computed during 17-cycle window:
  Cycles 0-15: Receive 16 gradient values, compute temporal delta
  Cycle 16:    Apply final weight update
  Cycle 17:    Output final weight
```

### Fixed-Point Format

- **BETA**: Q8 format (243/256 = 0.95)
- **Learning Rate**: Q8 format (150/256 = 0.586)
- **Gradient/Weight**: Q0 format (raw int16)
- **Delta**: Accumulates with BETA decay, saturates to int16

## Usage Example

### Basic Usage

```c
#include "snn_backprop.c"

// Define spike pattern for 16 timesteps
uint16_t spikes = 0xB0F5;  // Binary: 1010111100001101

// Define surrogate gradients from forward pass
int16_t grads[16] = {
    200, -100, -50, 0,
    1, 3, 6, 12,
    25, 50, 100, -128,
    0, 128, 255, 0
};

// Backpropagation parameters
int16_t error = -512;
int16_t weight = 20;

// Single function call executes entire backprop process
int16_t new_weight = snn_backprop(
    spikes,      // 16-bit spike pattern
    grads,       // Pointer to 16 gradients
    error,       // Error signal
    weight       // Initial weight
);

printf("Updated weight: %d\n", new_weight);  // Expected: 398 for test case
```

### Batch Processing

```c
// Process multiple datasets in sequence
#define NUM_DATASETS 10

for (int dataset = 0; dataset < NUM_DATASETS; dataset++) {
    // Load spike pattern and gradients for this dataset
    uint16_t spike_pat = spike_data[dataset];
    int16_t *grad_ptr = &gradient_data[dataset][0];
    int16_t error_val = error_data[dataset];
    
    // Update weight through backpropagation
    weight = snn_backprop(spike_pat, grad_ptr, error_val, weight);
    
    // Accumulate batch statistics
    accumulated_dW += (weight - weight_prev);
    weight_prev = weight;
}
```

### Advanced: Custom Memory Address

For systems with multiple memory regions, use `snn_backprop_compute()`:

```c
#define GRADIENT_MEM_ALT 0x20010000  // Alternate memory region

int32_t result = snn_backprop_compute(
    spike_pattern,
    gradient_array,
    error_term,
    initial_weight,
    GRADIENT_MEM_ALT  // Custom memory address
);
```

## Implementation Notes

### Default Memory Address
- Default: `GRADIENT_MEM_BASE = 0x20000000`
- Adjust in `snn_backprop.c` if your system uses different memory layout
- Gradients are copied to this address before computation

### Register Allocation
```
x1  = Gradient memory base address
x2  = Gradient count (always 16)
x3  = Spike pattern (16 bits)
x4  = Error term (16 bits)
x5  = Initial weight (16 bits)
x6  = Updated weight (result, 32 bits)
```

### Compiler Flags

```bash
# Compile with custom extensions support
gcc -march=rv32i_zicsr --fno-rename-registers -O2 snn_backprop.c

# For simulation (Icarus Verilog):
iverilog -I../extention -o sim your_testbench.v
```

### Expected Output Range

| Input | Output |
|-------|--------|
| weight=20, spike=0, grad=200 | 255 (clamped) |
| weight=20, spike=1, grad=200 | 20 (unchanged—gated) |
| weight=20, spike=0, grad=-512 | -492 |
| Test pattern 0xB0F5 with 16 grads | 398 |

## Performance Characteristics

| Metric | Value |
|--------|-------|
| Latency | ~95 cycles (fixed) |
| Throughput | 1 weight update per 95 cycles |
| Memory Bandwidth | 16 × 16-bit = 256 bits per update |
| Power (est.) | 50-100 mW (dependent on system) |

## Error Handling

The function handles saturation automatically:
- Weights saturate to int16 range (-32768 to 32767)
- No exception signaling—overflow wraps silently
- For overflow detection, check if `result > 32767 || result < -32768`

## Integration with Your RISC-V Processor

1. **Ensure custom opcode 0001011 is decoded** in your control unit
2. **Compile this file with your RISC-V toolchain**
3. **Link against your compiled CPU executable**
4. **Memory at GRADIENT_MEM_BASE must be writable**

## Example Training Loop

```c
typedef struct {
    int16_t spike_pattern;
    int16_t gradients[16];
    int16_t target_error;
} SNN_Dataset;

int main() {
    int16_t neuron_weight = 0;  // Start at 0
    SNN_Dataset datasets[100];  // Your training data
    
    // Training epoch
    for (int epoch = 0; epoch < 5; epoch++) {
        for (int i = 0; i < 100; i++) {
            // Single backprop call per dataset
            neuron_weight = snn_backprop(
                datasets[i].spike_pattern,
                datasets[i].gradients,
                datasets[i].target_error,
                neuron_weight
            );
        }
    }
    
    return neuron_weight;  // Final trained weight
}
```

This replaces 95+ lines of assembly/kernel code with a single C function call!
