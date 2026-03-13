#!/bin/bash

# =============================================================================
# Spiking Neural Network MNIST - Automated Workflow Script
# =============================================================================
# Automates the complete SNN pipeline:
#   1. Training multiple model configurations
#   2. Generating hardware neuron mappings
#   3. Converting test data to spike format
# Generates comprehensive performance analysis across different configurations.
# =============================================================================

set -e  # Exit on any error

# =============================================================================
# DIRECTORY CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BASE_OUTPUT_DIR="$SCRIPT_DIR/experiments"
LOG_DIR="$BASE_OUTPUT_DIR/logs"
RESULTS_FILE="experiment_results.csv"
SUMMARY_FILE="experiment_summary.txt"

# Python Scripts (in src/ directory)
TRAIN_SCRIPT="smnist_train.py"
MAPPING_SCRIPT="smnist_generate_mapping.py"
CONVERT_SCRIPT="smnist_convert_test.py"

# Python Interpreter
PYTHON_CMD="python3"

# =============================================================================
# NETWORK ARCHITECTURE CONFIGURATIONS
# =============================================================================
# Arrays of configurations to test (space-separated values)
HIDDEN_LAYERS=(1 2 3)                        # Number of hidden layers
HIDDEN_NEURONS=(16 32 64 128 256 512)        # Neurons per hidden layer
TRAINING_TIME_STEPS=(25 50 75 100)                 # Time steps during training
INFERENCE_TIME_STEPS=(25 50 75 100)           # Time steps during inference/testing

# =============================================================================
# TRAINING HYPERPARAMETERS
# =============================================================================
EPOCHS=10                                # Number of training epochs
BATCH_SIZE=64                            # Training batch size
LEARNING_RATE=5e-4                       # Learning rate (Adam optimizer)
# Note: BETA (LIF decay rate) is hardcoded in training script as 0.9

# =============================================================================
# DATA CONVERSION PARAMETERS
# =============================================================================
TEST_SAMPLES=960                         # Number of test samples to convert
USE_FULL_DATASET=false                   # Set to 'true' to test on full 10000 samples
# Note: dt_steps for spike encoding is controlled by INFERENCE_TIME_STEPS

# =============================================================================
# HARDWARE ENCODING PARAMETERS
# =============================================================================
CLUSTER_SIZE=32                          # Neurons per cluster
BASE_CLUSTER_ID=32                       # Starting cluster ID for input layer
NO_SPIKE_MARKER="FFF"                    # Hex marker for no-spike timesteps

# =============================================================================
# SYSTEM CONFIGURATION
# =============================================================================
FORCE_CPU=false                          # Set to 'true' to force CPU execution
RANDOM_SEED=42                           # Random seed for reproducibility


# =============================================================================
# OUTPUT FORMATTING (Colors for terminal output)
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

