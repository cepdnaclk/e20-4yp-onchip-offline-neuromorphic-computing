#!/usr/bin/env python3
"""
generate_spike_mem.py
======================
Converts MNIST test images into spike_mem.mem for the neuron accelerator testbench.

Spike encoding: RATE CODING
  Each pixel value (0–255) produces spikes spread evenly over T timesteps.
  Higher pixel value → more spikes → higher firing rate.

Spike packet format (11-bit, matches packet_width=11 in neuron_accelerator.v):
  bits [10:5] = cluster_id      (pixel_index // 32)
  bits  [4:0] = neuron_in_cluster (pixel_index %  32)

Memory layout — spike_mem[sample × T × 784 + t × 784 + neuron]:
  For each sample:
    For each timestep t = 0 .. T-1:
      For each input neuron n = 0 .. 783:
        If neuron n fires at timestep t → write 11-bit packet
        Otherwise                       → write 0x7FF  (sentinel / no-spike)

  The testbench computes the address as:
    spike_packet_index = input_neuron_index
                       + time_step_index  * input_neurons
                       + input_index      * time_step_window * input_neurons

test_labels.txt: one integer label per line (ground truth for accuracy check).

Usage
    # 100 samples, 25 timesteps  (recommended starting point)
    python generate_spike_mem.py --samples 100 --timesteps 25

    # 1000 samples
    python generate_spike_mem.py --samples 1000 --timesteps 25

    # From raw MNIST IDX files
    python generate_spike_mem.py --samples 500 --timesteps 25 \\
        --mnist_images /path/to/t10k-images-idx3-ubyte \\
        --mnist_labels /path/to/t10k-labels-idx1-ubyte
"""

import argparse
import struct
import random
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
NPC          = 32       # neurons per cluster
INPUT_SIZE   = 784      # 28 × 28 MNIST pixels
NO_SPIKE     = 0x7FF    # sentinel: this neuron does not fire this timestep


# ─────────────────────────────────────────────────────────────────────────────
# SPIKE ENCODING
# ─────────────────────────────────────────────────────────────────────────────

def rate_encode(pixel_values, timesteps, threshold=0.05):
    """
    Rate encode one image.

    Args:
        pixel_values : list/array of floats in [0.0, 1.0], length INPUT_SIZE
        timesteps    : number of time steps T
        threshold    : minimum normalised value to produce any spike (noise gate)

    Returns:
        firing[t] = set of neuron indices that fire at timestep t  (list of sets)
    """
    firing = [set() for _ in range(timesteps)]
    for nid, val in enumerate(pixel_values):
        if val < threshold:
            continue
        n_spikes = max(1, round(val * timesteps))
        if n_spikes >= timesteps:
            for t in range(timesteps):
                firing[t].add(nid)
        else:
            step = timesteps / n_spikes
            for k in range(n_spikes):
                t = int(k * step)
                firing[t].add(nid)
    return firing


