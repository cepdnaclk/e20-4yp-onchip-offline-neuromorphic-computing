#!/usr/bin/env python3
"""Apply batch weight learning using the custom RISC-V backprop unit behavior.

This script updates network weights using:
- `tools/data/smem_backprop_surrogate.csv`
- `smem_all_samples.csv` for input spike streams
- `tools/data/inference_blame.csv`
- a weight file formatted like `best_weights_hw.txt`

It mirrors the sequential behavior in:
- `RISC_V/extention/customUnit.v`
- `RISC_V/extention/Extention_in_EX.v`

Notes:
- W2 is updated sample-by-sample, synapse-by-synapse.
- W1 is updated using input spikes and a constant input-layer gradient of 128.
- Saturation follows the hardware 16-bit clamp used in `sat16_to_32`.
"""

from __future__ import annotations

import argparse
import csv
from functools import lru_cache
import re
from pathlib import Path
from typing import Dict, List, Tuple

# Hardware constants from Verilog
BETA = 192  # 0.75 * 256
LR_W1 = 8
LR_W2 = 16
HIDDEN_BLAME_CLIP = 64
DELTA_CLIP = 64
CENTER_HIDDEN_BLAME = True
W2_MIN = -100
W2_MAX = 100
W1_MIN = -50
W1_MAX = 50
CENTER_OUTPUT_BLAME = True
TARGETED_W2 = False

N_HIDDEN = 200
N_OUTPUT = 10
N_TS = 16
N_INPUT = 784
INPUT_GRADIENT = 128


def clamp16(value: int) -> int:
    if value > 32767:
        return 32767
    if value < -32768:
        return -32768
    return int(value)


def clamp_symmetric(value: int, limit: int) -> int:
    if limit <= 0:
        return int(value)
    if value > limit:
        return int(limit)
    if value < -limit:
        return int(-limit)
    return int(value)


def clamp_w2(value: int) -> int:
    if value > W2_MAX:
        return W2_MAX
    if value < W2_MIN:
        return W2_MIN
    return int(value)


def clamp_w1(value: int) -> int:
    if value > W1_MAX:
        return W1_MAX
    if value < W1_MIN:
        return W1_MIN
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
            # Skip visual separators or any line before a valid section.
            if set(line) <= {"-"}:
                continue
            if section is None:
                continue

            # Be tolerant to occasional commas/tabs and ignore malformed lines.
            tokens = line.replace(",", " ").split()
            try:
                row = [int(x) for x in tokens]
            except ValueError:
                continue
            if section == "w1":
                w1.append(row)
            else:
                w2.append(row)

    if len(w1) != 784:
        raise ValueError(f"Expected 784 W1 rows, got {len(w1)}")
    if any(len(r) != 200 for r in w1):
        raise ValueError("W1 row width mismatch; expected 200 columns per row")

    if len(w2) != 200:
        raise ValueError(f"Expected 200 W2 rows, got {len(w2)}")
    if any(len(r) != 10 for r in w2):
        raise ValueError("W2 row width mismatch; expected 10 columns per row")

    return w1, w2


def load_blame(path: Path) -> Dict[int, List[int]]:
    blame_by_sample: Dict[int, List[int]] = {}
    with path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        required = ["sample"] + [f"blame_o{j}" for j in range(N_OUTPUT)]
        for col in required:
            if col not in reader.fieldnames:
                raise ValueError(f"Missing column in blame CSV: {col}")

        for row in reader:
            s = int(row["sample"])
            blame_by_sample[s] = [int(row[f"blame_o{j}"]) for j in range(N_OUTPUT)]

    return blame_by_sample


def load_smem(path: Path) -> Dict[int, Dict[int, Dict[str, int]]]:
    # sample -> ts -> {needed columns}
    data: Dict[int, Dict[int, Dict[str, int]]] = {}
    with path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)

        required = ["sample", "ts"]
        required += [f"spike_h{i}" for i in range(N_HIDDEN)]
        required += [f"vmem_o{j}" for j in range(N_OUTPUT)]
        for col in required:
            if col not in reader.fieldnames:
                raise ValueError(f"Missing column in surrogate CSV: {col}")

        for row in reader:
            s = int(row["sample"])
            t = int(row["ts"])
            if s not in data:
                data[s] = {}

            values: Dict[str, int] = {}
            for i in range(N_HIDDEN):
                values[f"spike_h{i}"] = int(row[f"spike_h{i}"])
            for j in range(N_OUTPUT):
                values[f"vmem_o{j}"] = int(row[f"vmem_o{j}"])

            data[s][t] = values

    return data


