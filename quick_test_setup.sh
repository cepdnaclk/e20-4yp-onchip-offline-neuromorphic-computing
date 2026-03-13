#!/bin/bash

# Quick Start Test Script for Neuron Accelerator
# This creates minimal test data and runs a basic functional test

set -e

echo "======================================"
echo "Neuron Accelerator Quick Test Setup"
echo "======================================"

# Navigate to accelerator directory
cd rtl/neuron_accelerator

# Create minimal test data files
echo "Creating minimal test data files..."

# Create data_mem.mem - Initialization data (network config + weights)
cat > data_mem.mem << 'EOF'
01
02
03
04
05
06
07
08
09
0A
0B
0C
0D
0E
0F
10
xx
EOF

echo "✓ Created data_mem.mem (minimal initialization data)"

# Create spike_mem.mem - Input spike patterns
cat > spike_mem.mem << 'EOF'
001
002
003
7FF
004
005
7FF
7FF
EOF

echo "✓ Created spike_mem.mem (minimal spike input)"

echo ""
echo "Test files created successfully!"
echo ""
echo "======================================"
echo "Available Testing Options:"
echo "======================================"
echo ""
echo "1. If you have Icarus Verilog installed:"
echo "   cd rtl/neuron_accelerator"
echo "   iverilog -g2009 -o sim neuron_accelerator_tb.v"
echo "   ./sim"
echo ""
echo "2. If you have VCS (Synopsys):"
echo "   cd rtl/neuron_accelerator"
echo "   vcs -full64 -sverilog neuron_accelerator_tb.v"
echo "   ./simv"
echo ""
echo "3. If you have Verilator:"
echo "   verilator --cc neuron_accelerator.v --exe neuron_accelerator_tb.cpp"
echo ""
echo "4. Use online simulator (EDA Playground):"
echo "   Visit: https://www.edaplayground.com"
echo "   Upload: neuron_accelerator_tb.v and related files"
echo ""
echo "======================================"
echo "Install Simulation Tools (if needed):"
echo "======================================"
echo ""
echo "For Ubuntu/Debian:"
echo "  sudo apt-get update"
echo "  sudo apt-get install iverilog gtkwave"
echo ""
echo "For macOS (with Homebrew):"
echo "  brew install icarus-verilog gtkwave"
echo ""
echo "======================================"

# Check for common simulators
echo ""
echo "Checking installed simulators..."
echo ""

if command -v iverilog &> /dev/null; then
    echo "✓ Icarus Verilog is installed: $(iverilog -v 2>&1 | head -n1)"
    CAN_SIMULATE=true
else
    echo "✗ Icarus Verilog not found"
fi

if command -v vcs &> /dev/null; then
    echo "✓ VCS is installed"
    CAN_SIMULATE=true
else
    echo "✗ VCS not found"
fi

if command -v verilator &> /dev/null; then
    echo "✓ Verilator is installed"
    CAN_SIMULATE=true
else
    echo "✗ Verilator not found"
fi

echo ""

if [ "$CAN_SIMULATE" = true ]; then
    echo "======================================"
    echo "Ready to simulate!"
    echo "======================================"
    read -p "Would you like to run a simulation now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if command -v iverilog &> /dev/null; then
            echo "Compiling with Icarus Verilog..."
            iverilog -g2009 -o sim neuron_accelerator_tb.v
            echo "Running simulation..."
            ./sim +time_step_window=5 +input_neurons=4 +nn_layers=1 +input_count=2
            echo ""
            echo "Simulation complete! Check output.txt for results."
        fi
    fi
else
    echo "======================================"
    echo "No simulator found - Install options:"
    echo "======================================"
    echo ""
    echo "Quick install (Ubuntu/Debian):"
    echo "  sudo apt-get install iverilog"
    echo ""
    echo "Or use Docker:"
    echo "  docker run -it -v \$(pwd):/work hdlc/sim:osvb"
    echo ""
fi
