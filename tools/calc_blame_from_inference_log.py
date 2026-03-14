import argparse
import csv
import re
from pathlib import Path


SUMMARY_RE = re.compile(
    r"SAMPLE\s+(\d+)\s+\|\s+true=(\d+)\s+\|\s+pred=(\d+)\s+\|\s+([A-Z_]+)"
)


def output_blame_original(true_label, pred_label, num_output_neurons):
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")

    shared_error = true_label - pred_label
    return [shared_error] * num_output_neurons


def output_blame_original_scaled(true_label, pred_label, num_output_neurons, scale_percent):
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")
    if scale_percent <= 0:
        raise ValueError("scale_percent must be > 0")

    shared_error = true_label - pred_label
    scaled_error = int(round(shared_error * (float(scale_percent) / 100.0)))
    return [scaled_error] * num_output_neurons


def output_blame_class_directional(true_label, pred_label, num_output_neurons, scale):
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")
    if scale <= 0:
        raise ValueError("scale must be > 0")

    blame = [0] * num_output_neurons
    if true_label == pred_label:
        return blame

    if 0 <= true_label < num_output_neurons:
        blame[true_label] = scale
    if 0 <= pred_label < num_output_neurons:
        blame[pred_label] = -scale
    return blame


def output_blame_class_directional_inverted(true_label, pred_label, num_output_neurons, scale):
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")
    if scale <= 0:
        raise ValueError("scale must be > 0")

    blame = [0] * num_output_neurons
    if true_label == pred_label:
        return blame

    # Inverted sign variant to test whether update polarity is reversed downstream.
    if 0 <= true_label < num_output_neurons:
        blame[true_label] = -scale
    if 0 <= pred_label < num_output_neurons:
        blame[pred_label] = scale
    return blame


def output_blame_directional_error_magnitude(true_label, pred_label, num_output_neurons, scale_percent):
    """Use original error magnitude, but only on true/pred channels.

    This keeps the directional property (+true, -pred) while using
    |true-pred| scaled by percentage to control aggressiveness.
    """
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")
    if scale_percent <= 0:
        raise ValueError("scale_percent must be > 0")

    blame = [0] * num_output_neurons
    if true_label == pred_label:
        return blame

    mag = int(round(abs(true_label - pred_label) * (float(scale_percent) / 100.0)))
    if mag == 0:
        mag = 1

    if 0 <= true_label < num_output_neurons:
        blame[true_label] = mag
    if 0 <= pred_label < num_output_neurons:
        blame[pred_label] = -mag
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


