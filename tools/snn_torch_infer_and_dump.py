#!/usr/bin/env python3
"""Run fixed-point-style SNN inference on MNIST and dump hardware-learning traces.

Numpy-only implementation — no torch or torchvision required.
MNIST IDX binary files are downloaded automatically if not already present.

Outputs produced:
- SMEM CSV with columns compatible with the existing learning flow:
  sample,ts,inp_0..inp_783,spike_h0..spike_h199,spike_o0..spike_o9,vmem_h0..vmem_h199,vmem_o0..vmem_o9
- Inference log lines compatible with calc_blame_from_inference_log.py:
  SAMPLE <id> | true=<t> | pred=<p> | PASS/FAIL

Weight format: best_weights_hw.txt style with sections "W1 Weights" and "W2 Weights".
"""

from __future__ import annotations

import argparse
import csv
import gzip
import struct
import urllib.request
from pathlib import Path
from typing import List, Tuple

import numpy as np

INPUT_SIZE = 784
HIDDEN_SIZE = 200
OUTPUT_SIZE = 10

SCALE = 256
THRESHOLD = 256
BETA = 192  # 0.75 * 256

# Primary download URLs for raw MNIST IDX files.
_MNIST_URLS = {
    "train-images-idx3-ubyte.gz": "https://storage.googleapis.com/cvdf-datasets/mnist/train-images-idx3-ubyte.gz",
    "train-labels-idx1-ubyte.gz": "https://storage.googleapis.com/cvdf-datasets/mnist/train-labels-idx1-ubyte.gz",
    "t10k-images-idx3-ubyte.gz":  "https://storage.googleapis.com/cvdf-datasets/mnist/t10k-images-idx3-ubyte.gz",
    "t10k-labels-idx1-ubyte.gz":  "https://storage.googleapis.com/cvdf-datasets/mnist/t10k-labels-idx1-ubyte.gz",
}

# Fallback mirror list (tried in order if first URL fails).
_MNIST_MIRRORS: dict[str, list[str]] = {
    k: [
        _MNIST_URLS[k],
        f"http://yann.lecun.com/exdb/mnist/{k}",
    ]
    for k in _MNIST_URLS
}


def _download_file(filename: str, dest: Path) -> None:
    """Download a gzipped MNIST file trying each mirror until one succeeds."""
    for url in _MNIST_MIRRORS[filename]:
        try:
            print(f"  Downloading {filename} from {url} ...")
            urllib.request.urlretrieve(url, dest)
            print(f"  Saved to {dest}")
            return
        except Exception as exc:
            print(f"  Failed ({exc}), trying next mirror...")
    raise RuntimeError(f"Could not download {filename} from any mirror.")


def load_mnist_images(path: Path) -> np.ndarray:
    with gzip.open(path, "rb") as f:
        magic, n, rows, cols = struct.unpack(">4I", f.read(16))
        assert magic == 0x00000803, f"Bad magic {magic:#x} in {path}"
        return np.frombuffer(f.read(), dtype=np.uint8).reshape(n, rows * cols)


def load_mnist_labels(path: Path) -> np.ndarray:
    with gzip.open(path, "rb") as f:
        magic, n = struct.unpack(">2I", f.read(8))
        assert magic == 0x00000801, f"Bad magic {magic:#x} in {path}"
        return np.frombuffer(f.read(), dtype=np.uint8)


def get_mnist(data_root: Path, train: bool) -> Tuple[np.ndarray, np.ndarray]:
    """Return (images, labels) arrays, downloading IDX files as needed."""
    data_root.mkdir(parents=True, exist_ok=True)
    prefix = "train" if train else "t10k"
    img_gz = f"{prefix}-images-idx3-ubyte.gz"
    lbl_gz = f"{prefix}-labels-idx1-ubyte.gz"

    img_path = data_root / img_gz
    lbl_path = data_root / lbl_gz

    if not img_path.exists():
        _download_file(img_gz, img_path)
    if not lbl_path.exists():
        _download_file(lbl_gz, lbl_path)

    images = load_mnist_images(img_path)
    labels = load_mnist_labels(lbl_path)
    return images, labels


def parse_weight_file(path: Path) -> Tuple[np.ndarray, np.ndarray]:
    w1: List[List[int]] = []
    w2: List[List[int]] = []
    section = None

    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("W1 Weights"):
                section = "w1"
                continue
            if line.startswith("W2 Weights"):
                section = "w2"
                continue
            if set(line) <= {"-"}:
                continue
            if section is None:
                continue

            toks = line.replace(",", " ").split()
            try:
                row = [int(x) for x in toks]
            except ValueError:
                continue

            if section == "w1":
                w1.append(row)
            else:
                w2.append(row)

    if len(w1) != INPUT_SIZE or any(len(r) != HIDDEN_SIZE for r in w1):
        raise ValueError(
            f"W1 shape mismatch; expected {INPUT_SIZE}x{HIDDEN_SIZE}, "
            f"got {len(w1)}x{len(w1[0]) if w1 else 0}"
        )
    if len(w2) != HIDDEN_SIZE or any(len(r) != OUTPUT_SIZE for r in w2):
        raise ValueError(
            f"W2 shape mismatch; expected {HIDDEN_SIZE}x{OUTPUT_SIZE}, "
            f"got {len(w2)}x{len(w2[0]) if w2 else 0}"
        )

    return np.array(w1, dtype=np.int32), np.array(w2, dtype=np.int32)


def make_header() -> List[str]:
    cols = ["sample", "ts"]
    cols += [f"inp_{i}" for i in range(INPUT_SIZE)]
    cols += [f"spike_h{i}" for i in range(HIDDEN_SIZE)]
    cols += [f"spike_o{i}" for i in range(OUTPUT_SIZE)]
    cols += [f"vmem_h{i}" for i in range(HIDDEN_SIZE)]
    cols += [f"vmem_o{i}" for i in range(OUTPUT_SIZE)]
    return cols