def load_input_spikes(path: Path) -> Dict[int, Dict[int, bytearray]]:
    data: Dict[int, Dict[int, bytearray]] = {}
    input_columns: List[str] | None = None

    with path.open("r", newline="", encoding="utf-8", errors="ignore") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise ValueError("Input SMEM CSV has no header")

        if "sample" not in reader.fieldnames or "ts" not in reader.fieldnames:
            raise ValueError("Input SMEM CSV must contain 'sample' and 'ts' columns")

        input_columns = sorted(
            [c for c in reader.fieldnames if re.fullmatch(r"inp_\d+", c)],
            key=lambda name: int(name.split("_")[1]),
        )
        if len(input_columns) != N_INPUT:
            raise ValueError(f"Expected {N_INPUT} input spike columns, got {len(input_columns)}")

        for row in reader:
            sample = int(row["sample"])
            ts = int(row["ts"])
            if sample not in data:
                data[sample] = {}
            if ts in data[sample]:
                continue

            data[sample][ts] = bytearray(int(row[col]) & 0x1 for col in input_columns)

    return data


def hidden_blame_from_w2(w2: List[List[int]], output_blame: List[int]) -> List[int]:
    return [
        sum(w2[hidden_idx][out_idx] * output_blame[out_idx] for out_idx in range(N_OUTPUT))
        for hidden_idx in range(N_HIDDEN)
    ]


def center_values(values: List[int]) -> List[int]:
    if not values:
        return values
    mean = int(round(sum(values) / float(len(values))))
    return [v - mean for v in values]


def pack_input_spike_patterns(input_ts_map: Dict[int, bytearray]) -> List[int]:
    patterns = [0] * N_INPUT
    for t in range(N_TS):
        ts_values = input_ts_map[t]
        for input_idx in range(N_INPUT):
            patterns[input_idx] |= (int(ts_values[input_idx]) & 0x1) << t
    return patterns


@lru_cache(maxsize=None)
def cached_delta_offset(
    error_term: int,
    gradients: Tuple[int, ...],
    spike_pattern: int,
    lr: int,
    delta_clip: int,
) -> int:
    """Return net offset to subtract from a weight for one 16-timestep stream."""
    updated_weight = 0
    error_latched = clamp16(error_term)
    apply_update_d = False
    dm_prev = 0
    delta_out = 0

    for t in range(N_TS):
        spike = (spike_pattern >> t) & 0x1
        grad = clamp16(gradients[t])

        if apply_update_d:
            clipped_delta = clamp_symmetric(delta_out, delta_clip)
            lr_delta = (clipped_delta * lr) >> 8
            updated_weight -= lr_delta

        temporal_term = (dm_prev * BETA) >> 8
        effective_error = error_latched + temporal_term
        delta_calc = (effective_error * grad) >> 8

        delta_out = delta_calc if spike else 0
        dm_prev = 0 if spike else delta_calc
        apply_update_d = True

    if apply_update_d:
        clipped_delta = clamp_symmetric(delta_out, delta_clip)
        lr_delta = (clipped_delta * lr) >> 8
        updated_weight -= lr_delta

    return -updated_weight


@lru_cache(maxsize=None)
def cached_w1_delta(error_term: int, spike_pattern: int, lr_w1: int, delta_clip: int) -> int:
    """Return the net update amount for W1 with constant gradient 128.

    The returned value is the amount subtracted from the current weight before
    final 16-bit saturation.
    """
    grads = tuple([INPUT_GRADIENT] * N_TS)
    return cached_delta_offset(error_term, grads, spike_pattern, lr_w1, delta_clip)


def custom_unit_update(
    weight0: int,
    error_term: int,
    gradients: List[int],
    spikes: List[int],
    lr: int,
    delta_clip: int,
    clamp_weight=clamp16,
) -> int:
    """Simulate one dataset run through customCalculation/custom_backprop_unit.

    This mirrors the cycle behavior used by the CPU + LIFO stream path:
    - 16 grad_valid cycles (one per timestep)
    - one final flush cycle to apply the last pending delta
    """
    if len(gradients) != N_TS or len(spikes) != N_TS:
        raise ValueError("gradients/spikes must be length 16")

    updated_weight = clamp_weight(clamp16(weight0))
    error_latched = clamp16(error_term)
    apply_update_d = False

    # State inside custom_backprop_unit
    dm_prev = 0
    delta_out = 0

    for t in range(N_TS):
        grad = clamp16(gradients[t])
        spike = 1 if spikes[t] else 0

        # customCalculation update stage (uses previous cycle delta_out)
        if apply_update_d:
            clipped_delta = clamp_symmetric(delta_out, delta_clip)
            lr_delta = (clipped_delta * lr) >> 8
            updated_weight = clamp_weight(clamp16(updated_weight - lr_delta))

        # custom_backprop_unit current cycle
        temporal_term = (dm_prev * BETA) >> 8
        effective_error = error_latched + temporal_term
        delta_calc = (effective_error * grad) >> 8

        delta_out = delta_calc if spike else 0
        dm_prev = 0 if spike else delta_calc

        apply_update_d = True

    # Final flush cycle (grad_valid deasserted but delayed apply still occurs)
    if apply_update_d:
        clipped_delta = clamp_symmetric(delta_out, delta_clip)
        lr_delta = (clipped_delta * lr) >> 8
        updated_weight = clamp_weight(clamp16(updated_weight - lr_delta))

    return updated_weight


