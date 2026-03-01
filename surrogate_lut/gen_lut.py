#!/usr/bin/env python3
# =============================================================================
#  gen_lut.py — Surrogate Gradient LUT Generator
#  Project: On-Chip Offline Neuromorphic Computing (FYP)
# =============================================================================
#
#  Generates pre-calculated fast sigmoid surrogate gradient values for
#  all 256 possible 8-bit signed membrane potential values (-128 to +127).
#
#  Fast sigmoid surrogate gradient:
#      h(v) = 1 / (1 + k * |v / V_th|)^2
#
#  where:
#      v    = membrane potential (8-bit signed, range -128 to +127)
#      V_th = threshold (normalisation, set to 128.0)
#      k    = slope steepness factor (default 4.0)
#
#  Output is scaled to 8-bit unsigned fixed-point:
#      0xFF = 1.0 (peak at v=0)
#      0x00 = 0.0 (far from threshold)
#
#  Usage:
#      python3 gen_lut.py          → prints LUT table + Verilog initial block
#      python3 gen_lut.py --mem    → also writes surrogate_lut.mem (hex dump)
# =============================================================================

import sys

# ---- Parameters ----
K       = 4.0    # Steepness of fast sigmoid surrogate
V_TH    = 128.0  # Normalisation denominator (matches 8-bit signed range)
SCALE   = 255.0  # Map [0.0, 1.0] → [0, 255]

def fast_sigmoid_surrogate(v_raw: int, k: float = K) -> int:
    """
    Compute the fast sigmoid surrogate gradient for a given raw 8-bit value.
    v_raw: 0..255 (interpreted as 8-bit signed: 0..127 = positive,
                   128..255 = negative, i.e. -128..-1)
    Returns: 0..255 (8-bit unsigned fixed-point, 255 = 1.0)
    """
    # Reinterpret as signed
    v = v_raw if v_raw < 128 else v_raw - 256
    v_norm = v / V_TH
    grad = 1.0 / (1.0 + k * abs(v_norm)) ** 2
    return int(round(grad * SCALE))


# ---- Compute all 256 entries ----
lut = [fast_sigmoid_surrogate(i) for i in range(256)]

# ---- Print human-readable table ----
print("=" * 60)
print("  Surrogate Gradient LUT  (Fast Sigmoid, 8-bit)")
print(f"  k={K}, V_th={V_TH}, output scale={SCALE}")
print("=" * 60)
print(f"  {'idx':>4}  {'v_mem (signed)':>15}  {'hex':>6}  {'grad (float)':>13}")
print("-" * 60)
for i in range(256):
    v_signed = i if i < 128 else i - 256
    val = lut[i]
    grad_f = val / SCALE
    print(f"  {i:>4}  {v_signed:>15}  0x{val:02X}      {grad_f:.6f}")

print("=" * 60)
print(f"\n  Peak at index 128 (v=0): 0x{lut[128]:02X}")
print(f"  Symmetry check v=+64 (idx=192): 0x{lut[192]:02X}  "
      f"v=-64 (idx=64): 0x{lut[64]:02X}")
print()

# ---- Print Verilog initial block ----
print("// ---- Paste into surrogate_lut_wb.v initial block ----")
print("initial begin")
for i in range(256):
    v_signed = i if i < 128 else i - 256
    print(f"    lut_rom[{i:3d}] = 8'h{lut[i]:02X};  "
          f"// v = {v_signed:4d}  grad ≈ {lut[i]/SCALE:.4f}")
print("end")
print()

# ---- Optionally write .mem file ----
if "--mem" in sys.argv:
    mem_path = "surrogate_lut.mem"
    with open(mem_path, "w") as f:
        for val in lut:
            f.write(f"{val:02X}\n")
    print(f"[INFO] Wrote {mem_path} ({len(lut)} entries)")
