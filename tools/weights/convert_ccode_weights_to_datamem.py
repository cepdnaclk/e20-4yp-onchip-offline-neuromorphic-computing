#!/usr/bin/env python3
"""
convert_ccode_weights_to_datamem.py
====================================
Converts C-code generated weight file to data_mem_mnist.mem format
for the MNIST SNN hardware testbench.

Supports two weight file formats:

  Format A — backpropD.C  (save_weights_txt):
    W1 Weights (784 x 200):
    <784 rows, 200 space-separated integers>
    -------------------------------------
    W2 Weights (200 x 10):
    <200 rows, 10 space-separated integers>

  Format B — legacy format:
    --- Layer 1 Weights (W1) [784x200] ---
    <rows>
    --- Layer 2 Weights (W2) [200x10] ---
    <rows>

Note: W1 is stored as [IN x H] (row = one input neuron's weights to all hidden).
      W2 is stored as [H x OUT] (row = one hidden neuron's weights to all output).
      Internally both are transposed to [OUT x IN] as required by Neuron_Mapper.

Output: data_mem_mnist.mem — one byte per line, lowercase hex, no prefix.
        Drop-in replacement for the file the testbench reads.

int_scale parameter (--int-scale):
    Physical float weight = raw_integer / int_scale
    backpropD.C uses  #define SCALE 256  → --int-scale 256  (default)
    If you change SCALE in the C code, change --int-scale accordingly.
    Example: SCALE=20 → --int-scale 20

Hardware architecture is inferred from the weight file dimensions.
Current testbench default: 784→16→10  (N_HIDDEN_DUMP=16).
To use HIDDEN_SIZE=200 from backpropD.C, set N_HIDDEN_DUMP=200 in the
testbench parameter section and rebuild data_mem_mnist.mem with this script.

Usage:
    python convert_ccode_weights_to_datamem.py \\
        updated_weights.txt \\
        -o data_mem_mnist.mem \\
        --int-scale 256
"""

import argparse
import os
import sys

# ── locate model_compiler ───────────────────────────────────────────────────
_HERE = os.path.dirname(os.path.abspath(__file__))
_MODELS_DIR = os.path.join(_HERE, '..', '..', 'models')
sys.path.insert(0, os.path.abspath(_MODELS_DIR))

try:
    from model_compiler.neuron_mapper.core import Neuron_Mapper
    from model_compiler.neuron_mapper.utils import Neuron_LIF
except ImportError as e:
    sys.exit(f"ERROR: cannot import model_compiler from {_MODELS_DIR}: {e}\n"
             "Make sure models/model_compiler/ exists and is intact.")


# ── weight file parser ───────────────────────────────────────────────────────
def parse_weight_file(path):
    """
    Parse C-code weight dump file.
    Supports two formats:
      Format A (backpropD.C save_weights_txt):
        'W1 Weights (N x M):' header, separator line '-----', 'W2 Weights (N x M):'
      Format B (legacy):
        '--- Layer 1 Weights (W1) [NxM] ---' header

    Returns (W1_raw, W2_raw) where:
      W1_raw[i][j] = weight from input i  to hidden j   shape [IN  x H]
      W2_raw[i][j] = weight from hidden i to output j   shape [H   x OUT]
    All values are raw integers as written by the C code.
    """
    W1, W2 = [], []
    current = None
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            # Detect W1 header (both format A and B)
            if (line.lower().startswith('w1 weights') or
                    (line.startswith('---') and 'Layer 1' in line)):
                current = W1
                continue
            # Detect W2 header (both format A and B)
            if (line.lower().startswith('w2 weights') or
                    (line.startswith('---') and 'Layer 2' in line)):
                current = W2
                continue
            # Skip separator lines (all dashes, e.g. "-----...")
            if set(line.replace(' ', '')) <= {'-'}:
                continue
            # Skip comment lines
            if line.startswith('#'):
                continue
            if current is not None:
                try:
                    vals = list(map(int, line.split()))
                except ValueError:
                    sys.exit(f"ERROR: non-integer value on line {lineno} of {path}")
                if vals:
                    current.append(vals)
    if not W1:
        sys.exit(f"ERROR: no Layer 1 / W1 weights found in {path}")
    if not W2:
        sys.exit(f"ERROR: no Layer 2 / W2 weights found in {path}")
    return W1, W2


def _auto_scale(W1_raw, W2_raw):
    """Return a scale such that max|weight| ≈ 1.0 (works for Q28 range)."""
    all_vals = [abs(v) for row in W1_raw for v in row] + \
               [abs(v) for row in W2_raw for v in row]
    max_abs = max(all_vals) if all_vals else 1.0
    return float(max_abs) if max_abs > 0 else 1.0


