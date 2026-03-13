#!/usr/bin/env python3
"""Run hardware inference A/B studies across C weight files.

This script automates:
1) C-weight text -> data_mem_mnist_new.mem conversion
2) Running mnist_infertest testbench executable (simv_mnist_inf)
3) Extracting reported accuracy from simulation logs
4) Producing a compact report for baseline vs replay variants

It is intentionally dependency-free (stdlib only).
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional


ACC_RE = re.compile(r"Accuracy\s*:\s*([0-9]+\.[0-9]+)%")


@dataclass
class Variant:
    name: str
    weights_path: Path
    int_scale: float
    decay: str
    reset_mode: str


@dataclass
class Result:
    name: str
    weights_path: str
    int_scale: float
    decay: str
    reset_mode: str
    convert_ok: bool
    sim_ok: bool
    accuracy: Optional[float]
    notes: str
    log_path: str


def run_cmd(cmd: List[str], cwd: Path, env: dict, log_path: Path) -> subprocess.CompletedProcess:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as f:
        p = subprocess.run(cmd, cwd=str(cwd), env=env, stdout=f, stderr=subprocess.STDOUT, text=True)
    return p


def parse_accuracy(log_path: Path) -> Optional[float]:
    if not log_path.exists():
        return None
    text = log_path.read_text(errors="ignore")
    m = ACC_RE.search(text)
    if not m:
        return None
    return float(m.group(1))


def mk_variants(repo_root: Path) -> List[Variant]:
    cprog = repo_root / "RISC_V" / "c_program"
    return [
        Variant(
            name="baseline_hw",
            weights_path=cprog / "best_weights_hw.txt",
            int_scale=256.0,
            decay="lif24",
            reset_mode="zero",
        ),
        Variant(
            name="replay32_lutdump",
            weights_path=cprog / "best_weights_hw_replay32.txt",
            int_scale=256.0,
            decay="lif24",
            reset_mode="zero",
        ),
        Variant(
            name="replay32_spikeapprox",
            weights_path=cprog / "best_weights_hw_replay32_spikeapprox.txt",
            int_scale=256.0,
            decay="lif24",
            reset_mode="zero",
        ),
        # Stress check: what happens if someone forgets int_scale normalization.
        Variant(
            name="baseline_hw_scale_stress_int1",
            weights_path=cprog / "best_weights_hw.txt",
            int_scale=1.0,
            decay="lif24",
            reset_mode="zero",
        ),
    ]


def main() -> int:
    ap = argparse.ArgumentParser(description="Run hardware inference A/B on C weight files")
    ap.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root",
    )
    ap.add_argument(
        "--samples",
        type=int,
        default=320,
        help="input_count passed to simv_mnist_inf",
    )
    ap.add_argument(
        "--vcs-lib",
        type=str,
        default="/mnt/hidden_home/synopsys/vcs/linux64/lib",
        help="VCS runtime library path prepended to LD_LIBRARY_PATH",
    )
    ap.add_argument(
        "--module-load",
        type=str,
        default="",
        help="Optional shell snippet before simulation, e.g. 'module load synopsys/vcs/latest'",
    )
    ap.add_argument(
        "--sim-bin",
        type=Path,
        default=Path("inference_accelarator/neuron_accelerator/simv_mnist_inf"),
        help="Path to compiled simulation executable (repo-relative by default)",
    )
    ap.add_argument(
        "--converter",
        type=Path,
        default=Path("tools/weights/convert_ccode_weights_to_datamem.py"),
        help="Path to converter script (repo-relative by default)",
    )
    ap.add_argument(
        "--out-csv",
        type=Path,
        default=Path("RISC_V/c_program/ablation_accuracy_matrix.csv"),
        help="CSV report path (repo-relative by default)",
    )
    ap.add_argument(
        "--out-txt",
        type=Path,
        default=Path("RISC_V/c_program/ablation_accuracy_report.txt"),
        help="Text report path (repo-relative by default)",
    )
    ap.add_argument(
        "--logs-dir",
        type=Path,
        default=Path("RISC_V/c_program/ablation_logs"),
        help="Directory for conversion/simulation logs (repo-relative by default)",
    )
    args = ap.parse_args()

    repo_root = args.repo_root.resolve()
    sim_bin = (repo_root / args.sim_bin).resolve()
    converter = (repo_root / args.converter).resolve()
    out_csv = (repo_root / args.out_csv).resolve()
    out_txt = (repo_root / args.out_txt).resolve()
    logs_dir = (repo_root / args.logs_dir).resolve()
    accel_dir = (repo_root / "inference_accelarator" / "neuron_accelerator").resolve()

    if not converter.exists():
        print(f"ERROR: converter not found: {converter}")
        return 2
    if not sim_bin.exists():
        print(f"ERROR: sim executable not found: {sim_bin}")
        return 2

    env = os.environ.copy()
    ld_prev = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = f"{args.vcs_lib}:{ld_prev}" if ld_prev else args.vcs_lib

    variants = mk_variants(repo_root)
    data_mem_out = accel_dir / "data_mem_mnist_new.mem"

    results: List[Result] = []

    for v in variants:
        conv_log = logs_dir / f"{v.name}_convert.log"
        sim_log = logs_dir / f"{v.name}_sim.log"

        if not v.weights_path.exists():
            results.append(
                Result(
                    name=v.name,
                    weights_path=str(v.weights_path),
                    int_scale=v.int_scale,
                    decay=v.decay,
                    reset_mode=v.reset_mode,
                    convert_ok=False,
                    sim_ok=False,
                    accuracy=None,
                    notes="weights file missing",
                    log_path=str(conv_log),
                )
            )
            continue

        conv_cmd = [
            sys.executable,
            str(converter),
            str(v.weights_path),
            "-o",
            str(data_mem_out),
            "--int-scale",
            str(v.int_scale),
            "--decay",
            v.decay,
            "--reset-mode",
            v.reset_mode,
        ]
        cproc = run_cmd(conv_cmd, repo_root, env, conv_log)
        if cproc.returncode != 0:
            results.append(
                Result(
                    name=v.name,
                    weights_path=str(v.weights_path),
                    int_scale=v.int_scale,
                    decay=v.decay,
                    reset_mode=v.reset_mode,
                    convert_ok=False,
                    sim_ok=False,
                    accuracy=None,
                    notes=f"convert failed (rc={cproc.returncode})",
                    log_path=str(conv_log),
                )
            )
            continue

        if args.module_load.strip():
            sim_cmd = [
                "bash",
                "-lc",
                f"set -e; {args.module_load}; cd '{accel_dir}'; '{sim_bin}' +input_count={args.samples}",
            ]
            sim_cwd = repo_root
        else:
            sim_cmd = [str(sim_bin), f"+input_count={args.samples}"]
            sim_cwd = accel_dir
        sproc = run_cmd(sim_cmd, sim_cwd, env, sim_log)
        acc = parse_accuracy(sim_log)

        notes = "ok"
        if sproc.returncode != 0:
            notes = f"sim failed (rc={sproc.returncode})"
            txt = sim_log.read_text(errors="ignore") if sim_log.exists() else ""
            if "libvirsim.so" in txt:
                notes += "; missing VCS runtime libs (LD_LIBRARY_PATH/module load)"

        results.append(
            Result(
                name=v.name,
                weights_path=str(v.weights_path),
                int_scale=v.int_scale,
                decay=v.decay,
                reset_mode=v.reset_mode,
                convert_ok=True,
                sim_ok=(sproc.returncode == 0),
                accuracy=acc,
                notes=notes,
                log_path=str(sim_log),
            )
        )

    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with out_csv.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "variant",
                "weights_path",
                "int_scale",
                "decay",
                "reset_mode",
                "convert_ok",
                "sim_ok",
                "accuracy_percent",
                "notes",
                "log_path",
            ]
        )
        for r in results:
            w.writerow(
                [
                    r.name,
                    r.weights_path,
                    r.int_scale,
                    r.decay,
                    r.reset_mode,
                    int(r.convert_ok),
                    int(r.sim_ok),
                    "" if r.accuracy is None else f"{r.accuracy:.2f}",
                    r.notes,
                    r.log_path,
                ]
            )

    out_txt.parent.mkdir(parents=True, exist_ok=True)
    with out_txt.open("w") as f:
        f.write("Hardware Inference A/B Report\n")
        f.write("=============================\n\n")
        f.write(f"samples={args.samples}\n")
        f.write(f"sim_bin={sim_bin}\n")
        f.write(f"converter={converter}\n")
        f.write(f"LD_LIBRARY_PATH(add)={args.vcs_lib}\n\n")

        for r in results:
            f.write(f"[{r.name}]\n")
            f.write(f"weights={r.weights_path}\n")
            f.write(f"int_scale={r.int_scale} decay={r.decay} reset={r.reset_mode}\n")
            f.write(f"convert_ok={r.convert_ok} sim_ok={r.sim_ok}\n")
            f.write(f"accuracy={'' if r.accuracy is None else f'{r.accuracy:.2f}%'}\n")
            f.write(f"notes={r.notes}\n")
            f.write(f"log={r.log_path}\n\n")

        ok_acc = [r for r in results if r.accuracy is not None]
        if ok_acc:
            best = max(ok_acc, key=lambda x: x.accuracy)
            f.write("Summary\n")
            f.write("-------\n")
            f.write(f"best_variant={best.name}\n")
            f.write(f"best_accuracy={best.accuracy:.2f}%\n")

    print(f"Wrote: {out_csv}")
    print(f"Wrote: {out_txt}")
    print(f"Logs : {logs_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
