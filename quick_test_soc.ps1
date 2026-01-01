
# Compile Firmware
python tools/mini_assembler.py code/inference_test.s > firmware.hex

# Compile Verilog
# We need to include the path to RTL
# Note: simple_riscv.v and blackbox.v are included in soc_top.v, but we need to deal with include paths.
# soc_top.v includes relative paths "../riscv/simple_riscv.v".
# We should run iverilog from the root Directory.

iverilog -g2012 -o soc_sim.exe -I rtl/neuron_cluster -I rtl/neuron_integer/neuron_int_lif/utils -I rtl/neuron_integer/neuron_int_lif/decay -I rtl/neuron_integer/neuron_int_lif/adder -I rtl/neuron_integer/neuron_int_lif/accumulator -I rtl/neuron_integer/neuron_int_lif/neuron rtl/soc/soc_tb.v rtl/soc/soc_top.v

# Run Simulation
./soc_sim.exe
