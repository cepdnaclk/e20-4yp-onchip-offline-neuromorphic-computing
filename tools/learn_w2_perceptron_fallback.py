#!/usr/bin/env python3
"""Fallback W2-only learner using hidden spike counts and misclassification labels.

This script is intentionally simple and conservative:
- Keeps W1 unchanged.
- Updates only W2.
- For each misclassified sample:
  - add `eta * hidden_spike_count` to the true-class column
  - subtract `eta * hidden_spike_count` from the predicted-class column

It is designed as a stable alternative when custom-unit-surrogate online updates
cause repeated holdout regressions.
"""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path
from typing import Dict, List, Tuple

INPUT_SIZE = 784
HIDDEN_SIZE = 200
OUTPUT_SIZE = 10

W2_MIN = -100
W2_MAX = 100

SUMMARY_RE = re.compile(
    r"SAMPLE\s+(\d+)\s+\|\s+true=(\d+)\s+\|\s+pred=(\d+)\s+\|\s+([A-Z_]+)"
)


def clamp_w2(value: int) -> int:
    if value > W2_MAX:
        return W2_MAX
    if value < W2_MIN:
        return W2_MIN
    return int(value)


def parse_weight_file(path: Path) -> Tuple[List[List[int]], List[List[int]]]:
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

            tokens = line.replace(",", " ").split()
            try:
                row = [int(x) for x in tokens]
            except ValueError:
                continue

            if section == "w1":
                w1.append(row)
            else:
                w2.append(row)

    if len(w1) != INPUT_SIZE or any(len(r) != HIDDEN_SIZE for r in w1):
        raise ValueError("W1 shape mismatch")
    if len(w2) != HIDDEN_SIZE or any(len(r) != OUTPUT_SIZE for r in w2):
        raise ValueError("W2 shape mismatch")

    return w1, w2


def write_weight_file(path: Path, w1: List[List[int]], w2: List[List[int]]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("W1 Weights (784 x 200):\n")
        for row in w1:
            f.write(" ".join(str(x) for x in row) + "\n")
        f.write("\n-------------------------------------\n\n")
        f.write("W2 Weights (200 x 10):\n")
        for row in w2:
            f.write(" ".join(str(x) for x in row) + "\n")


def parse_infer_log(path: Path) -> Dict[int, Tuple[int, int, str]]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    mapping: Dict[int, Tuple[int, int, str]] = {}
    for s, t, p, result in SUMMARY_RE.findall(text):
        mapping[int(s)] = (int(t), int(p), result)
    if not mapping:
        raise ValueError("No SAMPLE lines found in inference log")
    return mapping


def hidden_spike_counts_by_sample(smem_csv: Path) -> Dict[int, List[int]]:
    counts: Dict[int, List[int]] = {}
    with smem_csv.open("r", newline="", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        req = ["sample", "ts"] + [f"spike_h{i}" for i in range(HIDDEN_SIZE)]
        for col in req:
            if col not in (reader.fieldnames or []):
                raise ValueError(f"Missing required SMEM column: {col}")

        for row in reader:
            sample = int(row["sample"])
            if sample not in counts:
                counts[sample] = [0] * HIDDEN_SIZE
            c = counts[sample]
            for i in range(HIDDEN_SIZE):
                c[i] += int(row[f"spike_h{i}"])
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description="Fallback W2-only perceptron learner")
    parser.add_argument("--weights", type=Path, required=True, help="Input best_weights_hw.txt")
    parser.add_argument("--smem", type=Path, required=True, help="SMEM CSV with spike_h* columns")
    parser.add_argument("--infer-log", type=Path, required=True, help="Inference log with true/pred")
    parser.add_argument("--output", type=Path, required=True, help="Output updated weight file")
    parser.add_argument("--eta", type=int, default=1, help="Integer update multiplier (default: 1)")
    parser.add_argument(
        "--use-binary-activity",
        action="store_true",
        help="Use 0/1 hidden activity per sample instead of raw spike counts",
    )
    parser.add_argument(
        "--average-updates",
        action="store_true",
        help="Average accumulated W2 deltas over used misclassified samples before apply",
    )
    parser.add_argument(
        "--max-misclassified",
        type=int,
        default=0,
        help="Limit number of misclassified samples used (0 = all)",
    )
    args = parser.parse_args()

    if args.eta <= 0:
        raise ValueError("--eta must be > 0")

    w1, w2 = parse_weight_file(args.weights)
    infer = parse_infer_log(args.infer_log)
    spike_counts = hidden_spike_counts_by_sample(args.smem)

    candidates = []
    for sample_id in sorted(set(infer.keys()) & set(spike_counts.keys())):
        true_label, pred_label, result = infer[sample_id]
        if result == "PASS" or true_label == pred_label:
            continue
        if not (0 <= true_label < OUTPUT_SIZE and 0 <= pred_label < OUTPUT_SIZE):
            continue
        candidates.append((sample_id, true_label, pred_label))

    if args.max_misclassified > 0:
        candidates = candidates[: args.max_misclassified]

    if not candidates:
        raise ValueError("No misclassified overlapping samples found for update")

    accum_w2 = [[0 for _ in range(OUTPUT_SIZE)] for _ in range(HIDDEN_SIZE)]

    for sample_id, true_label, pred_label in candidates:
        counts = spike_counts[sample_id]
        for i in range(HIDDEN_SIZE):
            activity = 1 if counts[i] > 0 else 0
            feature = activity if args.use_binary_activity else counts[i]
            delta = args.eta * feature
            accum_w2[i][true_label] += delta
            accum_w2[i][pred_label] -= delta

    divisor = float(len(candidates)) if args.average_updates else 1.0
    for i in range(HIDDEN_SIZE):
        for j in range(OUTPUT_SIZE):
            delta = int(round(accum_w2[i][j] / divisor))
            w2[i][j] = clamp_w2(w2[i][j] + delta)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_weight_file(args.output, w1, w2)

    print(f"Misclassified samples used: {len(candidates)}")
    print(f"Eta: {args.eta}")
    print(f"Binary activity: {'ON' if args.use_binary_activity else 'OFF'}")
    print(f"Average updates: {'ON' if args.average_updates else 'OFF'}")
    if args.max_misclassified > 0:
        print(f"Max misclassified requested: {args.max_misclassified}")
    print("Mode: W2-only perceptron fallback")
    print(f"Wrote: {args.output}")


if __name__ == "__main__":
    main()