print_header() {
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

print_section() {
    echo -e "${CYAN}----------------------------------------${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}----------------------------------------${NC}"
}

print_success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

print_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

print_info() {
    echo -e "${PURPLE}INFO: $1${NC}"
}

# Check if required scripts exist
check_prerequisites() {
    print_section "Checking Prerequisites"
    
    # Check if src directory exists
    if [[ ! -d "$SRC_DIR" ]]; then
        print_error "Source directory '$SRC_DIR' not found!"
        exit 1
    fi
    
    # Check if required scripts exist
    if [[ ! -f "$SRC_DIR/$TRAIN_SCRIPT" ]]; then
        print_error "Training script '$SRC_DIR/$TRAIN_SCRIPT' not found!"
        exit 1
    fi
    
    if [[ ! -f "$SRC_DIR/$MAPPING_SCRIPT" ]]; then
        print_error "Mapping script '$SRC_DIR/$MAPPING_SCRIPT' not found!"
        exit 1
    fi
    
    if [[ ! -f "$SRC_DIR/$CONVERT_SCRIPT" ]]; then
        print_error "Conversion script '$SRC_DIR/$CONVERT_SCRIPT' not found!"
        exit 1
    fi
    
    # Check Python dependencies
    $PYTHON_CMD -c "import torch, snntorch, torchvision" 2>/dev/null || {
        print_error "Required Python packages not found!"
        echo "Please install dependencies:"
        echo "  cd $SCRIPT_DIR"
        echo "  python3 -m venv venv"
        echo "  source venv/bin/activate  # On Windows: venv\\Scripts\\activate"
        echo "  pip install -r requirements.txt"
        echo "  pip install -e ../model_compiler"
        exit 1
    }
    
    print_success "All prerequisites satisfied"
}

# Create directory structure
setup_directories() {
    print_section "Setting up Directory Structure"
    
    mkdir -p "$BASE_OUTPUT_DIR"
    mkdir -p "$LOG_DIR"
    
    # Create subdirectories for each configuration
    for layers in "${HIDDEN_LAYERS[@]}"; do
        for neurons in "${HIDDEN_NEURONS[@]}"; do
            for train_steps in "${TRAINING_TIME_STEPS[@]}"; do
                config_dir="$BASE_OUTPUT_DIR/h${neurons}_l${layers}_t${train_steps}"
                mkdir -p "$config_dir/models"
                mkdir -p "$config_dir/mappings"
                mkdir -p "$config_dir/test_data"
            done
        done
    done
    
    print_success "Directory structure created in: $BASE_OUTPUT_DIR"
}

# Initialize results file
initialize_results() {
    print_section "Initializing Results File"
    
    results_path="$BASE_OUTPUT_DIR/$RESULTS_FILE"
    echo "Config,Hidden_Layers,Hidden_Neurons,Train_Time_Steps,Train_Accuracy,Inference_Time_Steps,Test_Accuracy" > "$results_path"
    
    print_success "Results file initialized: $results_path"
}

# Build common arguments for all scripts
build_common_args() {
    local args=""
    
    if [[ "$FORCE_CPU" == "true" ]]; then
        args="$args --cpu"
    fi
    
    echo "$args"
}

# Train a single model configuration
train_model() {
    local layers=$1
    local neurons=$2
    local train_steps=$3
    
    local config_name="h${neurons}_l${layers}_t${train_steps}"
    local output_dir="$BASE_OUTPUT_DIR/$config_name/models"
    local log_file="$LOG_DIR/train_${config_name}.log"
    
    # Ensure output_dir is absolute path
    if [[ "$output_dir" != /* ]]; then
        output_dir="$SCRIPT_DIR/$output_dir"
    fi
    
    print_info "Training model: $config_name"
    print_info "Output directory: $output_dir"
    
    # Build command arguments
    local common_args=$(build_common_args)
    
    # Training command
    cd "$SRC_DIR"
    $PYTHON_CMD "$TRAIN_SCRIPT" \
        --hidden-layers "$layers" \
        --hidden-neurons "$neurons" \
        --dt-steps "$train_steps" \
        --epochs "$EPOCHS" \
        --batch-size "$BATCH_SIZE" \
        --learning-rate "$LEARNING_RATE" \
        --output-dir "$output_dir" \
        $common_args \
        > "$log_file" 2>&1
    cd "$SCRIPT_DIR"
    
    if [[ $? -eq 0 ]]; then
        print_success "Training completed: $config_name"
        return 0
    else
        print_error "Training failed: $config_name (see $log_file)"
        return 1
    fi
}

# Generate hardware mapping from trained model
generate_mapping() {
    local layers=$1
    local neurons=$2
    local train_steps=$3
    
    local config_name="h${neurons}_l${layers}_t${train_steps}"
    local model_dir="$BASE_OUTPUT_DIR/$config_name/models"
    local mapping_dir="$BASE_OUTPUT_DIR/$config_name/mappings"
    local model_path="$model_dir/spiking_mnist_h${neurons}_l${layers}_t${train_steps}.pth"
    local log_file="$LOG_DIR/mapping_${config_name}.log"
    
    # Ensure paths are absolute
    if [[ "$model_dir" != /* ]]; then
        model_dir="$SCRIPT_DIR/$model_dir"
        model_path="$model_dir/spiking_mnist_h${neurons}_l${layers}_t${train_steps}.pth"
    fi
    if [[ "$mapping_dir" != /* ]]; then
        mapping_dir="$SCRIPT_DIR/$mapping_dir"
    fi
    
    if [[ ! -f "$model_path" ]]; then
        print_error "Model file not found: $model_path"
        return 1
    fi
    
    print_info "Generating hardware mapping: $config_name"
    
    # Build command arguments
    local common_args=$(build_common_args)
    
    # Generate mapping command
    cd "$SRC_DIR"
    $PYTHON_CMD "$MAPPING_SCRIPT" \
        --model-path "$model_path" \
        --output-dir "$mapping_dir" \
        $common_args \
        > "$log_file" 2>&1
    cd "$SCRIPT_DIR"
    
    if [[ $? -eq 0 ]]; then
        print_success "Mapping generated: $config_name"
        return 0
    else
        print_error "Mapping generation failed: $config_name (see $log_file)"
        return 1
    fi
}

# Test model and extract training accuracy
test_model_training_accuracy() {
    local layers=$1
    local neurons=$2
    local train_steps=$3
    
    local config_name="h${neurons}_l${layers}_t${train_steps}"
    local model_dir="$BASE_OUTPUT_DIR/$config_name/models"
    local model_path="$model_dir/spiking_mnist_h${neurons}_l${layers}_t${train_steps}.pth"
    local log_file="$LOG_DIR/test_train_${config_name}.log"
    
    # Ensure paths are absolute
    if [[ "$model_dir" != /* ]]; then
        model_dir="$SCRIPT_DIR/$model_dir"
        model_path="$model_dir/spiking_mnist_h${neurons}_l${layers}_t${train_steps}.pth"
    fi
    
    if [[ ! -f "$model_path" ]]; then
        print_error "Model file not found: $model_path"
        echo "0.0"
        return 1
    fi
    
    # Build command arguments
    local common_args=$(build_common_args)
    local samples_arg=""
    if [[ "$USE_FULL_DATASET" == "true" ]]; then
        samples_arg="--samples 10000"
    fi
    
    # Test the model with its training time steps
    cd "$SRC_DIR"
    $PYTHON_CMD "$CONVERT_SCRIPT" \
        --test_only \
        --model_path "$model_path" \
        --dt_steps "$train_steps" \
        $samples_arg \
        $common_args \
        > "$log_file" 2>&1
    cd "$SCRIPT_DIR"
    
    # Extract accuracy from log file
    local accuracy=$(grep "Test Accuracy:" "$log_file" | tail -1 | sed 's/.*Test Accuracy: \([0-9.]*\)%.*/\1/')
    
    if [[ -z "$accuracy" ]]; then
        accuracy="0.0"
    fi
    
    echo "$accuracy"
}

# Test model with different inference time steps and convert test data
test_and_convert() {
    local layers=$1
    local neurons=$2
    local train_steps=$3
    local inference_steps=$4
    
    local config_name="h${neurons}_l${layers}_t${train_steps}"
    local inference_name="${config_name}_inf${inference_steps}"
    local model_dir="$BASE_OUTPUT_DIR/$config_name/models"
    local model_path="$model_dir/spiking_mnist_h${neurons}_l${layers}_t${train_steps}.pth"
    local test_dir="$BASE_OUTPUT_DIR/$config_name/test_data"
    local log_file="$LOG_DIR/convert_${inference_name}.log"
    
    # Ensure paths are absolute
    if [[ "$model_dir" != /* ]]; then
        model_dir="$SCRIPT_DIR/$model_dir"
        model_path="$model_dir/spiking_mnist_h${neurons}_l${layers}_t${train_steps}.pth"
    fi
    if [[ "$test_dir" != /* ]]; then
        test_dir="$SCRIPT_DIR/$test_dir"
    fi
    
    if [[ ! -f "$model_path" ]]; then
        print_error "Model file not found: $model_path"
        echo "0.0"
        return 1
    fi
    
    # Build command arguments
    local common_args=$(build_common_args)
    
    # Generate test data and test model with different inference time steps
    cd "$SRC_DIR"
    $PYTHON_CMD "$CONVERT_SCRIPT" \
        --model_path "$model_path" \
        --dt_steps "$inference_steps" \
        --samples "$TEST_SAMPLES" \
        $common_args \
        > "$log_file" 2>&1
    cd "$SCRIPT_DIR"
    
    # Move generated files to appropriate directory
    if [[ -f "$SRC_DIR/test_values.txt" ]]; then
        mv "$SRC_DIR/test_values.txt" "$test_dir/test_values_t${inference_steps}.txt"
    fi
    if [[ -f "$SRC_DIR/test_labels.txt" ]]; then
        mv "$SRC_DIR/test_labels.txt" "$test_dir/test_labels_t${inference_steps}.txt"
    fi
    
    # Extract accuracy from log file
    local accuracy=$(grep "Test Accuracy:" "$log_file" | tail -1 | sed 's/.*Test Accuracy: \([0-9.]*\)%.*/\1/')
    
    if [[ -z "$accuracy" ]]; then
        accuracy="0.0"
    fi
    
    echo "$accuracy"
}

# Record results
record_result() {
    local layers=$1
    local neurons=$2
    local train_steps=$3
    local train_accuracy=$4
    local inference_steps=$5
    local test_accuracy=$6
    
    local config_name="h${neurons}_l${layers}_t${train_steps}"
    local results_path="$BASE_OUTPUT_DIR/$RESULTS_FILE"
    
    echo "$config_name,$layers,$neurons,$train_steps,$train_accuracy,$inference_steps,$test_accuracy" >> "$results_path"
}

# Generate summary report
generate_summary() {
    print_section "Generating Summary Report"
    
    local summary_path="$BASE_OUTPUT_DIR/$SUMMARY_FILE"
    local results_path="$BASE_OUTPUT_DIR/$RESULTS_FILE"
    
    {
        echo "================================================================"
        echo "SPIKING NEURAL NETWORK EXPERIMENT SUMMARY"
        echo "================================================================"
        echo "Generated on: $(date)"
        echo "Total configurations tested: $((${#HIDDEN_LAYERS[@]} * ${#HIDDEN_NEURONS[@]} * ${#TRAINING_TIME_STEPS[@]}))"
        echo "Inference time steps tested per model: ${#INFERENCE_TIME_STEPS[@]}"
        echo ""
        
        echo "CONFIGURATION PARAMETERS:"
        echo "----------------------------------------------------------------"
        echo "Network Architecture:"
        echo "  - Hidden layers: ${HIDDEN_LAYERS[*]}"
        echo "  - Hidden neurons: ${HIDDEN_NEURONS[*]}"
        echo "  - Training time steps: ${TRAINING_TIME_STEPS[*]}"
        echo "  - Inference time steps: ${INFERENCE_TIME_STEPS[*]}"
        echo ""
        echo "Training Hyperparameters:"
        echo "  - Epochs: $EPOCHS"
        echo "  - Batch size: $BATCH_SIZE"
        echo "  - Learning rate: $LEARNING_RATE"
        echo "  - Beta (decay): $BETA"
        echo ""
        echo "Data Conversion:"
        echo "  - Test samples: $TEST_SAMPLES"
        echo "  - Encoding time steps: $ENCODING_DT_STEPS"
        echo "  - Full dataset: $USE_FULL_DATASET"
        echo ""
        echo "Hardware Encoding:"
        echo "  - Cluster size: $CLUSTER_SIZE"
        echo "  - Base cluster ID: $BASE_CLUSTER_ID"
        echo "  - No-spike marker: $NO_SPIKE_MARKER"
        echo ""
        
        echo "TOP PERFORMING MODELS:"
        echo "----------------------------------------------------------------"
        echo "By Training Accuracy:"
        tail -n +2 "$results_path" | sort -t',' -k5 -nr | head -5 | while IFS=',' read -r config layers neurons train_steps train_acc inf_steps test_acc; do
            echo "  $config: ${train_acc}% (Layers:$layers, Neurons:$neurons, TrainSteps:$train_steps)"
        done
        
        echo ""
        echo "By Test Accuracy (Inference):"
        tail -n +2 "$results_path" | sort -t',' -k7 -nr | head -5 | while IFS=',' read -r config layers neurons train_steps train_acc inf_steps test_acc; do
            echo "  $config (inf_t$inf_steps): ${test_acc}% (Layers:$layers, Neurons:$neurons)"
        done
        
        echo ""
        echo "================================================================"
        echo "DETAILED RESULTS BY CONFIGURATION:"
        echo "================================================================"
        
        # Group by configuration
        for layers in "${HIDDEN_LAYERS[@]}"; do
            for neurons in "${HIDDEN_NEURONS[@]}"; do
                for train_steps in "${TRAINING_TIME_STEPS[@]}"; do
                    config_name="h${neurons}_l${layers}_t${train_steps}"
                    echo ""
                    echo "Configuration: $config_name"
                    echo "  Architecture: $layers hidden layers × $neurons neurons"
                    echo "  Training time steps: $train_steps"
                    
                    # Find training accuracy
                    train_acc=$(grep "^$config_name," "$results_path" | head -1 | cut -d',' -f5)
                    echo "  Training accuracy: ${train_acc}%"
                    
                    echo "  Inference results:"
                    grep "^$config_name," "$results_path" | while IFS=',' read -r config layers neurons train_steps train_acc inf_steps test_acc; do
                        echo "    Time steps $inf_steps: ${test_acc}%"
                    done
                done
            done
        done
        
        echo ""
        echo "================================================================"
        echo "OUTPUT STRUCTURE:"
        echo "================================================================"
        echo "$BASE_OUTPUT_DIR/"
        echo "├── $RESULTS_FILE              # CSV with all results"
        echo "├── $SUMMARY_FILE         # This summary report"
        echo "├── logs/                        # Execution logs"
        echo "└── h{N}_l{L}_t{T}/             # Per-configuration directories"
        echo "    ├── models/                  # Trained .pth models"
        echo "    ├── mappings/                # neuron_mapping.txt files"
        echo "    └── test_data/               # test_values_t{T}.txt files"
        
    } > "$summary_path"
    
    print_success "Summary report generated: $summary_path"
}

# Main execution function
main() {
    print_header "SPIKING NEURAL NETWORK AUTOMATED WORKFLOW"
    
    local start_time=$(date +%s)
    
    # Setup
    check_prerequisites
    setup_directories
    initialize_results
    
    local total_configs=$((${#HIDDEN_LAYERS[@]} * ${#HIDDEN_NEURONS[@]} * ${#TRAINING_TIME_STEPS[@]}))
    local current_config=0
    
    print_header "PHASE 1: MODEL TRAINING"
    print_info "Training $total_configs model configurations..."
    echo ""
    
    # Training loop
    for layers in "${HIDDEN_LAYERS[@]}"; do
        for neurons in "${HIDDEN_NEURONS[@]}"; do
            for train_steps in "${TRAINING_TIME_STEPS[@]}"; do
                current_config=$((current_config + 1))
                
                print_section "Configuration $current_config/$total_configs"
                echo "Hidden Layers: $layers"
                echo "Hidden Neurons: $neurons"
                echo "Training Time Steps: $train_steps"
                echo ""
                
                # Step 1: Train model
                if ! train_model "$layers" "$neurons" "$train_steps"; then
                    print_error "Training failed - skipping this configuration"
                    continue
                fi
                
                echo ""
                
                # Step 2: Generate hardware mapping
                print_header "PHASE 2: HARDWARE MAPPING GENERATION"
                if ! generate_mapping "$layers" "$neurons" "$train_steps"; then
                    print_error "Mapping generation failed - skipping test conversion"
                    continue
                fi
                
                echo ""
                
                # Step 3: Test training accuracy
                print_header "PHASE 3: MODEL EVALUATION"
                print_info "Testing training accuracy..."
                local train_accuracy=$(test_model_training_accuracy "$layers" "$neurons" "$train_steps")
                print_info "Training accuracy: ${train_accuracy}%"
                
                echo ""
                
                # Step 4: Test with different inference time steps and convert data
                print_header "PHASE 4: TEST DATA CONVERSION"
                for inference_steps in "${INFERENCE_TIME_STEPS[@]}"; do
                    print_info "Inference time steps: $inference_steps"
                    
                    local test_accuracy=$(test_and_convert "$layers" "$neurons" "$train_steps" "$inference_steps")
                    print_info "Test accuracy: ${test_accuracy}%"
                    
                    # Record results
                    record_result "$layers" "$neurons" "$train_steps" "$train_accuracy" "$inference_steps" "$test_accuracy"
                    
                    echo ""
                done
                
                echo ""
                print_success "Configuration $config_name completed successfully!"
                echo "================================================================"
                echo ""
            done
        done
    done
    
    # Generate final summary
    generate_summary
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    print_header "EXPERIMENT COMPLETED SUCCESSFULLY"
    print_success "Total execution time: ${hours}h ${minutes}m ${seconds}s"
    print_success "Results directory: $BASE_OUTPUT_DIR"
    print_success "Summary report: $BASE_OUTPUT_DIR/$SUMMARY_FILE"
    print_success "Detailed results CSV: $BASE_OUTPUT_DIR/$RESULTS_FILE"
    
    echo ""
    print_info "Next steps:"
    echo "  1. Review the summary report for top performing models"
    echo "  2. Check model files in experiments/h{N}_l{L}_t{T}/models/"
    echo "  3. Use neuron_mapping.txt files for hardware configuration"
    echo "  4. Deploy test_values_t{T}.txt files to neuromorphic accelerator"
    echo "  5. Analyze logs in '$LOG_DIR' for detailed information"
}

# Script execution options
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Automated SNN workflow: Training → Hardware Mapping → Test Conversion"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help              Show this help message"
    echo "  --dry-run               Show configuration without executing"
    echo "  --epochs N              Number of training epochs (default: $EPOCHS)"
    echo "  --batch-size N          Training batch size (default: $BATCH_SIZE)"
    echo "  --learning-rate RATE    Learning rate (default: $LEARNING_RATE)"
    echo "  --samples N             Test samples to convert (default: $TEST_SAMPLES)"
    echo "  --full-dataset          Test on full 10000 samples (default: $USE_FULL_DATASET)"
    echo "  --cpu                   Force CPU execution (default: $FORCE_CPU)"
    echo "  --python CMD            Python command to use (default: $PYTHON_CMD)"
    echo ""
    echo "CONFIGURATIONS TO BE TESTED:"
    echo "  Hidden layers:          ${HIDDEN_LAYERS[*]}"
    echo "  Hidden neurons:         ${HIDDEN_NEURONS[*]}"
    echo "  Training time steps:    ${TRAINING_TIME_STEPS[*]}"
    echo "  Inference time steps:   ${INFERENCE_TIME_STEPS[*]}"
    echo ""
    echo "TOTAL EXPERIMENTS:"
    echo "  Configurations:         $((${#HIDDEN_LAYERS[@]} * ${#HIDDEN_NEURONS[@]} * ${#TRAINING_TIME_STEPS[@]}))"
    echo "  Inference tests:        $((${#HIDDEN_LAYERS[@]} * ${#HIDDEN_NEURONS[@]} * ${#TRAINING_TIME_STEPS[@]} * ${#INFERENCE_TIME_STEPS[@]}))"
    echo ""
    echo "OUTPUT STRUCTURE:"
    echo "  Base directory:         $BASE_OUTPUT_DIR"
    echo "  Logs directory:         $LOG_DIR"
    echo "  Results CSV:            $BASE_OUTPUT_DIR/$RESULTS_FILE"
    echo "  Summary report:         $BASE_OUTPUT_DIR/$SUMMARY_FILE"
    echo ""
    echo "EXAMPLE:"
    echo "  bash $0                                    # Run with defaults"
    echo "  bash $0 --epochs 20 --samples 1000         # Custom parameters"
    echo "  bash $0 --cpu --full-dataset               # CPU mode, full test set"
    echo ""
    echo "NOTE: Edit configuration variables at the top of this script for"
    echo "      more advanced customization (network architectures, etc.)"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --dry-run)
            print_warning "Dry run mode - showing configuration only"
            show_help
            exit 0
            ;;
        --epochs)
            EPOCHS="$2"
            shift 2
            ;;
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --learning-rate)
            LEARNING_RATE="$2"
            shift 2
            ;;
        --samples)
            TEST_SAMPLES="$2"
            shift 2
            ;;
        --full-dataset)
            USE_FULL_DATASET=true
            shift
            ;;
        --cpu)
            FORCE_CPU=true
            shift
            ;;
        --python)
            PYTHON_CMD="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
done

# Run main function
main