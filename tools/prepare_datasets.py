#!/usr/bin/env python3
"""
prepare_datasets.py
====================
Converts a CSV file of neuron datasets into the flat text format expected by
CPU_tb_datasets.v, and optionally parses the weights_output.txt produced by
the Verilog simulation back into a readable CSV.

USAGE
-----
1. Generate input file for simulation:
       python tools/prepare_datasets.py to_txt  my_neurons.csv
   → writes  RISC_V/CPU/datasets_input.txt

2. Parse simulation results:
       python tools/prepare_datasets.py from_txt
   → reads   RISC_V/CPU/weights_output.txt
   → writes  tools/weights_result.csv  and prints a summary table

CSV FORMAT (my_neurons.csv)
---------------------------
Each row is one neuron dataset.  Header row is required:
  spike_hex, error, init_weight, g0, g1, g2, g3, g4, g5, g6, g7,
  g8, g9, g10, g11, g12, g13, g14, g15

  spike_hex  : 16-bit spike pattern, hex string WITHOUT "0x"  (e.g. B0F5)
  error      : signed integer                                  (e.g. -512)
  init_weight: signed integer                                  (e.g. 20)
  g0..g15    : 16 signed gradient values

EXAMPLE CSV
-----------
  spike_hex,error,init_weight,g0,g1,g2,g3,g4,g5,g6,g7,g8,g9,g10,g11,g12,g13,g14,g15
  B0F5,-512,20,200,-100,-50,0,1,3,6,12,25,50,100,-128,0,128,255,0
  FFFF,-256,50,10,20,30,-10,-20,-30,5,15,25,-5,-15,-25,0,0,0,0
"""

import csv
import os
import sys

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT   = os.path.dirname(SCRIPT_DIR)
CPU_DIR     = os.path.join(REPO_ROOT, "RISC_V", "CPU")
INPUT_TXT   = os.path.join(CPU_DIR,   "datasets_input.txt")
OUTPUT_TXT  = os.path.join(CPU_DIR,   "weights_output.txt")
RESULT_CSV  = os.path.join(SCRIPT_DIR, "weights_result.csv")

REQUIRED_COLS = (["spike_hex", "error", "init_weight"] +
                 [f"g{i}" for i in range(16)])


def cmd_to_txt(csv_path: str) -> None:
    """Convert CSV → datasets_input.txt."""
    if not os.path.isfile(csv_path):
        sys.exit(f"ERROR: file not found: {csv_path}")

    rows_written = 0
    with open(csv_path, newline="") as f_in, open(INPUT_TXT, "w") as f_out:
        reader = csv.DictReader(f_in)
        # Validate header
        missing = [c for c in REQUIRED_COLS if c not in reader.fieldnames]
        if missing:
            sys.exit(f"ERROR: CSV is missing columns: {missing}")

        for i, row in enumerate(reader, start=1):
            try:
                # Validate spike_hex is a valid hex value
                spike = row["spike_hex"].strip().upper()
                int(spike, 16)   # raises ValueError if not valid hex

                # Collect and validate the remaining signed integers
                nums = [int(row["error"]), int(row["init_weight"])]
                nums += [int(row[f"g{j}"]) for j in range(16)]

                f_out.write(f"{spike} {' '.join(str(n) for n in nums)}\n")
                rows_written += 1
            except (ValueError, KeyError) as e:
                print(f"  WARNING: skipping row {i} — {e}")

    print(f"Written {rows_written} datasets to:\n  {INPUT_TXT}")
    print("\nNow run the simulation:")
    print("  cd RISC_V/CPU")
    print("  iverilog -o tb_datasets CPU_tb_datasets.v && vvp tb_datasets")


def cmd_from_txt() -> None:
    """Parse weights_output.txt → weights_result.csv and print summary."""
    if not os.path.isfile(OUTPUT_TXT):
        sys.exit(f"ERROR: file not found: {OUTPUT_TXT}\n"
                 "Run the Verilog simulation first.")

    results = []
    with open(OUTPUT_TXT) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("dataset_index"):
                continue
            parts = line.split()
            if len(parts) == 2:
                results.append((int(parts[0]), int(parts[1])))

    if not results:
        print("No results found in weights_output.txt.")
        return

    # Write CSV
    with open(RESULT_CSV, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["dataset_index", "updated_weight"])
        writer.writerows(results)

    # Print table
    print(f"\n{'Dataset':>9}  {'Updated Weight':>14}")
    print("-" * 26)
    for idx, w in results:
        print(f"{idx:>9}  {w:>14}")
    print(f"\n{len(results)} datasets total.")
    print(f"Full results saved to:\n  {RESULT_CSV}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "to_txt":
        if len(sys.argv) < 3:
            sys.exit("Usage: prepare_datasets.py to_txt <input.csv>")
        cmd_to_txt(sys.argv[2])
    elif cmd == "from_txt":
        cmd_from_txt()
    else:
        sys.exit(f"Unknown command '{cmd}'.  Use 'to_txt' or 'from_txt'.")


if __name__ == "__main__":
    main()
