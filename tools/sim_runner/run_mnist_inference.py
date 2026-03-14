#!/usr/bin/env python3
"""
run_mnist_inference.py
=======================
One-click pipeline to:
  1. Convert weight file → data_mem.mem
  2. Convert MNIST test images → spike_mem.mem + test_labels.txt
  3. Compile and run Icarus Verilog simulation
  4. Decode output and compute accuracy
  5. Print a summary suitable for a research presentation

Usage (from the tools/ directory):
    python sim_runner/run_mnist_inference.py

    # Custom options
    python sim_runner/run_mnist_inference.py \\
        --samples 200 --timesteps 25 --hidden_threshold 30

    # Skip weight / spike generation (files already exist)
    python sim_runner/run_mnist_inference.py --skip_datamem --skip_spikes

    # Skip compilation (use existing simv / sim.vvp)
    python sim_runner/run_mnist_inference.py --skip_compile

    # Save detailed CSV results
    python sim_runner/run_mnist_inference.py --save_csv results.csv
"""

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# PATH CONFIGURATION (relative to this script's location)
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR     = Path(__file__).resolve().parent
TOOLS_DIR      = SCRIPT_DIR.parent
REPO_ROOT      = TOOLS_DIR.parent
ACCEL_DIR      = REPO_ROOT / 'inference_accelarator' / 'neuron_accelerator'
WEIGHTS_SCRIPT = TOOLS_DIR / 'weights' / 'convert_weights_to_datamem.py'
SPIKE_SCRIPT   = TOOLS_DIR / 'spike_gen' / 'generate_spike_mem.py'
DECODE_SCRIPT  = TOOLS_DIR / 'decoder' / 'decode_output.py'
WEIGHTS_TXT    = TOOLS_DIR / 'best_weights_epoch_1.txt'
WEIGHTS_BIN    = REPO_ROOT / 'inference_accelarator' / 'pretrained_weight' / 'best_weights.bin'
DATA_MEM       = ACCEL_DIR / 'data_mem.mem'
SPIKE_MEM      = ACCEL_DIR / 'spike_mem.mem'
LABELS_FILE    = ACCEL_DIR / 'test_labels.txt'
OUTPUT_FILE    = ACCEL_DIR / 'output.txt'
TB_FILE        = ACCEL_DIR / 'neuron_accelerator_tb.v'
SIM_VVP        = ACCEL_DIR / 'sim.vvp'
SHARED_MEM_V   = REPO_ROOT / 'shared_memory' / 'snn_shared_memory_wb.v'

INPUT_SIZE     = 784


def run(cmd, cwd=None, check=True, capture=False):
    """Run a shell command, printing it first."""
    print(f"\n$ {cmd}")
    result = subprocess.run(
        cmd, shell=True, cwd=str(cwd) if cwd else None,
        capture_output=capture, text=True
    )
    if check and result.returncode != 0:
        print(f"[ERROR] Command failed (exit code {result.returncode})")
        if capture:
            print(result.stderr)
        sys.exit(1)
    return result


def step_banner(step, title):
    print(f"\n{'='*65}")
    print(f"  STEP {step}: {title}")
    print(f"{'='*65}")


