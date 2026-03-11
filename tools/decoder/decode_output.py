#!/usr/bin/env python3
"""
decode_output.py
=================
Decodes the simulation output.txt and computes MNIST inference accuracy.

output.txt format (written by mnist_inference_tb.v):
    {sample_index}:{packet_hex}
  e.g.:
    0:3e0
    0:3e3
    1:3e5

Each packet is an 11-bit value:
    bits [10:5] = cluster_id
    bits  [4:0] = neuron_in_cluster

Output neurons are in cluster 31 (OUTPUT_CLUSTER), neurons 0–9.
  Packet for digit k = (31 << 5) | k = 0x3E0 + k

Prediction for a sample = output neuron with the most spikes.
If no output spikes at all → prediction = -1 (unclassified).

Usage
    python decode_output.py
    python decode_output.py --verbose
    python decode_output.py --samples 50 --save_csv results.csv
    python decode_output.py \\
        --sim_output path/to/output.txt \\
        --labels     path/to/test_labels.txt
"""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
import sys

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
NPC            = 32
OUTPUT_SIZE    = 10
OUTPUT_CLUSTER = 31   # cluster where output neurons live (clusters: input=0-24, hidden=25-30, output=31)


# ─────────────────────────────────────────────────────────────────────────────
# PACKET DECODER
# ─────────────────────────────────────────────────────────────────────────────

def decode_packet(hex_str):
    """
    Decode a hex spike packet string.
    Returns (cluster_id, neuron_in_cluster) or None if invalid / sentinel.
    """
    try:
        val = int(hex_str.strip(), 16) & 0x7FF
        if val == 0x7FF:
            return None   # sentinel
        cluster_id        = (val >> 5) & 0x3F
        neuron_in_cluster =  val       & 0x1F
        return cluster_id, neuron_in_cluster
    except ValueError:
        return None


def parse_output_file(filepath, output_cluster):
    """
    Parse output.txt → spike_counts[sample_idx][digit] = count.
    Only spikes from output_cluster with neuron_id < OUTPUT_SIZE are counted.
    Returns (spike_counts, total_lines_read, unmatched_lines).
    """
    spike_counts = defaultdict(lambda: defaultdict(int))
    total, unmatched = 0, 0

    with open(filepath) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            total += 1
            if ':' not in line:
                unmatched += 1
                continue
            idx_str, pkt_str = line.split(':', 1)
            try:
                sample_idx = int(idx_str.strip())
            except ValueError:
                unmatched += 1
                continue
            decoded = decode_packet(pkt_str.strip())
            if decoded is None:
                continue
            cluster_id, neuron_id = decoded
            if cluster_id == output_cluster and neuron_id < OUTPUT_SIZE:
                spike_counts[sample_idx][neuron_id] += 1

    return spike_counts, total, unmatched


def load_labels(filepath):
    labels = []
    with open(filepath) as fh:
        for line in fh:
            s = line.strip()
            if s:
                labels.append(int(s))
    return labels


# ─────────────────────────────────────────────────────────────────────────────
# ACCURACY
# ─────────────────────────────────────────────────────────────────────────────

def compute_accuracy(spike_counts, labels, num_samples, verbose=False):
    correct       = 0
    unclassified  = 0
    per_class     = defaultdict(lambda: [0, 0])   # [correct, total]
    predictions   = []

    for i in range(num_samples):
        true_label = labels[i] if i < len(labels) else -1
        counts     = spike_counts.get(i, {})

        if not counts:
            pred = -1
            unclassified += 1
        else:
            pred = max(range(OUTPUT_SIZE), key=lambda d: counts.get(d, 0))

        spike_vec = [counts.get(d, 0) for d in range(OUTPUT_SIZE)]
        predictions.append((pred, true_label, spike_vec))

        if true_label >= 0:
            per_class[true_label][1] += 1
            if pred == true_label:
                correct += 1
                per_class[true_label][0] += 1

        if verbose and i < 50:
            mark = "✓" if pred == true_label else "✗"
            print(f"  [{mark}] Sample {i:4d}: pred={pred:2d}  true={true_label:2d}  "
                  f"spikes={spike_vec}")

    classified = num_samples - unclassified
    return correct, classified, unclassified, per_class, predictions


