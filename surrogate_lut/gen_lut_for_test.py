#!/usr/bin/env python3
"""
gen_lut_for_test.py — Generate surrogate_lut.hex for Verilog testbench

The surrogate gradient function is:
    h(v) = 1 / (1 + k * |v / 128|)^2,  where k=4

This pre-calculates all 256 values (representing -128 to +127) and outputs
them as an 8-bit unsigned hex file suitable for loading with $readmemh.

LUT Index Mapping (as 8-bit unsigned):
    Index   0  → v_mem =    0  (peak: h = 1.0)
    Index   1  → v_mem =   +1
    ...
    Index 127  → v_mem = +127
    Index 128  → v_mem = -128
    ...
    Index 255  → v_mem =   -1

Output Format:
    surrogate_lut.hex: one 8-bit value per line, hex format (0x00 - 0xFF)
"""

import numpy as np

def surrogate_gradient(v):
    """
    Compute surrogate gradient: h(v) = 1 / (1 + k*|v/128|)^2
    
    Args:
        v: signed value (-128 to +127)
    
    Returns:
        h(v) as float (0.0 to 1.0), converted to 8-bit unsigned (0x00 to 0xFF)
    """
    k = 4.0
    normalized_v = v / 128.0
    denominator = 1.0 + k * (abs(normalized_v) ** 2)
    h = 1.0 / (denominator ** 2)
    
    # Convert to 8-bit unsigned: peak at 1.0 → 0xFF
    return int(round(h * 0xFF))


def main():
    lut = []
    
    for index in range(256):
        # Map 8-bit unsigned index to signed -128..+127
        if index < 128:
            v_signed = index  # 0..127
        else:
            v_signed = index - 256  # 128..255 → -128..-1
        
        h_uint8 = surrogate_gradient(v_signed)
        lut.append(h_uint8)
    
    # Write hex file
    with open('surrogate_lut.hex', 'w') as f:
        for i, value in enumerate(lut):
            f.write(f"{value:02x}\n")
    
    # Print some values for debugging
    print("Surrogate LUT values (sample):")
    print(f"  Index   0 (v=   0): 0x{lut[0]:02x}")
    print(f"  Index   5 (v=  +5): 0x{lut[5]:02x}")
    print(f"  Index  64 (v= +64): 0x{lut[64]:02x}")
    print(f"  Index 128 (v=-128): 0x{lut[128]:02x}")
    print(f"  Index 255 (v=  -1): 0x{lut[255]:02x}")
    print(f"\nWrote 256 values to surrogate_lut.hex")


if __name__ == '__main__':
    main()
