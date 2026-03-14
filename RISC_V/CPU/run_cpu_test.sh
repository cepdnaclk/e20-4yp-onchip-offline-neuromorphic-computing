#!/bin/bash
# run_cpu_test.sh — compile and run CPU_tb_4cases from the correct directory
# Usage: bash run_cpu_test.sh

set -e
RISCV=/home/ravindu/FYP/e20-4yp-onchip-offline-neuromorphic-computing/RISC_V
CPU=$RISCV/CPU

echo "=== Compiling CPU_tb_4cases.v ==="
iverilog -g2012 \
  -I$RISCV \
  -I$RISCV/extention \
  -I$RISCV/LIFO_Buffer \
  -I$RISCV/ALUunit \
  -I$RISCV/ProgramCounter \
  -I$RISCV/Adder \
  -I$RISCV/BranchController \
  -I$RISCV/ControlUnit \
  -I"$RISCV/Data Memory" \
  -I$RISCV/EX_MEM_pipeline \
  -I$RISCV/ID_EXPipeline \
  -I$RISCV/ID_IF_pipeLIne \
  -I$RISCV/ImidiateGenarator \
  -I$RISCV/InstructionMemory \
  -I$RISCV/RegisterFile \
  -I$RISCV/MEM_WBPipline \
  -I$RISCV/HazardHandling \
  -I$RISCV/HazardHandling/LoadUserHazard \
  -I$RISCV/MUX_32bit \
  -o $CPU/cpu_4cases.vvp \
  $CPU/CPU_tb_4cases.v

echo "=== Running simulation ==="
cd $CPU
vvp cpu_4cases.vvp
echo "=== Done ==="
