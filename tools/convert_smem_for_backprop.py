import argparse
import csv
import re
from pathlib import Path
from collections import Counter


def find_columns(header):
    spike_h = [c for c in header if c.startswith("spike_h")]
    spike_o = [c for c in header if c.startswith("spike_o")]
    vmem_h = [c for c in header if c.startswith("vmem_h")]
    vmem_o = [c for c in header if c.startswith("vmem_o")]
    return spike_h, spike_o, vmem_h, vmem_o


def load_lut_from_verilog(lut_verilog_path):
    lut = [None] * 256
    pattern = re.compile(r"lut_rom\[\s*(\d+)\s*\]\s*=\s*8'h([0-9A-Fa-f]{1,2})")

    with open(lut_verilog_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            m = pattern.search(line)
            if not m:
                continue
            idx = int(m.group(1))
            value = int(m.group(2), 16)
            if 0 <= idx < 256:
                lut[idx] = value

    missing = [i for i, v in enumerate(lut) if v is None]
    if missing:
        raise ValueError(
            f"Incomplete LUT in {lut_verilog_path}; missing {len(missing)} entries"
        )

    return lut


def convert(input_csv, output_csv, lut_verilog_path=None):
    output_path = Path(output_csv)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    lut = None
    if lut_verilog_path:
        lut = load_lut_from_verilog(lut_verilog_path)

    with open(input_csv, newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise ValueError("Input CSV has no header")

        header = reader.fieldnames
        if "sample" not in header or "ts" not in header:
            raise ValueError("Input CSV must contain 'sample' and 'ts' columns")

        spike_h, spike_o, vmem_h, vmem_o = find_columns(header)
        if not spike_h or not spike_o or not vmem_h or not vmem_o:
            raise ValueError("Missing expected spike/vmem columns")

        selected_cols = ["sample", "ts"] + spike_h + spike_o + vmem_h + vmem_o

        kept = {}
        duplicate_counter = Counter()
        for row in reader:
            key = (int(row["sample"]), int(row["ts"]))
            if key in kept:
                duplicate_counter[key] += 1
                # Keep the first occurrence. In this dataset, first ts=15 row is valid.
                continue
            kept[key] = row

    ordered_keys = sorted(kept.keys())

    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=selected_cols)
        writer.writeheader()
        for key in ordered_keys:
            row = kept[key]
            out_row = {c: row[c] for c in selected_cols}
            if lut is not None:
                # V_mem is interpreted as raw 8-bit unsigned index for LUT lookup.
                for c in vmem_h + vmem_o:
                    raw = int(out_row[c]) & 0xFF
                    out_row[c] = str(lut[raw])
            writer.writerow(out_row)

    samples = sorted({s for s, _ in ordered_keys})
    rows_per_sample = Counter(s for s, _ in ordered_keys)
    per_sample_distribution = Counter(rows_per_sample.values())

    print(f"Wrote: {output_path}")
    print(f"Rows out: {len(ordered_keys)}")
    print(f"Samples: {len(samples)} (range {samples[0]}..{samples[-1]})")
    print(f"Rows/sample distribution: {dict(per_sample_distribution)}")
    print(f"Duplicates removed: {sum(duplicate_counter.values())}")
    print(
        "Selected columns: "
        f"sample, ts, {len(spike_h)} spike_h, {len(spike_o)} spike_o, "
        f"{len(vmem_h)} vmem_h, {len(vmem_o)} vmem_o"
    )
    if lut is not None:
        print(f"LUT applied from: {lut_verilog_path}")


def main():
    default_output = Path(__file__).resolve().parent / "data" / "smem_backprop_clean.csv"

    parser = argparse.ArgumentParser(
        description="Deduplicate SMEM dump and keep only spike/vmem columns for backprop"
    )
    parser.add_argument("--input", required=True, help="Path to input smem CSV")
    parser.add_argument(
        "--output",
        default=str(default_output),
        help=f"Path to output cleaned CSV (default: {default_output})",
    )
    parser.add_argument(
        "--lut-verilog",
        default=None,
        help="Optional path to surrogate LUT Verilog file (e.g. surrogate_lut_wb.v)",
    )
    args = parser.parse_args()
    convert(args.input, args.output, args.lut_verilog)


if __name__ == "__main__":
    main()
