#!/usr/bin/env python3
"""
Compare hardware vs software dump CSVs (vmem + spikes).
"""

import argparse
import csv


def parse_row(row):
    return [int(x) for x in row]


def _load_csv_by_key(path):
    with open(path, newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if header is None:
            raise RuntimeError(f"Missing header in {path}")
        rows = {}
        duplicates = 0
        for row in reader:
            if len(row) < 2:
                continue
            key = (row[0], row[1])
            if key in rows:
                duplicates += 1
                continue
            rows[key] = row
    return header, rows, duplicates


def compare_csv(hw_path, sw_path, max_mismatches):
    mismatches = 0
    total = 0

    hw_header, hw_rows, hw_dups = _load_csv_by_key(hw_path)
    sw_header, sw_rows, sw_dups = _load_csv_by_key(sw_path)

    if hw_header != sw_header:
        print("Warning: header mismatch. Proceeding with column order from each file.")

    if hw_dups:
        print(f"Warning: {hw_dups} duplicate sample/ts rows in HW CSV (kept first occurrence)")
    if sw_dups:
        print(f"Warning: {sw_dups} duplicate sample/ts rows in SW CSV (kept first occurrence)")

    hw_keys = set(hw_rows.keys())
    sw_keys = set(sw_rows.keys())
    common = sorted(hw_keys & sw_keys, key=lambda k: (int(k[0]), int(k[1])))
    only_hw = sorted(hw_keys - sw_keys)[:5]
    only_sw = sorted(sw_keys - hw_keys)[:5]

    if only_hw:
        print(f"Warning: HW-only sample/ts rows (showing up to 5): {only_hw}")
    if only_sw:
        print(f"Warning: SW-only sample/ts rows (showing up to 5): {only_sw}")

    # Build semantic column groups for block-level diagnostics.
    def pick(prefixes):
        out = []
        for i, name in enumerate(hw_header):
            for p in prefixes:
                if name.startswith(p):
                    out.append(i)
                    break
        return out

    groups = {
        "inp": pick(["inp_", "inp_spk_"]),
        "h_spk": pick(["h_spk_", "spike_h"]),
        "o_spk": pick(["o_spk_", "spike_o"]),
        "h_lut": pick(["h_lut_", "vmem_h"]),
        "o_lut": pick(["o_lut_", "vmem_o"]),
    }
    g_mism = {k: 0 for k in groups}
    g_total = {k: 0 for k in groups}

    for key in common:
        hw_row = hw_rows[key]
        sw_row = sw_rows[key]
        total += 1

        hw_vals = parse_row(hw_row[2:])
        sw_vals = parse_row(sw_row[2:])

        if len(hw_vals) != len(sw_vals):
            print("[WARN] column count mismatch at sample/ts:", key)
            continue

        for idx, (h, s) in enumerate(zip(hw_vals, sw_vals)):
            if h != s:
                mismatches += 1
                if mismatches <= max_mismatches:
                    print(
                        f"Mismatch sample={key[0]} ts={key[1]} col={idx + 2}: hw={h} sw={s}"
                    )

        # Group mismatch accounting uses full-row indexing including sample,ts.
        for gname, idxs in groups.items():
            for i in idxs:
                g_total[gname] += 1
                if int(hw_row[i]) != int(sw_row[i]):
                    g_mism[gname] += 1

    print("\nBlock mismatch summary:")
    for gname in ["inp", "h_spk", "o_spk", "h_lut", "o_lut"]:
        t = g_total[gname]
        m = g_mism[gname]
        pct = (100.0 * m / t) if t else 0.0
        print(f"  {gname:5s} : mism={m} total={t} ({pct:.2f}%)")

    return total, mismatches


def main():
    parser = argparse.ArgumentParser(description="Compare HW/SW vmem+spike dumps")
    parser.add_argument("--hw", required=True, help="Hardware dump CSV (smem_all_samples.csv)")
    parser.add_argument("--sw", required=True, help="Software dump CSV (software_vmem_spikes.csv)")
    parser.add_argument("--max-mismatches", type=int, default=20,
                        help="Max mismatches to print (default: 20)")
    args = parser.parse_args()

    total, mismatches = compare_csv(args.hw, args.sw, args.max_mismatches)
    if mismatches == 0:
        print(f"PASS: {total} rows matched")
    else:
        print(f"FAIL: {mismatches} mismatches across {total} rows")


if __name__ == "__main__":
    main()
