import argparse
import csv
import re
from pathlib import Path


SUMMARY_RE = re.compile(
    r"SAMPLE\s+(\d+)\s+\|\s+true=(\d+)\s+\|\s+pred=(\d+)\s+\|\s+([A-Z_]+)"
)


def bounded_output_blame(true_label, pred_label, num_output_neurons):
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")

    # No learning push when prediction is already correct.
    if pred_label == true_label:
        return [0] * num_output_neurons

    blame = [0] * num_output_neurons
    if 0 <= true_label < num_output_neurons:
        blame[true_label] = 1

    if 0 <= pred_label < num_output_neurons:
        blame[pred_label] = -1

    return blame


def parse_log(log_path):
    text = Path(log_path).read_text(encoding="utf-8", errors="ignore")
    parsed = []
    for sample, true_label, pred_label, result in SUMMARY_RE.findall(text):
        parsed.append(
            {
                "sample": int(sample),
                "true": int(true_label),
                "pred": int(pred_label),
                "result": result,
            }
        )
    return parsed


def write_blame_csv(rows, output_csv, num_output_neurons):
    out_path = Path(output_csv)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    blame_cols = [f"blame_o{i}" for i in range(num_output_neurons)]
    fieldnames = ["sample", "true", "pred", "error", "result"] + blame_cols

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        for row in rows:
            error_value = row["true"] - row["pred"]
            blame = bounded_output_blame(
                true_label=row["true"],
                pred_label=row["pred"],
                num_output_neurons=num_output_neurons,
            )

            out_row = {
                "sample": row["sample"],
                "true": row["true"],
                "pred": row["pred"],
                "error": error_value,
                "result": row["result"],
            }
            for i, val in enumerate(blame):
                out_row[f"blame_o{i}"] = val

            writer.writerow(out_row)

    return out_path


def main():
    default_output = Path(__file__).resolve().parent / "data" / "inference_blame.csv"

    parser = argparse.ArgumentParser(
        description="Extract sample errors from inference.log and compute output-neuron blame"
    )
    parser.add_argument("--log", required=True, help="Path to inference.log")
    parser.add_argument(
        "--num-output-neurons",
        type=int,
        default=10,
        help="Number of output neurons for blame vector (default: 10)",
    )
    parser.add_argument(
        "--output",
        default=str(default_output),
        help=f"Output CSV path (default: {default_output})",
    )
    args = parser.parse_args()

    rows = parse_log(args.log)
    if not rows:
        raise ValueError("No sample summary lines found in log")

    out_path = write_blame_csv(rows, args.output, args.num_output_neurons)
    print(f"Parsed samples: {len(rows)}")
    print(f"Wrote: {out_path}")
    print(f"Output neurons: {args.num_output_neurons}")


if __name__ == "__main__":
    main()
