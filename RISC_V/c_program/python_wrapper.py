#!/usr/bin/env python3
"""
Python wrapper example for SNN backpropagation C function
Demonstrates how to call the hardware-accelerated backprop from Python
"""

import ctypes
import numpy as np
from ctypes import c_uint16, c_int16, POINTER, c_int32

# Load the compiled C library
# First compile snn_backprop.c:
#   riscv32-unknown-elf-gcc -march=rv32i -O2 -c snn_backprop.c -o snn_backprop.o
#   riscv32-unknown-elf-gcc -shared -o libsnn.so snn_backprop.o

try:
    snn_lib = ctypes.CDLL('./libsnn.so')
except OSError:
    print("Warning: libsnn.so not found. Install compiled library first:")
    print("  riscv32-unknown-elf-gcc -march=rv32i -O2 -c snn_backprop.c")
    print("  riscv32-unknown-elf-gcc -shared -o libsnn.so snn_backprop.o")
    snn_lib = None


def snn_backprop(spike_pattern, gradients, error_term, initial_weight):
    """
    Single-call SNN backpropagation function
    
    Args:
        spike_pattern (int): 16-bit pattern, 1 bit per timestep
        gradients (list or np.array): 16 gradient values (int16)
        error_term (int): Error signal (int16)
        initial_weight (int): Weight before update (int16)
    
    Returns:
        int: Updated weight after 95-cycle hardware computation
    
    Example:
        >>> spikes = 0xB0F5
        >>> grads = [200, -100, -50, 0, 1, 3, 6, 12, 25, 50, 100, -128, 0, 128, 255, 0]
        >>> error = -512
        >>> weight = 20
        >>> new_weight = snn_backprop(spikes, grads, error, weight)
        >>> print(f"Updated weight: {new_weight}")  # Output: 398
    """
    
    if snn_lib is None:
        raise RuntimeError("SNN library not loaded. Compile snn_backprop.c first.")
    
    # Get C function reference
    c_snn_backprop = snn_lib.snn_backprop
    c_snn_backprop.argtypes = [c_uint16, POINTER(c_int16), c_int16, c_int16]
    c_snn_backprop.restype = c_int16
    
    # Convert gradients to C array
    grad_array = (c_int16 * 16)(*gradients)
    
    # Call hardware-accelerated function
    result = c_snn_backprop(
        c_uint16(spike_pattern & 0xFFFF),
        grad_array,
        c_int16(error_term),
        c_int16(initial_weight)
    )
    
    return int(result)


if __name__ == "__main__":
    # Example: Test case from hardware simulation
    print("=" * 60)
    print("SNN Backpropagation Hardware Accelerator Test")
    print("=" * 60)
    
    # Test parameters
    spike_pattern = 0xB0F5  # Binary: [1,0,1,0,1,1,1,1,0,0,0,0,1,1,0,1]
    gradients = [200, -100, -50, 0, 1, 3, 6, 12, 25, 50, 100, -128, 0, 128, 255, 0]
    error = -512
    weight = 20
    
    print(f"\nInput Parameters:")
    print(f"  Spike pattern:   0x{spike_pattern:04X} = {bin(spike_pattern)}")
    print(f"  Gradient count:  {len(gradients)}")
    print(f"  Error term:      {error}")
    print(f"  Initial weight:  {weight}")
    
    if snn_lib:
        # Call single function
        result = snn_backprop(spike_pattern, gradients, error, weight)
        print(f"\nHardware Result:   {result}")
        print(f"Expected Result:   398")
        print(f"Match: {result == 398}")
    else:
        print("\n(Library not loaded - install compiled version to test)")
    
    print("\n" + "=" * 60)
    print("Execution Timeline:")
    print("=" * 60)
    print("""
    1. Register setup         5 cycles  | x1=grad_addr, x2=16, x3=spike, x4=error, x5=weight
    2. LIFOPUSH spike        1 cycle   | Push 0xB0F5 to spike LIFO
    3. LIFOPUSHMG gradient   62 cycles | Load 16 gradients from memory
    4. Wait for loader       62 cycles | NOPs
    5. LIFOPOP+compute       17 cycles | Load weight, start streaming
    6. Wait for finish       17 cycles | NOPs for computation
    7. LIFOWB writeback      4 cycles  | Write result to x6
    ────────────────────────────────────
    Total                    ~95 cycles ≈ 950 ns @ 100 MHz
    """)
