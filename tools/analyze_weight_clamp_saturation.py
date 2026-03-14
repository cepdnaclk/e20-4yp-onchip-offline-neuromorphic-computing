#!/usr/bin/env python3
"""Analyze clamp saturation in C-style weight dump files.

Usage:
  python3 tools/analyze_weight_clamp_saturation.py \
    --weights RISC_V/c_program/best_weights_hw.txt \
    --scale 256 --w1-clamp 20 --w2-clamp 100
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import List, Tuple


def parse_weights(path: Path) -> Tuple[List[List[int]], List[List[int]]]:
    lines = path.read_text().splitlines()

    def take(marker: str) -> List[List[int]]:
        start = -1
        for i, ln in enumerate(lines):
            if marker in ln:
                start = i + 1
                break
        if start < 0:
            raise ValueError(f"Missing marker: {marker}")
        rows: List[List[int]] = []
        for ln in lines[start:]:
            s = ln.strip()
            if not s:
                continue
            if s.startswith("W") or s.startswith("---"):
                break
            rows.append([int(x) for x in s.split()])
        if not rows:
            raise ValueError(f"No rows found for marker: {marker}")
        return rows

    return take("W1 Weights"), take("W2 Weights")


def layer_stats(mat: List[List[int]], clamp: int) -> dict:
    flat = [v for r in mat for v in r]
    n = len(flat)
    pos = sum(1 for v in flat if v == clamp)
    neg = sum(1 for v in flat if v == -clamp)
    z = sum(1 for v in flat if v == 0)
    max_abs = max(abs(v) for v in flat)
    return {
        "count": n,
        "pos_clamp": pos,
        "neg_clamp": neg,
        "zero": z,
        "max_abs": max_abs,
    }


def pct(x: int, n: int) -> float:
    return 100.0 * float(x) / float(n) if n else 0.0


def print_layer(name: str, st: dict, clamp: int, scale: int) -> None:
    print(f"[{name}]")
    print(f"count:        {st['count']}")
    print(f"+clamp {clamp}: {st['pos_clamp']} ({pct(st['pos_clamp'], st['count']):.2f}%)")
    print(f"-clamp {-clamp}: {st['neg_clamp']} ({pct(st['neg_clamp'], st['count']):.2f}%)")
    print(f"zero:         {st['zero']} ({pct(st['zero'], st['count']):.2f}%)")
    print(f"max|w_int|:   {st['max_abs']}")
    print(f"max|w_float|: {st['max_abs']/float(scale):.6f}")
    print()


def main() -> None:
    ap = argparse.ArgumentParser(description="Analyze weight clamp saturation")
    ap.add_argument("--weights", type=Path, required=True)
    ap.add_argument("--scale", type=int, default=256)
    ap.add_argument("--w1-clamp", type=int, default=20)
    ap.add_argument("--w2-clamp", type=int, default=100)
    args = ap.parse_args()

    w1, w2 = parse_weights(args.weights)

    s1 = layer_stats(w1, args.w1_clamp)
    s2 = layer_stats(w2, args.w2_clamp)

    print("Clamp Saturation Analysis")
    print("=========================")
    print(f"file:  {args.weights}")
    print(f"scale: {args.scale}")
    print()

    print_layer("W1", s1, args.w1_clamp, args.scale)
    print_layer("W2", s2, args.w2_clamp, args.scale)

    if pct(s2["pos_clamp"] + s2["neg_clamp"], s2["count"]) > 15.0:
        print("Warning: W2 clamp saturation is high (>15%).")
        print("Suggestions: reduce LR, add gradient clipping, or widen W2 clamp gradually.")


if __name__ == "__main__":
    main()