def run_sample(
    pixels: np.ndarray,   # shape (784,), values 0..255
    w1: np.ndarray,       # (784, 200) int32
    w2: np.ndarray,       # (200, 10) int32
    timesteps: int,
    rng: np.random.Generator,
) -> Tuple[List[List[int]], int]:
    """Run one sample; return per-timestep dump rows and predicted class."""
    mem1 = np.zeros(HIDDEN_SIZE, dtype=np.int32)
    mem2 = np.zeros(OUTPUT_SIZE, dtype=np.int32)
    out_spike_counts = np.zeros(OUTPUT_SIZE, dtype=np.int32)
    ts_rows: List[List[int]] = []

    for _t in range(timesteps):
        # Poisson encoding: spike if pixel value > uniform random in [0, 254].
        rnd = rng.integers(0, 255, size=INPUT_SIZE, dtype=np.int32)
        inp_out = (pixels > rnd).astype(np.int32)

        # Hidden layer LIF (reset-to-zero).
        mem1 = (mem1 * BETA) >> 8
        mem1 = mem1 + (inp_out @ w1)          # (784,) x (784,200) -> (200,)
        vmem_h = mem1.copy()
        spike_h = (mem1 > THRESHOLD).astype(np.int32)
        mem1 = np.where(spike_h.astype(bool), 0, mem1)

        # Output layer LIF (reset-to-zero).
        mem2 = (mem2 * BETA) >> 8
        mem2 = mem2 + (spike_h @ w2)          # (200,) x (200,10) -> (10,)
        vmem_o = mem2.copy()
        spike_o = (mem2 > THRESHOLD).astype(np.int32)
        out_spike_counts += spike_o
        mem2 = np.where(spike_o.astype(bool), 0, mem2)

        row: List[int] = []
        row += inp_out.tolist()
        row += spike_h.tolist()
        row += spike_o.tolist()
        row += vmem_h.tolist()
        row += vmem_o.tolist()
        ts_rows.append(row)

    pred = int(np.argmax(out_spike_counts))
    return ts_rows, pred


def main() -> None:
    parser = argparse.ArgumentParser(
        description="NumPy SNN MNIST inference + SMEM/log dump (no torch required)"
    )
    parser.add_argument("--weights",     type=Path, required=True,
                        help="Path to best_weights_hw.txt")
    parser.add_argument("--output-csv",  type=Path, required=True,
                        help="Output SMEM CSV for the custom-unit learning flow")
    parser.add_argument("--output-log",  type=Path, required=True,
                        help="Output inference.log summary")
    parser.add_argument("--num-samples", type=int, default=320,
                        help="Number of MNIST samples to run")
    parser.add_argument("--offset", type=int, default=0,
                        help="Start index in MNIST split (default: 0)")
    parser.add_argument("--timesteps",   type=int, default=16,
                        help="Timesteps per sample")
    parser.add_argument("--seed",        type=int, default=42,
                        help="RNG seed for Poisson encoding")
    parser.add_argument("--data-root",   type=Path, default=Path("./data"),
                        help="Directory for MNIST IDX files (downloaded if absent)")
    parser.add_argument("--train",       action="store_true",
                        help="Use MNIST train split (default: test split)")
    args = parser.parse_args()

    print(f"Loading weights from {args.weights} ...")
    w1, w2 = parse_weight_file(args.weights)
    print(f"  W1: {w1.shape}  W2: {w2.shape}")

    print(f"Loading MNIST ({'train' if args.train else 'test'}) from {args.data_root} ...")
    images, labels = get_mnist(args.data_root, args.train)
    if args.offset < 0 or args.offset >= len(images):
        raise ValueError(f"offset out of range: {args.offset} for dataset size {len(images)}")
    total = min(args.num_samples, len(images) - args.offset)
    print(
        f"  Using {total} samples (indices {args.offset}..{args.offset + total - 1}), "
        f"{args.timesteps} timesteps each."
    )

    args.output_csv.parent.mkdir(parents=True, exist_ok=True)
    args.output_log.parent.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(args.seed)
    header = make_header()
    pass_count = 0

    with args.output_csv.open("w", newline="", encoding="utf-8") as cf, \
         args.output_log.open("w", encoding="utf-8") as lf:

        writer = csv.writer(cf)
        writer.writerow(header)

        for local_id in range(total):
            sample_id = args.offset + local_id
            pixels = images[sample_id].astype(np.int32)
            label  = int(labels[sample_id])

            ts_rows, pred = run_sample(pixels, w1, w2, args.timesteps, rng)
            result = "PASS" if pred == label else "FAIL"
            if result == "PASS":
                pass_count += 1

            lf.write(f"SAMPLE {sample_id:4d}  |  true={label}  |  pred={pred}  |  {result}\n")

            for ts, payload in enumerate(ts_rows):
                writer.writerow([sample_id, ts] + payload)

            if (local_id + 1) % 10 == 0 or (local_id + 1) == total:
                acc_so_far = 100.0 * pass_count / (local_id + 1)
                print(f"  [{local_id+1:4d}/{total}]  acc = {acc_so_far:.1f}%")

    acc = (100.0 * pass_count / total) if total else 0.0
    print(f"\nDone.")
    print(f"  Accuracy   : {pass_count}/{total} = {acc:.2f}%")
    print(f"  SMEM CSV   -> {args.output_csv}")
    print(f"  Infer log  -> {args.output_log}")


if __name__ == "__main__":
    main()