def write_weight_file(path: Path, w1: List[List[int]], w2: List[List[int]]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write("W1 Weights (784 x 200):\n")
        for row in w1:
            f.write(" ".join(str(x) for x in row) + "\n")
        f.write("\n-------------------------------------\n\n")
        f.write("W2 Weights (200 x 10):\n")
        for row in w2:
            f.write(" ".join(str(x) for x in row) + "\n")


def apply_final_clamp(w1: List[List[int]], w2: List[List[int]]) -> None:
    for i in range(N_INPUT):
        for j in range(N_HIDDEN):
            w1[i][j] = clamp_w1(clamp16(w1[i][j]))
    for i in range(N_HIDDEN):
        for j in range(N_OUTPUT):
            w2[i][j] = clamp_w2(clamp16(w2[i][j]))


def apply_accumulated_updates(
    w1: List[List[int]],
    w2: List[List[int]],
    accum_w1: List[List[int]],
    accum_w2: List[List[int]],
    divisor: float,
    targeted_w2: bool,
) -> None:
    if divisor <= 0:
        raise ValueError("divisor must be > 0")

    if not targeted_w2:
        for i in range(N_INPUT):
            for j in range(N_HIDDEN):
                avg_offset = int(round(accum_w1[i][j] / divisor))
                w1[i][j] = clamp_w1(clamp16(w1[i][j] - avg_offset))

    for i in range(N_HIDDEN):
        for j in range(N_OUTPUT):
            avg_offset = int(round(accum_w2[i][j] / divisor))
            w2[i][j] = clamp_w2(clamp16(w2[i][j] - avg_offset))


def run_learning(
    weights_path: Path,
    smem_path: Path,
    blame_path: Path,
    out_path: Path,
    full_smem_path: Path,
    lr_w1: int,
    lr_w2: int,
    hidden_blame_clip: int,
    delta_clip: int,
    center_hidden_blame: bool,
    center_output_blame: bool,
    targeted_w2: bool,
    update_mode: str,
    micro_batch_size: int,
    sample_id: int | None,
    sample_offset: int,
    max_samples: int | None,
) -> None:
    w1_base, w2_base = parse_weight_file(weights_path)
    w1 = [row[:] for row in w1_base]
    w2 = [row[:] for row in w2_base]
    blame_by_sample = load_blame(blame_path)
    smem_by_sample = load_smem(smem_path)
    input_spikes_by_sample = load_input_spikes(full_smem_path)

    common_samples = sorted(
        set(blame_by_sample.keys()) & set(smem_by_sample.keys()) & set(input_spikes_by_sample.keys())
    )
    if sample_id is not None:
        common_samples = [s for s in common_samples if s == sample_id]
    if sample_offset > 0:
        common_samples = common_samples[sample_offset:]
    if max_samples is not None and max_samples > 0:
        common_samples = common_samples[:max_samples]
    if not common_samples:
        raise ValueError("No overlapping sample IDs between smem and blame files")

    if update_mode not in {"frozen-batch", "online", "micro-batch"}:
        raise ValueError(f"Unsupported update_mode: {update_mode}")
    if micro_batch_size <= 0:
        raise ValueError("micro_batch_size must be > 0")

    # Frozen-batch update accumulates deltas using fixed base weights, then applies once.
    # Online update applies each sample immediately to the live weights.
    accum_w1 = [[0 for _ in range(N_HIDDEN)] for _ in range(N_INPUT)]
    accum_w2 = [[0 for _ in range(N_OUTPUT)] for _ in range(N_HIDDEN)]
    used_samples = 0
    contributing_samples = 0
    pending_contributors = 0

    for s in common_samples:
        ts_map = smem_by_sample[s]
        input_ts_map = input_spikes_by_sample[s]
        if any(t not in ts_map for t in range(N_TS)):
            # Skip incomplete samples to avoid malformed updates
            continue
        if any(t not in input_ts_map for t in range(N_TS)):
            continue
        used_samples += 1

        # Pre-extract gradients per output neuron for this sample
        grads_per_output = [tuple(int(ts_map[t][f"vmem_o{j}"]) for t in range(N_TS)) for j in range(N_OUTPUT)]
        blame_vec = blame_by_sample[s]
        if center_output_blame:
            blame_vec = center_values(blame_vec)
        has_nonzero_blame = any(v != 0 for v in blame_vec)
        if has_nonzero_blame:
            contributing_samples += 1

        # If blame is fully zero, this sample contributes no learning signal.
        if not has_nonzero_blame:
            continue

        w2_ref = w2 if update_mode in {"online", "micro-batch"} else w2_base
        hidden_blame = hidden_blame_from_w2(w2_ref, blame_vec)
        if center_hidden_blame:
            hidden_blame = center_values(hidden_blame)
        if hidden_blame_clip > 0:
            hidden_blame = [clamp_symmetric(v, hidden_blame_clip) for v in hidden_blame]

        if targeted_w2:
            output_indices = [j for j, v in enumerate(blame_vec) if v != 0]
        else:
            output_indices = list(range(N_OUTPUT))

        for i in range(N_HIDDEN):
            spike_pattern = 0
            for t in range(N_TS):
                spike_pattern |= (int(ts_map[t][f"spike_h{i}"]) & 0x1) << t
            for j in output_indices:
                delta_offset = cached_delta_offset(
                    blame_vec[j],
                    grads_per_output[j],
                    spike_pattern,
                    lr_w2,
                    delta_clip,
                )
                if update_mode == "online":
                    w2[i][j] = clamp_w2(clamp16(w2[i][j] - delta_offset))
                else:
                    accum_w2[i][j] += delta_offset

        # Targeted mode keeps W1 fixed and only adjusts selected W2 channels.
        if not targeted_w2:
            input_patterns = pack_input_spike_patterns(input_ts_map)
            hidden_deltas = [
                cached_w1_delta(hidden_blame[hidden_idx], 0, lr_w1, delta_clip)
                for hidden_idx in range(N_HIDDEN)
            ]
            for input_idx in range(N_INPUT):
                spike_pattern = input_patterns[input_idx]
                for hidden_idx in range(N_HIDDEN):
                    delta_offset = (
                        hidden_deltas[hidden_idx]
                        if spike_pattern == 0
                        else cached_w1_delta(hidden_blame[hidden_idx], spike_pattern, lr_w1, delta_clip)
                    )
                    if update_mode == "online":
                        w1[input_idx][hidden_idx] = clamp_w1(clamp16(w1[input_idx][hidden_idx] - delta_offset))
                    else:
                        accum_w1[input_idx][hidden_idx] += delta_offset

        if update_mode == "micro-batch":
            pending_contributors += 1
            if pending_contributors >= micro_batch_size:
                apply_accumulated_updates(w1, w2, accum_w1, accum_w2, float(pending_contributors), targeted_w2)
                accum_w1 = [[0 for _ in range(N_HIDDEN)] for _ in range(N_INPUT)]
                accum_w2 = [[0 for _ in range(N_OUTPUT)] for _ in range(N_HIDDEN)]
                pending_contributors = 0

    if used_samples == 0:
        raise ValueError("No complete samples were usable for learning")
    if contributing_samples == 0:
        raise ValueError(
            "No samples produced nonzero blame; no weight updates can be applied"
        )

    if update_mode == "frozen-batch":
        # Average only across samples that actually contributed nonzero blame.
        avg_divisor = float(contributing_samples)
        if targeted_w2:
            w1 = [row[:] for row in w1_base]
        else:
            w1 = [row[:] for row in w1_base]
        w2 = [row[:] for row in w2_base]
        apply_accumulated_updates(w1, w2, accum_w1, accum_w2, avg_divisor, targeted_w2)
    elif update_mode == "micro-batch" and pending_contributors > 0:
        apply_accumulated_updates(w1, w2, accum_w1, accum_w2, float(pending_contributors), targeted_w2)

    apply_final_clamp(w1, w2)
    write_weight_file(out_path, w1, w2)

    print(f"Samples used for learning: {used_samples}")
    print(f"Samples with nonzero blame: {contributing_samples}")
    print(f"Targeted W2 mode: {'ON' if targeted_w2 else 'OFF'}")
    if sample_id is not None:
        print(f"Selected sample id: {sample_id}")
    if sample_offset > 0:
        print(f"Sample offset applied: {sample_offset}")
    if max_samples is not None and max_samples > 0:
        print(f"Max samples requested: {max_samples}")
    if update_mode == "online":
        print("Update mode: online (per-sample updates applied immediately)")
    elif update_mode == "micro-batch":
        print(f"Update mode: micro-batch (average delta applied every {micro_batch_size} contributing samples)")
    else:
        print("Update mode: frozen-batch (average delta per sample applied once)")
    print(f"Updated weight file written to:\n  {out_path}")


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    default_weights = Path.home() / "Downloads" / "best_weights_hw.txt"
    default_full_smem = Path.home() / "Downloads" / "smem_all_samples.csv"

    parser = argparse.ArgumentParser(description="Learn updated weights using custom unit behavior")
    parser.add_argument("--weights", type=Path, default=default_weights, help="Input weights txt file")
    parser.add_argument(
        "--smem",
        type=Path,
        default=repo_root / "tools" / "data" / "smem_backprop_surrogate.csv",
        help="Surrogate SMEM CSV",
    )
    parser.add_argument(
        "--blame",
        type=Path,
        default=repo_root / "tools" / "data" / "inference_blame.csv",
        help="Inference blame CSV",
    )
    parser.add_argument(
        "--full-smem",
        type=Path,
        default=default_full_smem,
        help="Full SMEM CSV containing inp_* columns for W1 updates",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=repo_root / "tools" / "data" / "best_weights_hw_updated.txt",
        help="Output updated weights txt",
    )
    parser.add_argument("--lr-w1", type=int, default=LR_W1, help="W1 learning rate in Q8 (default: 8)")
    parser.add_argument("--lr-w2", type=int, default=LR_W2, help="W2 learning rate in Q8 (default: 16)")
    parser.add_argument(
        "--clip-hidden",
        type=int,
        default=HIDDEN_BLAME_CLIP,
        help="Symmetric clip for hidden blame; <=0 disables clipping (default: 64)",
    )
    parser.add_argument(
        "--clip-delta",
        type=int,
        default=DELTA_CLIP,
        help="Symmetric clip for delta_out before LR multiply; <=0 disables clipping (default: 64)",
    )
    parser.add_argument(
        "--no-center-hidden-blame",
        action="store_true",
        help="Disable zero-mean centering of hidden blame per sample",
    )
    parser.add_argument(
        "--no-center-output-blame",
        action="store_true",
        help="Disable zero-mean centering of output blame vector per sample",
    )
    parser.add_argument(
        "--targeted-w2",
        action="store_true",
        help=(
            "Targeted update mode: only update W2 channels with nonzero blame "
            "(e.g., true/pred in class-directional blame), keep W1 fixed"
        ),
    )
    parser.add_argument(
        "--update-mode",
        choices=["frozen-batch", "online", "micro-batch"],
        default="frozen-batch",
        help=(
            "Weight update mode: 'frozen-batch' averages deltas over contributing samples, "
            "'online' applies each sample update immediately to the live weights, "
            "'micro-batch' averages and applies every K contributing samples"
        ),
    )
    parser.add_argument(
        "--micro-batch-size",
        type=int,
        default=32,
        help="Number of contributing samples per applied update in micro-batch mode (default: 32)",
    )
    parser.add_argument(
        "--sample-id",
        type=int,
        default=None,
        help="Use only one sample id for the update (default: use all overlapping samples)",
    )
    parser.add_argument(
        "--sample-offset",
        type=int,
        default=0,
        help="Skip the first N sorted overlapping sample ids before learning (default: 0)",
    )
    parser.add_argument(
        "--max-samples",
        type=int,
        default=None,
        help="Use only the first N sorted sample ids (default: all)",
    )

    args = parser.parse_args()

    if not args.weights.exists():
        raise FileNotFoundError(f"Weights file not found: {args.weights}")
    if not args.smem.exists():
        raise FileNotFoundError(f"SMEM file not found: {args.smem}")
    if not args.blame.exists():
        raise FileNotFoundError(f"Blame file not found: {args.blame}")
    if not args.full_smem.exists():
        raise FileNotFoundError(f"Full SMEM file not found: {args.full_smem}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    run_learning(
        args.weights,
        args.smem,
        args.blame,
        args.output,
        args.full_smem,
        args.lr_w1,
        args.lr_w2,
        args.clip_hidden,
        args.clip_delta,
        not args.no_center_hidden_blame,
        not args.no_center_output_blame,
        args.targeted_w2,
        args.update_mode,
        args.micro_batch_size,
        args.sample_id,
        args.sample_offset,
        args.max_samples,
    )


if __name__ == "__main__":
    main()