def load_output_margin_scores(smem_csv, num_output_neurons):
    score_by_sample = {}
    with Path(smem_csv).open("r", newline="", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        required = ["sample"] + [f"vmem_o{i}" for i in range(num_output_neurons)]
        for col in required:
            if col not in (reader.fieldnames or []):
                raise ValueError(f"Missing required SMEM column: {col}")

        for row in reader:
            sample = int(row["sample"])
            if sample not in score_by_sample:
                score_by_sample[sample] = [None] * num_output_neurons
            for index in range(num_output_neurons):
                value = int(row[f"vmem_o{index}"])
                prev = score_by_sample[sample][index]
                if prev is None or value > prev:
                    score_by_sample[sample][index] = value

    return {
        sample: [0 if value is None else int(value) for value in values]
        for sample, values in score_by_sample.items()
    }


def load_output_spike_rates(smem_csv, num_output_neurons):
    spike_sum_by_sample = {}
    timestep_count_by_sample = {}
    with Path(smem_csv).open("r", newline="", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        required = ["sample", "ts"] + [f"spike_o{i}" for i in range(num_output_neurons)]
        for col in required:
            if col not in (reader.fieldnames or []):
                raise ValueError(f"Missing required SMEM column: {col}")

        for row in reader:
            sample = int(row["sample"])
            if sample not in spike_sum_by_sample:
                spike_sum_by_sample[sample] = [0] * num_output_neurons
                timestep_count_by_sample[sample] = 0
            timestep_count_by_sample[sample] += 1
            for index in range(num_output_neurons):
                spike_sum_by_sample[sample][index] += int(row[f"spike_o{index}"])

    rate_by_sample = {}
    for sample, spike_sums in spike_sum_by_sample.items():
        timesteps = timestep_count_by_sample[sample]
        if timesteps <= 0:
            raise ValueError(f"Sample {sample} has no timesteps in SMEM")
        rate_by_sample[sample] = [int((count * 256) / timesteps) for count in spike_sums]
    return rate_by_sample


def output_blame_margin_directional(
    true_label,
    pred_label,
    num_output_neurons,
    scores,
    scale_percent,
    margin_divisor,
    max_blame,
    margin_update_threshold,
):
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")
    if scale_percent <= 0:
        raise ValueError("scale_percent must be > 0")
    if margin_divisor <= 0:
        raise ValueError("margin_divisor must be > 0")
    if max_blame <= 0:
        raise ValueError("max_blame must be > 0")

    blame = [0] * num_output_neurons
    if true_label == pred_label:
        return blame

    pred_score = scores[pred_label] if 0 <= pred_label < len(scores) else 0
    true_score = scores[true_label] if 0 <= true_label < len(scores) else 0
    raw_margin = max(1, pred_score - true_score)
    if margin_update_threshold >= 0 and raw_margin > margin_update_threshold:
        return blame
    scaled = int(round((raw_margin * float(scale_percent) / 100.0) / float(margin_divisor)))
    magnitude = max(1, min(max_blame, scaled))

    if 0 <= true_label < num_output_neurons:
        blame[true_label] = magnitude
    if 0 <= pred_label < num_output_neurons:
        blame[pred_label] = -magnitude
    return blame


def output_blame_rate_target(true_label, num_output_neurons, rates, scale_percent, invert):
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")
    if scale_percent <= 0:
        raise ValueError("scale_percent must be > 0")

    blame = [0] * num_output_neurons
    sign = -1 if invert else 1
    for index in range(num_output_neurons):
        target = 256 if index == true_label else 0
        delta = int(round((2.0 * (rates[index] - target)) * (float(scale_percent) / 100.0)))
        blame[index] = sign * delta
    return blame


def output_blame_rate_target_sparse(
    true_label,
    pred_label,
    num_output_neurons,
    rates,
    scale_percent,
    invert,
    max_abs_blame,
):
    if num_output_neurons <= 0:
        raise ValueError("num_output_neurons must be > 0")
    if scale_percent <= 0:
        raise ValueError("scale_percent must be > 0")

    blame = [0] * num_output_neurons
    if true_label == pred_label:
        return blame

    sign = -1 if invert else 1

    # True channel should move toward target rate 256.
    if 0 <= true_label < num_output_neurons:
        delta_true = int(round((2.0 * (rates[true_label] - 256)) * (float(scale_percent) / 100.0)))
        blame[true_label] = sign * delta_true

    # Predicted channel should move toward target rate 0.
    if 0 <= pred_label < num_output_neurons:
        delta_pred = int(round((2.0 * (rates[pred_label] - 0)) * (float(scale_percent) / 100.0)))
        blame[pred_label] = sign * delta_pred

    if max_abs_blame > 0:
        for idx in range(num_output_neurons):
            if blame[idx] > max_abs_blame:
                blame[idx] = max_abs_blame
            elif blame[idx] < -max_abs_blame:
                blame[idx] = -max_abs_blame

    return blame


def write_blame_csv(
    rows,
    output_csv,
    num_output_neurons,
    mode,
    blame_scale,
    original_scale_percent,
    smem_csv,
    margin_divisor,
    max_blame,
    margin_update_threshold,
    only_fail,
    rate_target_max_blame,
):
    out_path = Path(output_csv)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    blame_cols = [f"blame_o{i}" for i in range(num_output_neurons)]
    fieldnames = ["sample", "true", "pred", "error", "result"] + blame_cols
    margin_scores = None
    spike_rates = None
    if mode == "margin-directional":
        if not smem_csv:
            raise ValueError("--smem is required for margin-directional mode")
        margin_scores = load_output_margin_scores(smem_csv, num_output_neurons)
    if mode in {
        "rate-target",
        "rate-target-inverted",
        "rate-target-sparse",
        "rate-target-sparse-inverted",
    }:
        if not smem_csv:
            raise ValueError("--smem is required for rate-target modes")
        spike_rates = load_output_spike_rates(smem_csv, num_output_neurons)

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        for row in rows:
            error_value = row["true"] - row["pred"]
            if only_fail and row["result"] != "FAIL":
                blame = [0] * num_output_neurons
            elif mode == "original-shared":
                blame = output_blame_original(
                    true_label=row["true"],
                    pred_label=row["pred"],
                    num_output_neurons=num_output_neurons,
                )
            elif mode == "original-shared-scaled":
                blame = output_blame_original_scaled(
                    true_label=row["true"],
                    pred_label=row["pred"],
                    num_output_neurons=num_output_neurons,
                    scale_percent=original_scale_percent,
                )
            elif mode == "class-directional-inverted":
                blame = output_blame_class_directional_inverted(
                    true_label=row["true"],
                    pred_label=row["pred"],
                    num_output_neurons=num_output_neurons,
                    scale=blame_scale,
                )
            elif mode == "directional-error-magnitude":
                blame = output_blame_directional_error_magnitude(
                    true_label=row["true"],
                    pred_label=row["pred"],
                    num_output_neurons=num_output_neurons,
                    scale_percent=original_scale_percent,
                )
            elif mode == "margin-directional":
                if row["sample"] not in margin_scores:
                    raise ValueError(f"Sample {row['sample']} not found in SMEM scores")
                blame = output_blame_margin_directional(
                    true_label=row["true"],
                    pred_label=row["pred"],
                    num_output_neurons=num_output_neurons,
                    scores=margin_scores[row["sample"]],
                    scale_percent=original_scale_percent,
                    margin_divisor=margin_divisor,
                    max_blame=max_blame,
                    margin_update_threshold=margin_update_threshold,
                )
            elif mode in {"rate-target", "rate-target-inverted"}:
                if row["sample"] not in spike_rates:
                    raise ValueError(f"Sample {row['sample']} not found in SMEM rates")
                blame = output_blame_rate_target(
                    true_label=row["true"],
                    num_output_neurons=num_output_neurons,
                    rates=spike_rates[row["sample"]],
                    scale_percent=original_scale_percent,
                    invert=(mode == "rate-target-inverted"),
                )
                if rate_target_max_blame > 0:
                    blame = [max(-rate_target_max_blame, min(rate_target_max_blame, v)) for v in blame]
            elif mode in {"rate-target-sparse", "rate-target-sparse-inverted"}:
                if row["sample"] not in spike_rates:
                    raise ValueError(f"Sample {row['sample']} not found in SMEM rates")
                blame = output_blame_rate_target_sparse(
                    true_label=row["true"],
                    pred_label=row["pred"],
                    num_output_neurons=num_output_neurons,
                    rates=spike_rates[row["sample"]],
                    scale_percent=original_scale_percent,
                    invert=(mode == "rate-target-sparse-inverted"),
                    max_abs_blame=rate_target_max_blame,
                )
            else:
                blame = output_blame_class_directional(
                    true_label=row["true"],
                    pred_label=row["pred"],
                    num_output_neurons=num_output_neurons,
                    scale=blame_scale,
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
    parser.add_argument(
        "--mode",
        choices=[
            "class-directional",
            "class-directional-inverted",
            "original-shared",
            "original-shared-scaled",
            "directional-error-magnitude",
            "margin-directional",
            "rate-target",
            "rate-target-inverted",
            "rate-target-sparse",
            "rate-target-sparse-inverted",
        ],
        default="class-directional",
        help=(
            "Blame mapping mode: 'class-directional' sets +scale on true class and "
            "-scale on predicted class (0 elsewhere), 'class-directional-inverted' flips "
            "that sign assignment, 'original-shared' uses true-pred for all outputs, "
            "'original-shared-scaled' applies a percentage of true-pred, and "
            "'directional-error-magnitude' applies a scaled |true-pred| only to true/pred channels, "
            "'margin-directional' uses output vmem margin from SMEM on true/pred channels, and "
            "'rate-target' matches C backprop style output error from output spike rates. "
            "'rate-target-sparse' applies rate-target only to true/pred channels."
        ),
    )
    parser.add_argument(
        "--blame-scale",
        type=int,
        default=1,
        help="Scale used by class-directional mode (default: 1)",
    )
    parser.add_argument(
        "--original-scale-percent",
        type=int,
        default=100,
        help=(
            "Scale used by 'original-shared-scaled' mode as a percentage of (true-pred). "
            "Examples: 100=full original, 50=half, 25=quarter."
        ),
    )
    parser.add_argument(
        "--smem",
        default=None,
        help="SMEM CSV path required by 'margin-directional' mode",
    )
    parser.add_argument(
        "--margin-divisor",
        type=int,
        default=64,
        help="Divisor applied to output vmem margin before converting to blame magnitude (default: 64)",
    )
    parser.add_argument(
        "--max-blame",
        type=int,
        default=4,
        help="Maximum absolute blame value for margin-directional mode (default: 4)",
    )
    parser.add_argument(
        "--margin-update-threshold",
        type=int,
        default=-1,
        help=(
            "For margin-directional mode, only update when (pred_score - true_score) <= threshold. "
            "Set -1 to disable this gate (default: -1)."
        ),
    )
    parser.add_argument(
        "--only-fail",
        action="store_true",
        help="Emit zero blame for PASS rows; update only on FAIL rows",
    )
    parser.add_argument(
        "--rate-target-max-blame",
        type=int,
        default=0,
        help="Symmetric cap for rate-target* blame values (0 disables cap)",
    )
    args = parser.parse_args()

    rows = parse_log(args.log)
    if not rows:
        raise ValueError("No sample summary lines found in log")

    out_path = write_blame_csv(
        rows,
        args.output,
        args.num_output_neurons,
        args.mode,
        args.blame_scale,
        args.original_scale_percent,
        args.smem,
        args.margin_divisor,
        args.max_blame,
        args.margin_update_threshold,
        args.only_fail,
        args.rate_target_max_blame,
    )
    print(f"Parsed samples: {len(rows)}")
    print(f"Wrote: {out_path}")
    print(f"Output neurons: {args.num_output_neurons}")
    print(f"Blame mode: {args.mode}")
    if args.mode == "class-directional":
        print(f"Blame scale: {args.blame_scale}")
    if args.mode in ("original-shared-scaled", "directional-error-magnitude"):
        print(f"Original shared scale percent: {args.original_scale_percent}")
    if args.mode == "margin-directional":
        print(f"SMEM source: {args.smem}")
        print(f"Margin divisor: {args.margin_divisor}")
        print(f"Max blame: {args.max_blame}")
        print(f"Margin update threshold: {args.margin_update_threshold}")
    if args.mode in (
        "rate-target",
        "rate-target-inverted",
        "rate-target-sparse",
        "rate-target-sparse-inverted",
    ):
        print(f"SMEM source: {args.smem}")
        print(f"Rate-target scale percent: {args.original_scale_percent}")
        print(f"Rate-target max blame: {args.rate_target_max_blame}")
    if args.only_fail:
        print("Only FAIL rows: ON")


if __name__ == "__main__":
    main()