def print_report(correct, classified, unclassified, per_class, num_samples):
    print()
    print("=" * 60)
    print("  INFERENCE ACCURACY REPORT")
    print("=" * 60)
    print(f"  Samples evaluated        : {num_samples}")
    print(f"  Samples with output spikes: {classified}")
    print(f"  Unclassified (silent)    : {unclassified}")

    if classified > 0:
        acc_all  = 100.0 * correct / num_samples
        acc_cls  = 100.0 * correct / classified
        print(f"\n  Top-1 Accuracy (all)     : {acc_all:.2f}%  ({correct}/{num_samples})")
        print(f"  Top-1 Accuracy (classified): {acc_cls:.2f}%  ({correct}/{classified})")
    else:
        print("\n  No output spikes detected. Possible causes:")
        print("    1. Thresholds too high — try --hidden_threshold 10 in weight converter")
        print(f"    2. OUTPUT_CLUSTER mismatch — currently set to {OUTPUT_CLUSTER}")
        print("    3. Simulation did not finish — check output.txt is non-empty")

    print()
    print("  Per-class breakdown:")
    print(f"  {'Digit':>6}  {'Correct':>8}  {'Total':>6}  {'Acc%':>7}")
    print("  " + "-" * 34)
    for d in range(OUTPUT_SIZE):
        c, t = per_class[d]
        acc = f"{100.0 * c / t:.1f}%" if t > 0 else "  N/A "
        print(f"  {d:>6}  {c:>8}  {t:>6}  {acc:>7}")
    print("=" * 60)


def save_csv(filepath, predictions):
    with open(filepath, 'w', newline='') as fh:
        writer = csv.writer(fh)
        writer.writerow(['sample', 'true_label', 'predicted', 'correct'] +
                        [f'spikes_{d}' for d in range(OUTPUT_SIZE)])
        for i, (pred, true, spikes) in enumerate(predictions):
            writer.writerow([i, true, pred, int(pred == true)] + spikes)
    print(f"\n[csv] Per-sample results → {filepath}")


# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

def main():
    repo_root    = Path(__file__).resolve().parent.parent.parent
    default_sim  = str(repo_root / 'inference_accelarator' / 'neuron_accelerator'
                       / 'output.txt')
    default_lbl  = str(repo_root / 'inference_accelarator' / 'neuron_accelerator'
                       / 'test_labels.txt')

    p = argparse.ArgumentParser(description="Decode simulation output and compute accuracy")
    p.add_argument('--sim_output',     default=default_sim,
                   help='Path to simulation output.txt')
    p.add_argument('--labels',         default=default_lbl,
                   help='Path to test_labels.txt')
    p.add_argument('--samples',        type=int, default=None,
                   help='Number of samples to evaluate (default: all in labels file)')
    p.add_argument('--output_cluster', type=int, default=OUTPUT_CLUSTER,
                   help=f'Cluster ID of output neurons (default: {OUTPUT_CLUSTER})')
    p.add_argument('--verbose',        action='store_true',
                   help='Print per-sample predictions (first 50)')
    p.add_argument('--save_csv',       default=None,
                   help='Save per-sample results to CSV file')
    args = p.parse_args()

    print("=" * 65)
    print("  Neuron Accelerator — Output Decoder & Accuracy Calculator")
    print("=" * 65)
    print(f"  Sim output     : {args.sim_output}")
    print(f"  Labels file    : {args.labels}")
    print(f"  Output cluster : {args.output_cluster}")
    print()

    if not Path(args.sim_output).exists():
        print(f"[ERROR] {args.sim_output} not found. Run simulation first.")
        sys.exit(1)
    if not Path(args.labels).exists():
        print(f"[ERROR] {args.labels} not found. Run generate_spike_mem.py first.")
        sys.exit(1)

    # Check file is non-empty
    if Path(args.sim_output).stat().st_size == 0:
        print("[ERROR] output.txt is empty — simulation produced no output.")
        print("        The simulation may still be running, or init did not complete.")
        sys.exit(1)

    print("[parse] Reading simulation output ...")
    spike_counts, total_lines, unmatched = parse_output_file(
        args.sim_output, args.output_cluster)
    print(f"  Lines read              : {total_lines:,}")
    print(f"  Unmatched lines         : {unmatched}")
    print(f"  Samples with output spikes: {len(spike_counts)}")

    print("[parse] Reading ground-truth labels ...")
    labels = load_labels(args.labels)
    print(f"  Labels loaded           : {len(labels)}")

    num_samples = args.samples if args.samples else len(labels)
    num_samples = min(num_samples, len(labels))
    print(f"  Evaluating              : {num_samples} samples")

    print("\n[eval] Computing accuracy ...")
    correct, classified, unclassified, per_class, predictions = compute_accuracy(
        spike_counts, labels, num_samples, verbose=args.verbose)

    print_report(correct, classified, unclassified, per_class, num_samples)

    if args.save_csv:
        save_csv(args.save_csv, predictions)

    if classified > 0:
        print(f"\n[RESULT] Hardware MNIST accuracy = "
              f"{100.0 * correct / num_samples:.2f}%  "
              f"({correct}/{num_samples} samples)")
    print("=" * 65)


if __name__ == '__main__':
    main()
