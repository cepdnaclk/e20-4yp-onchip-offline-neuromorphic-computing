#!/usr/bin/env python3
"""Check parity between two Vmem->LUT index mappings.

Mappings compared:
1) C-style divide+clamp in backpropD_hw.C:
   idx = clamp(int(mem / SCALE), -128, 127) + 128
2) Hardware bit-slice style for Q16.16 dumps:
   idx = (mem >> 16) & 0xFF  (i.e., bits[23:16] of 32-bit signed value)
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import List, Tuple


SCALE = 256


def c_style_index(mem: int) -> int:
    v = int(float(mem) / float(SCALE))
    if v > 127:
        v = 127
    if v < -128:
        v = -128
    return (v + 128) & 0xFF


def bits_23_16_index(mem: int) -> int:
    u32 = mem & 0xFFFFFFFF
    return (u32 >> 16) & 0xFF


def read_sample_values(path: Path, max_values: int) -> List[int]:
    vals: List[int] = []
    if not path.exists():
        return vals
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s:
            continue
        try:
            if s.lower().startswith("0x"):
                vals.append(int(s, 16))
            else:
                vals.append(int(s, 10))
        except ValueError:
            continue
        if len(vals) >= max_values:
            break
    return vals


def build_default_testset() -> List[int]:
    v = [
        0,
        1,
        -1,
        255,
        -255,
        256,
        -256,
        257,
        -257,
        0x00010000,
        0x00008000,
        0xFFFF0000,
        0x7FFFFFFF,
        -2147483648,
    ]
    for x in range(-2048, 2049, 64):
        v.append(x)
    return v


def compare(values: List[int]) -> Tuple[int, List[Tuple[int, int, int]]]:
    mismatches: List[Tuple[int, int, int]] = []
    for mem in values:
        c = c_style_index(mem)
        b = bits_23_16_index(mem)
        if c != b:
            mismatches.append((mem, c, b))
    return len(values), mismatches


def main() -> None:
    ap = argparse.ArgumentParser(description="Check LUT index mapper parity")
    ap.add_argument("--values-file", type=Path, help="Optional text file with one mem value per line")
    ap.add_argument("--max-values", type=int, default=10000)
    ap.add_argument("--report", type=Path, default=Path("RISC_V/c_program/vmem_lut_parity_report.txt"))
    args = ap.parse_args()

    values = build_default_testset()
    if args.values_file:
        values.extend(read_sample_values(args.values_file, args.max_values))

    total, mismatches = compare(values)

    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("w") as f:
        f.write("Vmem->LUT Index Parity Report\n")
        f.write("=============================\n")
        f.write(f"Total values tested: {total}\n")
        f.write(f"Mismatches: {len(mismatches)}\n\n")
        for mem, c_idx, b_idx in mismatches[:200]:
            f.write(f"mem={mem} c_style={c_idx} bits23_16={b_idx}\n")

    if mismatches:
        print(f"FAIL: {len(mismatches)} mismatches out of {total}. Report: {args.report}")
    else:
        print(f"PASS: mapper parity over {total} values. Report: {args.report}")


if __name__ == "__main__":
    main()