def main():
    parser = argparse.ArgumentParser(
        description="Full MNIST inference pipeline for the neuron accelerator"
    )
    parser.add_argument('--samples', type=int, default=100,
                        help='Number of MNIST test samples (default: 100)')
    parser.add_argument('--timesteps', type=int, default=25,
                        help='Timesteps per sample for rate encoding (default: 25)')
    parser.add_argument('--hidden_threshold', type=int, default=30,
                        help='Hidden layer firing threshold integer (default: 30)')
    parser.add_argument('--output_threshold', type=int, default=1,
                        help='Output layer firing threshold integer (default: 1)')
    parser.add_argument('--scale', type=int, default=1,
                        help='Weight scale factor (default: 1)')
    parser.add_argument('--use_bin_weights', action='store_true',
                        help='Use binary weight file instead of text file')
    parser.add_argument('--skip_datamem', action='store_true',
                        help='Skip data_mem.mem generation (use existing file)')
    parser.add_argument('--skip_spikes', action='store_true',
                        help='Skip spike_mem.mem generation (use existing files)')
    parser.add_argument('--skip_compile', action='store_true',
                        help='Skip Icarus compilation (use existing sim.vvp)')
    parser.add_argument('--skip_sim', action='store_true',
                        help='Skip simulation (decode existing output.txt only)')
    parser.add_argument('--save_csv', type=str, default=None,
                        help='Save per-sample results to this CSV file')
    parser.add_argument('--verbose', action='store_true',
                        help='Print per-sample predictions')
    parser.add_argument('--timeout', type=int, default=7200,
                        help='Simulation timeout in seconds (default: 7200 = 2 hours)')
    args = parser.parse_args()

    t_start = time.time()

    print("=" * 65)
    print("  NEURON ACCELERATOR – MNIST INFERENCE PIPELINE")
    print("=" * 65)
    print(f"  Samples       : {args.samples}")
    print(f"  Timesteps     : {args.timesteps}")
    print(f"  H-threshold   : {args.hidden_threshold}")
    print(f"  O-threshold   : {args.output_threshold}")
    print(f"  Weight scale  : ×{args.scale}")
    print(f"  Accelerator   : {ACCEL_DIR}")

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 1: Generate data_mem.mem
    # ─────────────────────────────────────────────────────────────────────────
    step_banner(1, "Generate data_mem.mem (weights → init byte stream)")

    if args.skip_datamem:
        if not DATA_MEM.exists():
            print(f"[ERROR] --skip_datamem set but {DATA_MEM} not found!")
            sys.exit(1)
        print(f"[skip] Using existing {DATA_MEM}")
    else:
        if args.use_bin_weights and WEIGHTS_BIN.exists():
            weights_arg = f"--bin_weights {WEIGHTS_BIN}"
            print(f"[weights] Using binary: {WEIGHTS_BIN}")
        else:
            weights_arg = f"--weights {WEIGHTS_TXT}"
            print(f"[weights] Using text:   {WEIGHTS_TXT}")

        run(f"python3 {WEIGHTS_SCRIPT} "
            f"{weights_arg} "
            f"--output {DATA_MEM} "
            f"--hidden_threshold {args.hidden_threshold} "
            f"--output_threshold {args.output_threshold} "
            f"--scale {args.scale}")

    size_kb = DATA_MEM.stat().st_size / 1024
    print(f"[ok] data_mem.mem: {size_kb:.1f} KB, {DATA_MEM.stat().st_size} bytes")

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 2: Generate spike_mem.mem
    # ─────────────────────────────────────────────────────────────────────────
    step_banner(2, "Generate spike_mem.mem (MNIST → spike packets)")

    if args.skip_spikes:
        if not SPIKE_MEM.exists():
            print(f"[ERROR] --skip_spikes set but {SPIKE_MEM} not found!")
            sys.exit(1)
        print(f"[skip] Using existing {SPIKE_MEM}")
    else:
        run(f"python3 {SPIKE_SCRIPT} "
            f"--samples {args.samples} "
            f"--timesteps {args.timesteps} "
            f"--output {SPIKE_MEM} "
            f"--labels {LABELS_FILE}")

    # Count entries in spike_mem.mem
    n_entries = sum(1 for _ in open(SPIKE_MEM))
    expected  = args.samples * args.timesteps * INPUT_SIZE + 1
    print(f"[ok] spike_mem.mem: {n_entries:,} entries  (expected ≈ {expected:,})")

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 3: Compile with Icarus Verilog
    # ─────────────────────────────────────────────────────────────────────────
    step_banner(3, "Compile Verilog testbench (Icarus iverilog)")

    if args.skip_compile or args.skip_sim:
        if not SIM_VVP.exists() and not args.skip_sim:
            print(f"[ERROR] --skip_compile set but {SIM_VVP} not found!")
            sys.exit(1)
        print(f"[skip] Using existing {SIM_VVP}")
    else:
        # Check shared_memory file exists
        if not SHARED_MEM_V.exists():
            print(f"[ERROR] Missing: {SHARED_MEM_V}")
            print("  The testbench requires snn_shared_memory_wb.v")
            sys.exit(1)

        # iverilog must be run from ACCEL_DIR so that relative `include paths resolve
        compile_cmd = (
            f"iverilog -o {SIM_VVP} "
            f"-g2012 "
            f"-Wall -Wno-timescale "
            f"{TB_FILE}"
        )
        t0 = time.time()
        run(compile_cmd, cwd=ACCEL_DIR)
        print(f"[ok] Compilation: {time.time()-t0:.1f}s")

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 4: Run simulation
    # ─────────────────────────────────────────────────────────────────────────
    step_banner(4, "Run simulation (vvp)")

    if args.skip_sim:
        if not OUTPUT_FILE.exists():
            print(f"[ERROR] --skip_sim set but {OUTPUT_FILE} not found!")
            sys.exit(1)
        print(f"[skip] Using existing {OUTPUT_FILE}")
    else:
        print(f"[sim] Parameters:")
        print(f"   +time_step_window={args.timesteps}")
        print(f"   +input_neurons={INPUT_SIZE}")
        print(f"   +nn_layers=2")
        print(f"   +input_count={args.samples}")
        print(f"[sim] This may take a while for large sample counts...")
        print(f"[sim] Timeout: {args.timeout}s")

        sim_cmd = (
            f"vvp {SIM_VVP} "
            f"+time_step_window={args.timesteps} "
            f"+input_neurons={INPUT_SIZE} "
            f"+nn_layers=2 "
            f"+input_count={args.samples}"
        )

        t0 = time.time()
        try:
            result = subprocess.run(
                sim_cmd, shell=True, cwd=str(ACCEL_DIR),
                timeout=args.timeout
            )
            elapsed = time.time() - t0
            if result.returncode != 0:
                print(f"[WARNING] Simulation exited with code {result.returncode}")
            else:
                print(f"[ok] Simulation complete: {elapsed:.1f}s")
        except subprocess.TimeoutExpired:
            print(f"[ERROR] Simulation timed out after {args.timeout}s")
            print("  Try fewer samples or shorter timestep window.")
            sys.exit(1)

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 5: Decode output and compute accuracy
    # ─────────────────────────────────────────────────────────────────────────
    step_banner(5, "Decode output.txt and compute accuracy")

    if not OUTPUT_FILE.exists() or OUTPUT_FILE.stat().st_size == 0:
        print(f"[ERROR] {OUTPUT_FILE} is empty or missing.")
        print("  Check that the simulation ran correctly.")
        sys.exit(1)

    decode_args = (
        f"--sim_output {OUTPUT_FILE} "
        f"--labels {LABELS_FILE} "
        f"--samples {args.samples} "
    )
    if args.verbose:
        decode_args += "--verbose "
    if args.save_csv:
        csv_path = Path(args.save_csv)
        if not csv_path.is_absolute():
            csv_path = ACCEL_DIR / csv_path
        decode_args += f"--save_csv {csv_path} "

    run(f"python3 {DECODE_SCRIPT} {decode_args}")

    # ─────────────────────────────────────────────────────────────────────────
    # FINAL SUMMARY
    # ─────────────────────────────────────────────────────────────────────────
    total_time = time.time() - t_start
    print()
    print("=" * 65)
    print("  PIPELINE COMPLETE")
    print(f"  Total time: {total_time:.1f}s  ({total_time/60:.1f} min)")
    print()
    print("  Files generated:")
    print(f"    {DATA_MEM}")
    print(f"    {SPIKE_MEM}")
    print(f"    {LABELS_FILE}")
    print(f"    {OUTPUT_FILE}")
    print()
    print("  For VCS (Synopsys) on the university server:")
    print("    See: tools/sim_runner/VCS_GUIDE.md")
    print("=" * 65)


if __name__ == '__main__':
    main()
