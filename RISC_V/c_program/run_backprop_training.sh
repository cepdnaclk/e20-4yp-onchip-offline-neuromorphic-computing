#!/bin/bash
# run_backprop_training.sh
# ========================
# Full pipeline to train with backpropD.C and test with hardware simulation
#
# Prerequisites:
#   - Python 3.8+ with torchvision installed
#   - gcc compiler
#   - VCS or iverilog for testbench (optional)
#
# Usage:
#   bash run_backprop_training.sh [options]
#
# Options:
#   --train-count N     = number of training samples (default: 60000)
#   --no-prepare        = skip MNIST data prep (use existing mnist_full_train.bin)
#   --no-train          = skip backprop training
#   --no-test           = skip hardware testbench
#   --int-scale SCALE   = override weight converter scale (default: 256)

set -e  # exit on error

# ─── Configuration ──────────────────────────────────────────────────────────
TRAIN_COUNT=60000
DO_PREPARE=1
DO_TRAIN=1
DO_TEST=1
INT_SCALE=""  # empty = use default 256

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --train-count)
            TRAIN_COUNT=$2
            shift 2
            ;;
        --no-prepare)
            DO_PREPARE=0
            shift
            ;;
        --no-train)
            DO_TRAIN=0
            shift
            ;;
        --no-test)
            DO_TEST=0
            shift
            ;;
        --int-scale)
            INT_SCALE="--int-scale $2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ─── Helper functions ────────────────────────────────────────────────────────
print_stage() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║ $1"
    echo "╚════════════════════════════════════════════════════════════════════╝"
}

# ─── Get workspace root ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

echo "Workspace root: $WS_ROOT"
echo "Train count: $TRAIN_COUNT"
echo ""

# ─── STAGE 1: Prepare MNIST binary ────────────────────────────────────────────
if [ $DO_PREPARE -eq 1 ]; then
    print_stage "STAGE 1: Preparing MNIST binary data"
    
    if [ ! -f "$SCRIPT_DIR/mnist_full_train.bin" ]; then
        echo "Generating mnist_full_train.bin (label + 784 pixels per sample)..."
        cd "$SCRIPT_DIR" || exit 1
        python3 "$SCRIPT_DIR/prepare_mnist_data.py" \
            --train-count $TRAIN_COUNT \
            --output "$SCRIPT_DIR/mnist_full_train.bin"
        echo "✓ Data ready"
    else
        echo "mnist_full_train.bin already exists, skipping..."
    fi
else
    echo "Skipping MNIST preparation (--no-prepare)"
fi

# ─── STAGE 2: Compile & run backprop training ─────────────────────────────────
if [ $DO_TRAIN -eq 1 ]; then
    print_stage "STAGE 2: Compiling and running backprop training"
    
    cd "$SCRIPT_DIR" || exit 1
    
    if [ ! -f "backpropD.C" ]; then
        echo "ERROR: backpropD.C not found in $SCRIPT_DIR"
        exit 1
    fi
    
    echo "Compiling backpropD.C..."
    gcc -O2 -o backprop backpropD.C
    echo "✓ Compiled: ./backprop"
    
    if [ ! -f "mnist_full_train.bin" ]; then
        echo "ERROR: mnist_full_train.bin not found"
        echo "Run with --no-prepare or ensure MNIST data is ready"
        exit 1
    fi
    
    echo "Running 5 epochs of training (60,000 samples/epoch, batch_size=32)..."
    echo "This will take ~5-10 minutes depending on CPU speed..."
    time ./backprop
    
    if [ -f "best_weights_new.txt" ]; then
        echo "✓ Training complete: best_weights_new.txt"
    else
        echo "ERROR: best_weights_new.txt not generated"
        exit 1
    fi
else
    echo "Skipping backprop training (--no-train)"
fi

# ─── STAGE 3: Convert weights to hardware format ──────────────────────────────
if [ $DO_TRAIN -eq 1 ] || [ $DO_TEST -eq 1 ]; then
    print_stage "STAGE 3: Converting weights to hardware memory format"
    
    if [ ! -f "$SCRIPT_DIR/best_weights_new.txt" ]; then
        echo "ERROR: best_weights_new.txt not found"
        echo "Run backprop training first (remove --no-train)"
        exit 1
    fi
    
    CONVERTER="$WS_ROOT/tools/weights/convert_ccode_weights_to_datamem.py"
    if [ ! -f "$CONVERTER" ]; then
        echo "ERROR: converter script not found at $CONVERTER"
        exit 1
    fi
    
    cd "$WS_ROOT/inference_accelarator/neuron_accelerator" || exit 1
    
    echo "Converting best_weights_new.txt → data_mem_mnist.mem..."
    python3 "$CONVERTER" \
        "$SCRIPT_DIR/best_weights_new.txt" \
        -o data_mem_mnist.mem \
        $INT_SCALE
    
    if [ -f "data_mem_mnist.mem" ]; then
        echo "✓ Weights converted: data_mem_mnist.mem"
        LINES=$(wc -l < data_mem_mnist.mem)
        echo "  ($LINES bytes, one per line)"
    else
        echo "ERROR: data_mem_mnist.mem not created"
        exit 1
    fi
else
    echo "Skipping weight conversion"
fi

# ─── STAGE 4: Run hardware testbench ──────────────────────────────────────────
if [ $DO_TEST -eq 1 ]; then
    print_stage "STAGE 4: Running hardware inference testbench"
    
    cd "$WS_ROOT/inference_accelarator/neuron_accelerator" || exit 1
    
    if [ -x "./simv_mnist_inf" ]; then
        echo "Running testbench on first 10 samples (for quick test)..."
        ./simv_mnist_inf +input_count=10
        
        if [ -f "hw_activations.txt" ]; then
            echo "✓ Hardware inference complete"
            echo "  Activation dumps: hw_activations.txt"
            echo "  Accuracy results printed above"
        else
            echo "WARNING: hw_activations.txt not created"
        fi
    else
        echo "ERROR: testbench not compiled (simv_mnist_inf not found)"
        echo "To compile:"
        echo "  cd $WS_ROOT/inference_accelarator/neuron_accelerator"
        echo "  vcs -full64 -sverilog -debug_access+all +v2k mnist_infertest_tb.v -o simv_mnist_inf"
        exit 1
    fi
else
    echo "Skipping testbench (--no-test)"
fi

print_stage "✓ Pipeline complete!"
echo ""
echo "Summary of outputs:"
echo "  • best_weights_new.txt          — Updated weights from backprop"
echo "  • data_mem_mnist.mem            — Hardware-ready weight initialization"
echo "  • hw_activations.txt            — Neuron spiking and membrane potentials"
echo ""
echo "Next steps:"
echo "  1. Run full hardware test (on all 320 samples):"
echo "     cd $WS_ROOT/inference_accelarator/neuron_accelerator"
echo "     ./simv_mnist_inf"
echo ""
echo "  2. For another training epoch with the new testbench:"
echo "     Edit backpropD.C: change line 'int total_epochs = 5;' to start from updated weights"
echo "     bash run_backprop_training.sh --no-prepare"
