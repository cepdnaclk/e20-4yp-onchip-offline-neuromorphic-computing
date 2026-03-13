#!/usr/bin/env python3
"""Check weight scaling consistency between C int weights and Q16.16 packaging."""

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
            raise ValueError(f"Missing marker {marker}")
        rows: List[List[int]] = []
        for ln in lines[start:]:
            s = ln.strip()
            if not s:
                continue
            if s.startswith("W") or s.startswith("---"):
                break
            rows.append([int(x) for x in s.split()])
        return rows

    return take("W1 Weights"), take("W2 Weights")


def main() -> None:
    ap = argparse.ArgumentParser(description="Check weight conversion scale")
    ap.add_argument("--weights", required=True, type=Path)
    ap.add_argument("--int-scale", type=int, default=256)
    ap.add_argument("--max-values", type=int, default=20)
    ap.add_argument("--report", type=Path, default=Path("RISC_V/c_program/weight_scale_check_report.txt"))
    args = ap.parse_args()

    w1, w2 = parse_weights(args.weights)
    flat = [v for r in w1 for v in r] + [v for r in w2 for v in r]
    sample = flat[: max(1, args.max_values)]

    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("w") as f:
        f.write("Weight Conversion Scale Check\n")
        f.write("=============================\n")
        f.write(f"Input file: {args.weights}\n")
        f.write(f"int_scale (C): {args.int_scale}\n\n")
        f.write("Columns:\n")
        f.write("w_int, q16_correct(v=int/int_scale*65536), q16_if_direct_intx65536, ratio\n\n")

        for w in sample:
            q_correct = int(round((w / float(args.int_scale)) * 65536.0))
            q_direct = int(w * 65536)
            ratio = "inf" if q_correct == 0 else f"{(q_direct / q_correct):.2f}"
            f.write(f"{w}, {q_correct}, {q_direct}, {ratio}\n")

        non_zero = [w for w in sample if w != 0]
        if non_zero:
            avg_ratio = sum((w * 65536) / int(round((w / float(args.int_scale)) * 65536.0)) for w in non_zero) / len(non_zero)
            f.write("\n")
            f.write(f"Average non-zero ratio: {avg_ratio:.2f}x\n")
            f.write("Expected if int_scale=256 and direct-int conversion is used: ~256x over-scale.\n")

    print(f"Wrote scale check report: {args.report}")


if __name__ == "__main__":
    main()
