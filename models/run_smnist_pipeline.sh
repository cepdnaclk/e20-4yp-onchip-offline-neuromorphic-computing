#!/bin/bash
# =============================================================================
# SMNIST Pipeline Runner — End-to-End Mem File + V_mem Trace Generation
# =============================================================================
#
# This script orchestrates the complete pipeline:
#   1. Setup Python virtual environment + install dependencies
#   2. Train a small SMNIST spiking neural network
#   3. Generate neuron mapping → data_mem.mem
#   4. Convert test data to spikes → spike_mem.mem
#   5. Extract golden reference V_mem traces
#
# Usage:
#   bash run_smnist_pipeline.sh              # Run everything
#   bash run_smnist_pipeline.sh --skip-setup # Skip venv setup (if already done)
#   bash run_smnist_pipeline.sh --skip-train # Skip training (use existing model)
#
# =============================================================================

set -e  # Exit on error

# =============================================================================
# CONFIGURATION — Adjust these as needed
# =============================================================================
HIDDEN_NEURONS=16           # Neurons per hidden layer (small for quick test)
HIDDEN_LAYERS=1             # Number of hidden layers
DT_STEPS=16                 # Timesteps (user requested 16)
EPOCHS=10                   # Training epochs
BATCH_SIZE=64               # Training batch size
LEARNING_RATE=5e-4          # Adam learning rate
TEST_SAMPLES=320            # Samples for spike_mem.mem (accuracy testing)
VMEM_SAMPLES=10             # Samples for V_mem golden reference
SEED=42                     # Random seed for reproducible spikes
INPUT_LAYER_COUNT=784       # 28x28 MNIST pixels

# =============================================================================
# PATHS
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMNIST_DIR="$SCRIPT_DIR/smnist_lif_model"
SRC_DIR="$SMNIST_DIR/src"
GEN_DIR="$SCRIPT_DIR/gen_blackbox_data"
MODEL_COMPILER_DIR="$SCRIPT_DIR/model_compiler"

OUTPUT_DIR="$SCRIPT_DIR/pipeline_output"
MODEL_DIR="$OUTPUT_DIR/models"
MAPPING_DIR="$OUTPUT_DIR/mappings"
MEM_DIR="$OUTPUT_DIR/mem_files"
VMEM_DIR="$OUTPUT_DIR/vmem_traces"
SPIKE_DIR="$OUTPUT_DIR/spike_data"

PYTHON_CMD="python3"
VENV_DIR="$SCRIPT_DIR/venv"

# Derived
MODEL_NAME="spiking_mnist_h${HIDDEN_NEURONS}_l${HIDDEN_LAYERS}_t${DT_STEPS}"
MODEL_FILE="$MODEL_DIR/${MODEL_NAME}.pth"