def convert(weight_file, output_file, int_scale,
            threshold, decay_mode, reset_mode):
    """Full conversion pipeline: C weight file → data_mem.mem."""

    W1_raw, W2_raw = parse_weight_file(weight_file)

    # Auto-detect scale if not provided — default to 256 matching C code SCALE
    if int_scale is None:
        int_scale = 256.0
        print(f"Using default int_scale = {int_scale}  (matches #define SCALE 256 in backpropD.C)")
        print("  Override with --int-scale if SCALE differs in your C code.")

    # Infer dimensions from the file
    in_neurons  = len(W1_raw)       # rows  = 784 input neurons
    h_neurons   = len(W1_raw[0])    # cols  = H   hidden neurons
    h2_check    = len(W2_raw)       # rows  = H   hidden neurons  (must match)
    out_neurons = len(W2_raw[0])    # cols  = 10  output neurons

    if h_neurons != h2_check:
        sys.exit(f"ERROR: W1 has {h_neurons} hidden cols but W2 has {h2_check} rows")

    print(f"Architecture detected: {in_neurons} → {h_neurons} → {out_neurons}")
    print(f"int_scale = {int_scale}  (float = int / {int_scale})")

    # Convert integers → floats
    W1_float = [[v / int_scale for v in row] for row in W1_raw]
    W2_float = [[v / int_scale for v in row] for row in W2_raw]

    # Transpose to [H × IN] and [OUT × H] as required by Neuron_Mapper
    W1_for_mapper = [[W1_float[j][i] for j in range(in_neurons)]
                     for i in range(h_neurons)]
    W2_for_mapper = [[W2_float[j][i] for j in range(h_neurons)]
                     for i in range(out_neurons)]

    # Validate weight magnitude (warn if likely wrong scale)
    flat_w = [abs(w) for row in W1_for_mapper for w in row] + \
             [abs(w) for row in W2_for_mapper for w in row]
    max_w = max(flat_w)

    # Q28 fixed-point can represent floats up to ±(2^31 / 2^28) = ±8.0.
    # If weights exceed this, Neuron_Mapper will raise an overflow error.
    # The C trainer must clamp weights before saving (W1_CLAMP / W2_CLAMP).
    # Do NOT auto-rescale here — that silently changes the threshold and
    # makes training and inference use inconsistent dynamics.
    MAX_Q28 = 7.999
    if max_w > MAX_Q28:
        sys.exit(
            f"ERROR: max|float weight| = {max_w:.4f} exceeds Q4.28 hardware limit (±{MAX_Q28}).\n"
            f"  The C trainer must clamp weights before saving.\n"
            f"  Check W1_CLAMP / W2_CLAMP in the C source and rerun training.\n"
            f"  Expected: max|float| = max_int_clamp / int_scale  ≤ 7.999\n"
            f"  Got:      int_scale = {int_scale},  max|weight_int| = {int(max_w * int_scale)}"
        )
    elif max_w < 0.001:
        print(f"WARNING: max |weight| = {max_w:.6f}  — weights near zero; "
              f"network will not fire.  Consider decreasing --int-scale.")

    # Build neuron_layers / neuron_weights for Neuron_Mapper
    neuron_layers = {
        "Input": {
            "decay_mode":  decay_mode,
            "threshold":   threshold,
            "neurons":     in_neurons,
            "reset_mode":  reset_mode,
            "is_virtual":  True,
        },
        "Layer1": {
            "decay_mode": decay_mode,
            "threshold":  threshold,
            "neurons":    h_neurons,
            "reset_mode": reset_mode,
        },
        "Layer2": {
            "decay_mode": decay_mode,
            "threshold":  threshold,
            "neurons":    out_neurons,
            "reset_mode": reset_mode,
        },
    }
    neuron_weights = {
        "Input-Layer1":  {"weights": W1_for_mapper},
        "Layer1-Layer2": {"weights": W2_for_mapper},
    }

    print("Running Neuron_Mapper (map + generate_init) …")
    mapper = Neuron_Mapper(neuron_layers, neuron_weights)
    mapper.map()

    # Write one byte per line (same format as the original data_mem_mnist.mem)
    byte_count = 0
    with open(output_file, 'w') as out:
        for packet in mapper.generate_init():
            if isinstance(packet, (list, tuple)):
                for byte_hex in packet:
                    out.write(f"{byte_hex}\n")
                    byte_count += 1
            else:
                # Shouldn't happen, but handle gracefully
                out.write(f"{packet}\n")
                byte_count += 1

    print(f"Written {byte_count} bytes → {output_file}")


# ── CLI ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description='Convert C-code weight file to data_mem_mnist.mem')
    parser.add_argument('weight_file', help='C-code weight dump (e.g. updated_weights.txt)')
    parser.add_argument('-o', '--output', default='data_mem_mnist.mem',
                        help='Output .mem file (default: data_mem_mnist.mem)')
    parser.add_argument('--int-scale', type=float, default=None,
                        help='Divide raw integers by this to get float weights. '
                             'Default: match C code SCALE (256). '
                             'Change if SCALE is different in backpropD.C. '
                             'Example: --int-scale 256 for #define SCALE 256.')
    parser.add_argument('--threshold', type=float, default=1.0,
                        help='LIF threshold (default: 1.0, must match training)')
    parser.add_argument('--decay', choices=['lif2', 'lif4', 'lif8', 'lif24'],
                        default='lif2',
                        help='Decay mode (default: lif2 = β=0.5). '
                             'Use lif24 for C-code model (β=0.75).')
    parser.add_argument('--reset-mode', choices=['zero', 'vtd', 'no'],
                        default='zero',
                        help='Spike reset mode (default: zero = hardware RESET_ZERO). '
                             'zero=reset to 0, vtd=subtract threshold, no=no reset.')
    args = parser.parse_args()

    decay_map = {
        'lif2':  Neuron_LIF.DECAY_MODE_LIF_2,
        'lif4':  Neuron_LIF.DECAY_MODE_LIF_4,
        'lif8':  Neuron_LIF.DECAY_MODE_LIF_8,
        'lif24': Neuron_LIF.DECAY_MODE_LIF_2_4,
    }
    reset_map = {
        'zero': Neuron_LIF.RESET_MODE_ZERO,
        'vtd':  Neuron_LIF.RESET_MODE_VTD,
        'no':   Neuron_LIF.RESET_MODE_NO,
    }
    convert(
        weight_file=args.weight_file,
        output_file=args.output,
        int_scale=args.int_scale,     # None → auto-detect inside convert()
        threshold=args.threshold,
        decay_mode=decay_map[args.decay],
        reset_mode=reset_map[args.reset_mode],
    )


if __name__ == '__main__':
    main()
