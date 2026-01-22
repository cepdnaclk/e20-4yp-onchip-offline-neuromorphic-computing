#!/bin/bash

# Simulation script for backpropagation neuron
# Compiles and runs the testbench using Icarus Verilog

echo "========================================"
echo "Backpropagation Neuron Simulation"
echo "========================================"
echo ""

# Clean previous build artifacts
echo "Cleaning previous build files..."
rm -f backprop_neuron_tb.vvp backprop_neuron_tb.vcd

# Compile the design and testbench
echo "Compiling Verilog files..."
iverilog -o backprop_neuron_tb.vvp \
    backprop_neuron.v \
    backprop_neuron_tb.v

if [ $? -ne 0 ]; then
    echo "ERROR: Compilation failed!"
    exit 1
fi

echo "Compilation successful!"
echo ""

# Run the simulation
echo "Running simulation..."
echo "========================================"
vvp backprop_neuron_tb.vvp

if [ $? -ne 0 ]; then
    echo "ERROR: Simulation failed!"
    exit 1
fi

echo ""
echo "========================================"
echo "Simulation completed successfully!"
echo ""

# Check if VCD file was generated
if [ -f backprop_neuron_tb.vcd ]; then
    echo "Waveform file generated: backprop_neuron_tb.vcd"
    echo "To view waveforms, run: gtkwave backprop_neuron_tb.vcd"
else
    echo "WARNING: No waveform file generated"
fi

echo "========================================"