# =============================================================================
# COLORS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# FLAGS
# =============================================================================
SKIP_SETUP=false
SKIP_TRAIN=false
FORCE_CPU=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-setup)  SKIP_SETUP=true; shift ;;
        --skip-train)  SKIP_TRAIN=true; shift ;;
        --cpu)         FORCE_CPU=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-setup   Skip Python venv setup (use if already installed)"
            echo "  --skip-train   Skip model training (use existing .pth file)"
            echo "  --cpu          Force CPU execution"
            echo "  -h, --help     Show this help"
            echo ""
            echo "Configuration (edit script to change):"
            echo "  HIDDEN_NEURONS=$HIDDEN_NEURONS"
            echo "  HIDDEN_LAYERS=$HIDDEN_LAYERS"
            echo "  DT_STEPS=$DT_STEPS"
            echo "  EPOCHS=$EPOCHS"
            echo "  TEST_SAMPLES=$TEST_SAMPLES"
            echo "  VMEM_SAMPLES=$VMEM_SAMPLES"
            exit 0
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
print_step() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  STEP $1: $2${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

print_ok() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

print_warn() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

print_info() {
    echo -e "${CYAN}  → $1${NC}"
}

check_file() {
    if [[ -f "$1" ]]; then
        local size=$(stat --format="%s" "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo "?")
        print_ok "$2: $1 (${size} bytes)"
        return 0
    else
        echo -e "${RED}  ✗ MISSING: $1${NC}"
        return 1
    fi
}

# =============================================================================
# PIPELINE START
# =============================================================================
echo ""
echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  SMNIST PIPELINE — Mem Files + V_mem Golden Reference${NC}"
echo -e "${BLUE}================================================================${NC}"
echo -e "${CYAN}  Architecture: ${HIDDEN_NEURONS} hidden × ${HIDDEN_LAYERS} layers${NC}"
echo -e "${CYAN}  Timesteps:    ${DT_STEPS}${NC}"
echo -e "${CYAN}  Output:       ${OUTPUT_DIR}${NC}"
echo -e "${BLUE}================================================================${NC}"

# Create directories
mkdir -p "$MODEL_DIR" "$MAPPING_DIR" "$MEM_DIR" "$VMEM_DIR" "$SPIKE_DIR"

# =============================================================================
# STEP 1: SETUP PYTHON ENVIRONMENT
# =============================================================================
if [[ "$SKIP_SETUP" == "false" ]]; then
    print_step "1/7" "Setting up Python environment"

    if [[ ! -d "$VENV_DIR" ]]; then
        print_info "Creating virtual environment at $VENV_DIR"
        $PYTHON_CMD -m venv "$VENV_DIR"
    else
        print_info "Virtual environment already exists at $VENV_DIR"
    fi

    # Activate venv
    source "$VENV_DIR/bin/activate"
    print_ok "Virtual environment activated"

    # Install dependencies
    print_info "Installing core dependencies..."
    pip install --quiet torch torchvision --index-url https://download.pytorch.org/whl/cpu 2>&1 | tail -1
    pip install --quiet snntorch numpy 2>&1 | tail -1

    # Install model_compiler
    print_info "Installing model_compiler..."
    pip install --quiet -e "$MODEL_COMPILER_DIR" 2>&1 | tail -1

    # Verify
    $PYTHON_CMD -c "import torch, snntorch; from neuron_mapper import Neuron_Mapper; print('All dependencies OK')"
    print_ok "Environment setup complete"
else
    print_step "1/7" "Skipping setup (--skip-setup)"
    # Try to activate existing venv
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        source "$VENV_DIR/bin/activate"
        print_ok "Activated existing venv"
    else
        print_warn "No venv found, using system Python"
    fi
fi

# Build CPU flag
CPU_FLAG=""
if [[ "$FORCE_CPU" == "true" ]]; then
    CPU_FLAG="--cpu"
fi

# =============================================================================
# STEP 2: TRAIN MODEL
# =============================================================================
if [[ "$SKIP_TRAIN" == "false" ]]; then
    print_step "2/7" "Training SMNIST model"
    print_info "Config: ${HIDDEN_NEURONS} neurons, ${HIDDEN_LAYERS} layers, ${DT_STEPS} timesteps, ${EPOCHS} epochs"

    cd "$SRC_DIR"
    $PYTHON_CMD smnist_train.py \
        --hidden-neurons "$HIDDEN_NEURONS" \
        --hidden-layers "$HIDDEN_LAYERS" \
        --dt-steps "$DT_STEPS" \
        --epochs "$EPOCHS" \
        --batch-size "$BATCH_SIZE" \
        --learning-rate "$LEARNING_RATE" \
        --output-dir "$MODEL_DIR" \
        $CPU_FLAG

    cd "$SCRIPT_DIR"

    # The training script also generates neuron_mapping.txt in MODEL_DIR
    # Move it to MAPPING_DIR if it exists
    if [[ -f "$MODEL_DIR/neuron_mapping.txt" ]]; then
        cp "$MODEL_DIR/neuron_mapping.txt" "$MAPPING_DIR/neuron_mapping.txt"
    fi

    check_file "$MODEL_FILE" "Trained model"
else
    print_step "2/7" "Skipping training (--skip-train)"
    check_file "$MODEL_FILE" "Existing model"
fi

# =============================================================================
# STEP 3: GENERATE NEURON MAPPING (if not already done by training)
# =============================================================================
print_step "3/7" "Generating neuron mapping"

if [[ ! -f "$MAPPING_DIR/neuron_mapping.txt" ]]; then
    print_info "Running smnist_generate_mapping.py..."
    cd "$SRC_DIR"
    $PYTHON_CMD smnist_generate_mapping.py \
        --model-path "$MODEL_FILE" \
        --output-dir "$MAPPING_DIR" \
        $CPU_FLAG
    cd "$SCRIPT_DIR"
else
    print_info "neuron_mapping.txt already exists from training step"
fi

check_file "$MAPPING_DIR/neuron_mapping.txt" "Neuron mapping"

# =============================================================================
# STEP 4: CONVERT MAPPING → data_mem.mem
# =============================================================================
print_step "4/7" "Converting neuron_mapping.txt → data_mem.mem"

cd "$GEN_DIR"
$PYTHON_CMD convert_init.py \
    "$MAPPING_DIR/neuron_mapping.txt" \
    -o "$MEM_DIR/data_mem.mem"
cd "$SCRIPT_DIR"

check_file "$MEM_DIR/data_mem.mem" "Data memory file"

# =============================================================================
# STEP 5: CONVERT TEST DATA → test_values.txt + test_labels.txt
# =============================================================================
print_step "5/7" "Converting MNIST test data to spike format"

cd "$SRC_DIR"
$PYTHON_CMD smnist_convert_test.py \
    --samples "$TEST_SAMPLES" \
    --dt_steps "$DT_STEPS" \
    --model_path "$MODEL_FILE" \
    $CPU_FLAG

# Move output files to our output directory
if [[ -f "test_values.txt" ]]; then
    mv test_values.txt "$SPIKE_DIR/test_values.txt"
fi
if [[ -f "test_labels.txt" ]]; then
    mv test_labels.txt "$SPIKE_DIR/test_labels.txt"
fi
cd "$SCRIPT_DIR"

check_file "$SPIKE_DIR/test_values.txt" "Test spike values"
check_file "$SPIKE_DIR/test_labels.txt" "Test labels"

# =============================================================================
# STEP 6: CONVERT SPIKES → spike_mem.mem
# =============================================================================
print_step "6/7" "Converting test_values.txt → spike_mem.mem"

cd "$GEN_DIR"
$PYTHON_CMD convert_spikes.py \
    "$SPIKE_DIR/test_values.txt" \
    -t "$DT_STEPS" \
    -l "$INPUT_LAYER_COUNT" \
    -o "$MEM_DIR/spike_mem.mem"
cd "$SCRIPT_DIR"

check_file "$MEM_DIR/spike_mem.mem" "Spike memory file"

# =============================================================================
# STEP 7: EXTRACT V_MEM GOLDEN REFERENCE TRACES
# =============================================================================
print_step "7/7" "Extracting V_mem golden reference traces"

cd "$SRC_DIR"
$PYTHON_CMD extract_vmem_traces.py \
    --model-path "$MODEL_FILE" \
    --samples "$VMEM_SAMPLES" \
    --dt-steps "$DT_STEPS" \
    --seed "$SEED" \
    --output-dir "$VMEM_DIR" \
    $CPU_FLAG
cd "$SCRIPT_DIR"

check_file "$VMEM_DIR/golden_reference.npz" "Golden reference (compact)"
check_file "$VMEM_DIR/golden_input_spikes.txt" "Golden input spikes"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  PIPELINE COMPLETE! All files generated successfully.${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "${CYAN}Output Directory: ${OUTPUT_DIR}${NC}"
echo ""
echo "  📂 pipeline_output/"
echo "  ├── models/"
echo "  │   └── ${MODEL_NAME}.pth           ← Trained PyTorch model"
echo "  ├── mappings/"
echo "  │   └── neuron_mapping.txt          ← Hardware neuron/weight config"
echo "  ├── mem_files/"
echo "  │   ├── data_mem.mem                ← Initialization memory (weights, thresholds, routing)"
echo "  │   └── spike_mem.mem               ← Input spike memory (test data)"
echo "  ├── spike_data/"
echo "  │   ├── test_values.txt             ← Raw spike data (hex)"
echo "  │   └── test_labels.txt             ← Ground truth labels"
echo "  └── vmem_traces/"
echo "      ├── golden_reference.npz        ← All V_mem/spike traces (numpy)"
echo "      ├── golden_input_spikes.txt     ← Exact input spike patterns used"
echo "      └── sample_XXXX_traces.csv      ← Per-sample CSV traces"
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "  1. Copy mem_files/data_mem.mem and mem_files/spike_mem.mem to your RTL testbench"
echo "  2. Run the hardware simulation"
echo "  3. Compare hardware V_mem dump against vmem_traces/golden_reference.npz"
echo "  4. Run output_decoder.py on hardware output to check classification accuracy"
echo ""
echo -e "${CYAN}Quick file sizes:${NC}"
for f in "$MEM_DIR/data_mem.mem" "$MEM_DIR/spike_mem.mem" "$VMEM_DIR/golden_reference.npz"; do
    if [[ -f "$f" ]]; then
        size=$(stat --format="%s" "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo "?")
        echo "  $(basename "$f"): ${size} bytes"
    fi
done
echo ""
echo -e "${GREEN}================================================================${NC}"
