#!/usr/bin/env python3
"""
Replay hardware dump (spikes + LUT-index Vmem) and perform one C-style update pass.

Pure-Python implementation (no external dependencies) so it runs in restricted
environments and mirrors the learning update contract in backpropD_hw.C.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


SCALE = 256
THRESHOLD = 1 * SCALE
DEFAULT_BETA = 0.75
DEFAULT_LR = 0.005
DEFAULT_BATCH = 32


@dataclass
class ReplaySample:
    sample_id: int
    inp_spk: List[List[float]]
    hid_spk: List[List[float]]
    out_spk: List[List[float]]
    hid_lut: List[List[int]]
    out_lut: List[List[int]]


def _zeros_2d(r: int, c: int, v: float = 0.0) -> List[List[float]]:
    return [[v for _ in range(c)] for _ in range(r)]


def _parse_weight_matrix(lines: List[str], marker: str) -> List[List[int]]:
    start = -1
    for i, ln in enumerate(lines):
        if marker in ln:
            start = i + 1
            break
    if start < 0:
        raise ValueError(f"Marker '{marker}' not found")

    rows: List[List[int]] = []
    idx = start
    while idx < len(lines):
        s = lines[idx].strip()
        if not s:
            idx += 1
            continue
        if s.startswith("W") or s.startswith("---"):
            break
        try:
            row = [int(x) for x in s.split()]
        except ValueError:
            break
        if row:
            rows.append(row)
        idx += 1

    if not rows:
        raise ValueError(f"No rows found for marker '{marker}'")
    return rows


def load_weights_txt(path: Path) -> Tuple[List[List[int]], List[List[int]]]:
    lines = path.read_text().splitlines()
    w1 = _parse_weight_matrix(lines, "W1 Weights")
    w2 = _parse_weight_matrix(lines, "W2 Weights")
    return w1, w2


def save_weights_txt(path: Path, w1: List[List[int]], w2: List[List[int]]) -> None:
    with path.open("w") as f:
        f.write(f"W1 Weights ({len(w1)} x {len(w1[0])}):\n")
        for row in w1:
            f.write(" ".join(str(int(v)) for v in row) + "\n")
        f.write("\n-------------------------------------\n\n")
        f.write(f"W2 Weights ({len(w2)} x {len(w2[0])}):\n")
        for row in w2:
            f.write(" ".join(str(int(v)) for v in row) + "\n")


def load_labels(path: Path) -> List[int]:
    labels: List[int] = []
    for line in path.read_text().splitlines():
        s = line.strip()
        if s:
            labels.append(int(s, 10))
    return labels


def load_lut_from_verilog(path: Path) -> List[int]:
    lut = [0] * 256
    seen = set()
    pat = re.compile(r"lut_rom\[\s*(\d+)\s*\]\s*=\s*8'h([0-9A-Fa-f]{2})")
    for line in path.read_text().splitlines():
        m = pat.search(line)
        if not m:
            continue
        idx = int(m.group(1))
        val = int(m.group(2), 16)
        if 0 <= idx <= 255:
            lut[idx] = val
            seen.add(idx)
    if len(seen) != 256:
        raise RuntimeError(f"Expected 256 LUT entries, found {len(seen)} in {path}")
    return lut


def _pick_columns(header: Sequence[str], prefixes: Sequence[str], count: int) -> List[int]:
    idx: List[int] = []
    for p in prefixes:
        idx = [i for i, name in enumerate(header) if name.startswith(p)]
        if len(idx) == count:
            break
    if len(idx) != count:
        raise RuntimeError(
            f"Could not find {count} columns with prefixes {prefixes}. Found {len(idx)}"
        )
    return idx


def _to_int_list(row: List[str], indices: Sequence[int]) -> List[int]:
    return [int(float(row[i])) for i in indices]


def load_replay_samples(
    csv_path: Path,
    input_size: int,
    hidden_size: int,
    output_size: int,
    max_samples: int | None,
) -> List[ReplaySample]:
    with csv_path.open(newline="") as f:
        reader = csv.reader(f)
        header = next(reader)

        i_sample = header.index("sample")
        i_ts = header.index("ts")

        inp_idx = _pick_columns(header, ("inp_", "inp_spk_"), input_size)
        hs_idx = _pick_columns(header, ("spike_h", "h_spk_"), hidden_size)
        os_idx = _pick_columns(header, ("spike_o", "o_spk_"), output_size)
        hl_idx = _pick_columns(header, ("vmem_h", "h_lut_"), hidden_size)
        ol_idx = _pick_columns(header, ("vmem_o", "o_lut_"), output_size)

        buckets: Dict[int, Dict[int, Tuple[List[int], List[int], List[int], List[int], List[int]]]] = {}
        for row in reader:
            if not row or len(row) <= i_ts:
                continue
            s = int(row[i_sample])
            t = int(row[i_ts])
            buckets.setdefault(s, {})[t] = (
                _to_int_list(row, inp_idx),
                _to_int_list(row, hs_idx),
                _to_int_list(row, os_idx),
                _to_int_list(row, hl_idx),
                _to_int_list(row, ol_idx),
            )

    sample_ids = sorted(buckets.keys())
    if max_samples is not None:
        sample_ids = sample_ids[:max_samples]

    out: List[ReplaySample] = []
    for s in sample_ids:
        ts_keys = sorted(buckets[s].keys())
        inp: List[List[float]] = []
        hs: List[List[float]] = []
        os: List[List[float]] = []
        hl: List[List[int]] = []
        ol: List[List[int]] = []

        for t in ts_keys:
            d = buckets[s][t]
            inp.append([float(v) for v in d[0]])
            hs.append([float(v) for v in d[1]])
            os.append([float(v) for v in d[2]])
            hl.append([int(v) & 0xFF for v in d[3]])
            ol.append([int(v) & 0xFF for v in d[4]])

        out.append(ReplaySample(s, inp, hs, os, hl, ol))

    return out


def _surrogate_spike_approx(spike: float) -> float:
    vt = THRESHOLD / SCALE
    fired_v = (THRESHOLD + 1) / SCALE
    off_v = 0.0
    v = fired_v if spike > 0.5 else off_v
    den = 1.0 + 4.0 * abs(v - vt)
    return 1.0 / (den * den)


def compute_sample_grads(
    sample: ReplaySample,
    label: int,
    w1f: List[List[float]],
    w2f: List[List[float]],
    lut: List[int],
    beta: float,
    sg_source: str,
) -> Tuple[List[List[float]], List[List[float]]]:
    t_steps = len(sample.inp_spk)
    h_size = len(w2f)
    o_size = len(w2f[0])
    i_size = len(w1f)

    out_spk_total = [0.0] * o_size
    for t in range(t_steps):
        row = sample.out_spk[t]
        for k in range(o_size):
            out_spk_total[k] += row[k]

    out_rates = [(v * SCALE) / float(t_steps) for v in out_spk_total]
    delta_out = [2.0 * ((out_rates[k] / SCALE) - (1.0 if k == label else 0.0)) for k in range(o_size)]

    dm2 = [0.0] * o_size
    dm1 = [0.0] * h_size

    dW1 = _zeros_2d(i_size, h_size, 0.0)
    dW2 = _zeros_2d(h_size, o_size, 0.0)

    for t in range(t_steps - 1, -1, -1):
        i_spk = sample.inp_spk[t]
        h_spk = sample.hid_spk[t]
        o_spk = sample.out_spk[t]

        if sg_source == "lut_dump":
            sg_o = [lut[idx] / 255.0 for idx in sample.out_lut[t]]
            sg_h = [lut[idx] / 255.0 for idx in sample.hid_lut[t]]
        else:
            sg_o = [_surrogate_spike_approx(v) for v in o_spk]
            sg_h = [_surrogate_spike_approx(v) for v in h_spk]

        d2 = [(delta_out[k] + beta * dm2[k]) * sg_o[k] for k in range(o_size)]

        active_h = [j for j in range(h_size) if h_spk[j] > 0.5]
        for j in active_h:
            row = dW2[j]
            for k in range(o_size):
                row[k] += d2[k]

        new_dm1 = [0.0] * h_size
        for j in range(h_size):
            s = 0.0
            row_w2 = w2f[j]
            for k in range(o_size):
                s += row_w2[k] * d2[k]
            new_dm1[j] = s

        dm2 = [d2[k] * (1.0 - o_spk[k]) for k in range(o_size)]
        d1 = [(new_dm1[j] + beta * dm1[j]) * sg_h[j] for j in range(h_size)]

        active_i = [i for i in range(i_size) if i_spk[i] > 0.5]
        for i in active_i:
            row = dW1[i]
            for j in range(h_size):
                row[j] += d1[j]

        dm1 = [d1[j] * (1.0 - h_spk[j]) for j in range(h_size)]

    return dW1, dW2


def _apply_update_and_clip(
    wf: List[List[float]],
    acc: List[List[float]],
    step: float,
    clamp_abs: float,
) -> None:
    for i in range(len(wf)):
        row_w = wf[i]
        row_a = acc[i]
        for j in range(len(row_w)):
            v = row_w[j] - step * row_a[j]
            if v > clamp_abs:
                v = clamp_abs
            elif v < -clamp_abs:
                v = -clamp_abs
            row_w[j] = v
            row_a[j] = 0.0


def apply_replay_update(
    samples: List[ReplaySample],
    labels: Sequence[int],
    w1_int: List[List[int]],
    w2_int: List[List[int]],
    lut: List[int],
    lr: float,
    batch_size: int,
    beta: float,
    w1_clamp_int: int,
    w2_clamp_int: int,
    sg_source: str,
    apply_tail: bool,
) -> Tuple[List[List[int]], List[List[int]], Dict[str, float]]:
    i_size = len(w1_int)
    h_size = len(w1_int[0])
    o_size = len(w2_int[0])

    w1f = [[w1_int[i][j] / float(SCALE) for j in range(h_size)] for i in range(i_size)]
    w2f = [[w2_int[j][k] / float(SCALE) for k in range(o_size)] for j in range(h_size)]

    acc1 = _zeros_2d(i_size, h_size, 0.0)
    acc2 = _zeros_2d(h_size, o_size, 0.0)

    w1_max = w1_clamp_int / float(SCALE)
    w2_max = w2_clamp_int / float(SCALE)
    updates_applied = 0

    for n, s in enumerate(samples, start=1):
        if s.sample_id >= len(labels):
            continue
        label = int(labels[s.sample_id])
        g1, g2 = compute_sample_grads(s, label, w1f, w2f, lut, beta, sg_source)

        for i in range(i_size):
            row_a = acc1[i]
            row_g = g1[i]
            for j in range(h_size):
                row_a[j] += row_g[j]
        for j in range(h_size):
            row_a = acc2[j]
            row_g = g2[j]
            for k in range(o_size):
                row_a[k] += row_g[k]

        if n % batch_size == 0:
            step = lr / batch_size
            _apply_update_and_clip(w1f, acc1, step, w1_max)
            _apply_update_and_clip(w2f, acc2, step, w2_max)
            updates_applied += 1

    if apply_tail:
        non_zero_tail = False
        for i in range(i_size):
            for j in range(h_size):
                if acc1[i][j] != 0.0:
                    non_zero_tail = True
                    break
            if non_zero_tail:
                break
        if non_zero_tail:
            step = lr / batch_size
            _apply_update_and_clip(w1f, acc1, step, w1_max)
            _apply_update_and_clip(w2f, acc2, step, w2_max)
            updates_applied += 1

    w1_new = [[int(round(w1f[i][j] * SCALE)) for j in range(h_size)] for i in range(i_size)]
    w2_new = [[int(round(w2f[j][k] * SCALE)) for k in range(o_size)] for j in range(h_size)]

    w1_abs_max = max(abs(v) for row in w1_new for v in row)
    w2_abs_max = max(abs(v) for row in w2_new for v in row)
    stats = {
        "samples_used": float(len(samples)),
        "updates_applied": float(updates_applied),
        "w1_abs_max": float(w1_abs_max),
        "w2_abs_max": float(w2_abs_max),
    }
    return w1_new, w2_new, stats


def _layer_diff_stats(old: List[List[int]], new: List[List[int]]) -> Tuple[int, int, int, float, float]:
    diffs: List[int] = []
    changed = 0
    max_abs = 0
    total_abs = 0
    count = 0
    for i in range(len(old)):
        for j in range(len(old[0])):
            d = int(new[i][j]) - int(old[i][j])
            ad = abs(d)
            diffs.append(ad)
            if d != 0:
                changed += 1
            if ad > max_abs:
                max_abs = ad
            total_abs += ad
            count += 1
    diffs.sort()
    p95_idx = min(count - 1, int(math.floor(0.95 * (count - 1))))
    p95 = float(diffs[p95_idx])
    mean_abs = float(total_abs) / float(count)
    return count, changed, max_abs, mean_abs, p95


def write_diff_report(
    path: Path,
    old_w1: List[List[int]],
    old_w2: List[List[int]],
    new_w1: List[List[int]],
    new_w2: List[List[int]],
) -> None:
    c1, ch1, m1, mean1, p951 = _layer_diff_stats(old_w1, new_w1)
    c2, ch2, m2, mean2, p952 = _layer_diff_stats(old_w2, new_w2)
    with path.open("w") as f:
        f.write("Replay Learning Diff Report\n")
        f.write("=================================\n\n")
        f.write("[W1]\n")
        f.write(f"count={c1}\n")
        f.write(f"changed={ch1}\n")
        f.write(f"max_abs_diff={m1}\n")
        f.write(f"mean_abs_diff={mean1:.6f}\n")
        f.write(f"p95_abs_diff={p951:.6f}\n\n")
        f.write("[W2]\n")
        f.write(f"count={c2}\n")
        f.write(f"changed={ch2}\n")
        f.write(f"max_abs_diff={m2}\n")
        f.write(f"mean_abs_diff={mean2:.6f}\n")
        f.write(f"p95_abs_diff={p952:.6f}\n")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Replay hardware dump learning oracle")
    p.add_argument("--weights-in", required=True, type=Path, help="Input C-style weight text file")
    p.add_argument("--weights-out", required=True, type=Path, help="Output updated weight text file")
    p.add_argument("--dump-csv", required=True, type=Path, help="Hardware dump CSV (smem_all_samples.csv)")
    p.add_argument("--labels", required=True, type=Path, help="Labels txt, one label per line")
    p.add_argument(
        "--lut-verilog",
        default=Path("surrogate_lut/surrogate_lut_wb.v"),
        type=Path,
        help="Path to surrogate_lut_wb.v",
    )
    p.add_argument("--diff-report", default=Path("tools/replay_diff_report.txt"), type=Path)
    p.add_argument("--max-samples", type=int, default=32, help="Number of dump samples to replay")
    p.add_argument("--lr", type=float, default=DEFAULT_LR)
    p.add_argument("--batch-size", type=int, default=DEFAULT_BATCH)
    p.add_argument("--beta", type=float, default=DEFAULT_BETA)
    p.add_argument("--w1-clamp-int", type=int, default=20)
    p.add_argument("--w2-clamp-int", type=int, default=100)
    p.add_argument("--sg-source", choices=["lut_dump", "spike_approx"], default="lut_dump")
    p.add_argument("--apply-tail", action="store_true", help="Apply partial batch tail update")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    w1, w2 = load_weights_txt(args.weights_in)
    labels = load_labels(args.labels)
    lut = load_lut_from_verilog(args.lut_verilog)

    samples = load_replay_samples(
        args.dump_csv,
        input_size=len(w1),
        hidden_size=len(w1[0]),
        output_size=len(w2[0]),
        max_samples=args.max_samples,
    )

    w1_new, w2_new, stats = apply_replay_update(
        samples=samples,
        labels=labels,
        w1_int=w1,
        w2_int=w2,
        lut=lut,
        lr=args.lr,
        batch_size=args.batch_size,
        beta=args.beta,
        w1_clamp_int=args.w1_clamp_int,
        w2_clamp_int=args.w2_clamp_int,
        sg_source=args.sg_source,
        apply_tail=args.apply_tail,
    )

    args.weights_out.parent.mkdir(parents=True, exist_ok=True)
    save_weights_txt(args.weights_out, w1_new, w2_new)

    args.diff_report.parent.mkdir(parents=True, exist_ok=True)
    write_diff_report(args.diff_report, w1, w2, w1_new, w2_new)

    print("Replay oracle complete")
    print(f"  samples_used    : {int(stats['samples_used'])}")
    print(f"  updates_applied : {int(stats['updates_applied'])}")
    print(f"  W1 abs max      : {int(stats['w1_abs_max'])}")
    print(f"  W2 abs max      : {int(stats['w2_abs_max'])}")
    print(f"  weights_out     : {args.weights_out}")
    print(f"  diff_report     : {args.diff_report}")


if __name__ == "__main__":
    main()