def encode_packet(neuron_id):
    """Encode neuron_id into an 11-bit spike packet."""
    cluster_id        = (neuron_id // NPC) & 0x3F
    neuron_in_cluster = (neuron_id  % NPC) & 0x1F
    return (cluster_id << 5) | neuron_in_cluster


# ─────────────────────────────────────────────────────────────────────────────
# MNIST LOADERS  (tries sklearn → tensorflow → pytorch → raw IDX → dummy)
# ─────────────────────────────────────────────────────────────────────────────

def load_mnist_sklearn(num_samples):
    try:
        from sklearn.datasets import fetch_openml
        print("[mnist] Loading via scikit-learn (may take ~30s first time) ...")
        mnist = fetch_openml('mnist_784', version=1, as_frame=False, parser='auto')
        X = mnist.data.astype('float32') / 255.0
        y = mnist.target.astype('int32')
        X_test, y_test = X[-10000:], y[-10000:]
        n = min(num_samples, len(X_test))
        return X_test[:n], y_test[:n].tolist()
    except Exception:
        return None, None


def load_mnist_tf(num_samples):
    try:
        import tensorflow as tf  # type: ignore
        print("[mnist] Loading via TensorFlow ...")
        (_, _), (X_test, y_test) = tf.keras.datasets.mnist.load_data()
        X_test = X_test.reshape(-1, 784).astype('float32') / 255.0
        n = min(num_samples, len(X_test))
        return X_test[:n], y_test[:n].tolist()
    except Exception:
        return None, None


def load_mnist_torch(num_samples):
    try:
        import torch            # type: ignore
        import torchvision      # type: ignore
        print("[mnist] Loading via PyTorch/torchvision ...")
        ds = torchvision.datasets.MNIST(root='/tmp/mnist', train=False,
                                        download=True,
                                        transform=torchvision.transforms.ToTensor())
        X, y = [], []
        for i, (img, label) in enumerate(ds):
            if i >= num_samples:
                break
            X.append(img.numpy().flatten().tolist())
            y.append(int(label))
        return X, y
    except Exception:
        return None, None


def load_mnist_idx(image_file, label_file, num_samples):
    """Load from raw IDX binary files (optionally .gz)."""
    import gzip

    def open_idx(path):
        return gzip.open(path, 'rb') if str(path).endswith('.gz') else open(path, 'rb')

    with open_idx(image_file) as f:
        magic, n, rows, cols = struct.unpack('>IIII', f.read(16))
        raw = f.read()
    import array as _arr
    data = list(_arr.array('B', raw))
    total = rows * cols
    X = [[data[i * total + j] / 255.0 for j in range(total)]
         for i in range(min(n, num_samples))]

    with open_idx(label_file) as f:
        struct.unpack('>II', f.read(8))
        raw = f.read()
    y = list(_arr.array('B', raw))[:min(n, num_samples)]
    return X, y


def make_dummy(num_samples, seed=42):
    """Fallback: random pixel data with random labels."""
    print("[mnist] WARNING: using RANDOM dummy data — install sklearn/tf/torch for real MNIST")
    rng = random.Random(seed)
    X = [[rng.random() for _ in range(INPUT_SIZE)] for _ in range(num_samples)]
    y = [rng.randint(0, 9) for _ in range(num_samples)]
    return X, y


# ─────────────────────────────────────────────────────────────────────────────
# MAIN GENERATOR
# ─────────────────────────────────────────────────────────────────────────────

def generate_spike_mem(X, y, timesteps, output_file, labels_file, threshold=0.05):
    """
    Write spike_mem.mem and test_labels.txt.

    spike_mem.mem layout (one 3-hex-digit entry per line):
      For each sample s:
        For each timestep t:
          For each neuron n in 0..INPUT_SIZE-1:
            fires → 3-digit hex packet
            silent → 7FF
    """
    num_samples = len(X)
    total_entries = num_samples * timesteps * INPUT_SIZE

    print(f"\n[spike_gen] Encoding {num_samples} samples × {timesteps} timesteps "
          f"× {INPUT_SIZE} neurons = {total_entries:,} entries")

    # Pre-compute firing sets for all samples
    firing_all = []
    for s, pixels in enumerate(X):
        # Normalise if needed
        pix = [v / 255.0 if v > 1.5 else float(v) for v in pixels]
        firing_all.append(rate_encode(pix, timesteps, threshold))
        if (s + 1) % 200 == 0:
            print(f"  Encoded {s + 1}/{num_samples} samples ...")

    Path(output_file).parent.mkdir(parents=True, exist_ok=True)

    total_spikes = 0
    with open(output_file, 'w') as f:
        for s in range(num_samples):
            for t in range(timesteps):
                for nid in range(INPUT_SIZE):
                    if nid in firing_all[s][t]:
                        f.write(f"{encode_packet(nid):03X}\n")
                        total_spikes += 1
                    else:
                        f.write(f"{NO_SPIKE:03X}\n")

    Path(labels_file).parent.mkdir(parents=True, exist_ok=True)
    with open(labels_file, 'w') as f:
        for label in y:
            f.write(f"{label}\n")

    print(f"\n[spike_gen] Done.")
    print(f"  spike entries written : {total_entries:,}")
    print(f"  spike events          : {total_spikes:,}  "
          f"({100.0 * total_spikes / total_entries:.1f}% active)")
    print(f"  avg spikes / sample   : {total_spikes / num_samples:.1f}")
    print(f"  spike_mem.mem  → {output_file}")
    print(f"  test_labels.txt → {labels_file}")


# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

def main():
    repo_root    = Path(__file__).resolve().parent.parent.parent
    default_mem  = str(repo_root / 'inference_accelarator' / 'neuron_accelerator'
                       / 'spike_mem.mem')
    default_lbl  = str(repo_root / 'inference_accelarator' / 'neuron_accelerator'
                       / 'test_labels.txt')

    p = argparse.ArgumentParser(description="Generate spike_mem.mem from MNIST")
    p.add_argument('--samples',       type=int,   default=100,
                   help='Number of MNIST test samples (default: 100)')
    p.add_argument('--timesteps',     type=int,   default=16,
                   help='Timesteps for rate encoding (default: 16)')
    p.add_argument('--threshold',     type=float, default=0.05,
                   help='Minimum pixel value to generate any spike (default: 0.05)')
    p.add_argument('--output',        default=default_mem,
                   help='Output spike_mem.mem path')
    p.add_argument('--labels',        default=default_lbl,
                   help='Output test_labels.txt path')
    p.add_argument('--mnist_images',  default=None,
                   help='Path to raw MNIST t10k-images IDX file (optional)')
    p.add_argument('--mnist_labels',  default=None,
                   help='Path to raw MNIST t10k-labels IDX file (optional)')
    p.add_argument('--seed',          type=int,   default=42,
                   help='Random seed for dummy fallback (default: 42)')
    args = p.parse_args()

    print("=" * 65)
    print("  Neuron Accelerator — MNIST → spike_mem.mem Generator")
    print("=" * 65)
    print(f"  Samples   : {args.samples}")
    print(f"  Timesteps : {args.timesteps}")
    print(f"  Threshold : {args.threshold}")
    print()

    # Load MNIST
    X, y = None, None

    if args.mnist_images and args.mnist_labels:
        print("[mnist] Loading from raw IDX files ...")
        X, y = load_mnist_idx(args.mnist_images, args.mnist_labels, args.samples)
        print(f"[mnist] Loaded {len(X)} samples")

    if X is None:
        X, y = load_mnist_sklearn(args.samples)
    if X is None:
        X, y = load_mnist_tf(args.samples)
    if X is None:
        X, y = load_mnist_torch(args.samples)
    if X is None:
        X, y = make_dummy(args.samples, args.seed)

    if X is not None:
        print(f"[mnist] {len(X)} samples ready")

    X = [list(row) for row in X]   # ensure list-of-lists

    generate_spike_mem(X, y, args.timesteps, args.output, args.labels, args.threshold)

    print()
    print("[next steps]")
    print("  1. Run: python tools/weights/convert_weights_to_datamem.py")
    print("  2. Compile testbench:")
    print("       cd inference_accelarator/neuron_accelerator")
    print("       iverilog -g2012 -o sim.vvp mnist_inference_tb.v")
    print(f"  3. Run simulation:")
    print(f"       vvp sim.vvp +time_step_window={args.timesteps} "
          f"+input_neurons={INPUT_SIZE} +nn_layers=2 +input_count={args.samples}")
    print("  4. Decode results:")
    print("       python tools/decoder/decode_output.py")
    print("=" * 65)


if __name__ == '__main__':
    main()
