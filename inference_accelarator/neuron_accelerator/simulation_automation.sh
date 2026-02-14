#!/bin/bash

# Neuron Accelerator Simulation Automation Script
# =================================================
# This script automates the complete testing pipeline for the neuron accelerator
# It processes model configurations, loads neuron mappings and test data,
# runs VCS simulations, and calculates accuracy using the output decoder
#
# Usage: ./simulation_automation.sh [-n neuron_count1 neuron_count2 ...] [-t timestep1 timestep2 ...] [-h]

set -e  # Exit on any error

# =============================================================================
# CONFIGURATION PARAMETERS
# =============================================================================

# Directory Paths
BASE_DIR="../../models/smnist_lif_model"
EXPERIMENTS_DIR="$BASE_DIR/experiments"
SRC_DIR="$BASE_DIR/src"
NEURON_ACCELERATOR_DIR="."
OUTPUT_DECODER_SCRIPT="$SRC_DIR/output_decoder.py"
SIMULATIONS_DIR="simulations"  # Main simulations directory

# File Names
NEURON_MAPPING_FILE="neuron_mapping.txt"
TEST_LABELS_PREFIX="test_labels_t"
TEST_VALUES_PREFIX="test_values_t"
DATA_MEM_FILE="data_mem.mem"
SPIKE_MEM_FILE="spike_mem.mem"
OUTPUT_FILE="output.txt"

# Results Configuration (will be updated in parse_arguments)
RESULTS_DIR="$SIMULATIONS_DIR/results"
RESULTS_CSV="$SIMULATIONS_DIR/accelerator_simulation_results.csv"
LOG_FILE="$SIMULATIONS_DIR/simulation_automation.log"
SHARED_SPIKE_DIR="$SIMULATIONS_DIR/shared_spike_mem"

# VCS Configuration
VCS_EXECUTABLE="vcs"
VCS_FLAGS="-full64 -sverilog -debug_access+all +v2k"
SIMV_EXECUTABLE="./simv"
SIMV_BASE_FLAGS="+fsdb+all=on +fsdb+delta"

# Testbench Configuration
TESTBENCH_FILE="neuron_accelerator_tb.v"
TOP_MODULE="neuron_accelerator_tb"

# Testbench Parameters (defaults)
DEFAULT_TIME_STEP_WINDOW=20
DEFAULT_INPUT_NEURONS=784
DEFAULT_NN_LAYERS=3
DEFAULT_INPUT_COUNT=960

# Simulation Runtime Parameters (used during inference)
SIMULATION_INPUT_NEURONS=784        # MNIST input size (fixed)
SIMULATION_INPUT_COUNT=960        # Number of test samples to process

# Processing Configuration
DEFAULT_INFERENCE_TIMESTEPS=(25 50 75 100)  # Default inference timesteps to test
TIMEOUT_SECONDS=3600                 # Simulation timeout (1 hour)
VERBOSE_MODE=false                   # Show detailed tool output

# Model Configuration Filters (matching training workflow)
# These define which configurations to process based on layers and neurons
DEFAULT_LAYER_CONFIGS=(1 2 3)              # Layer configurations to process
DEFAULT_NEURON_CONFIGS=(16 32 64 128 256 512)  # Neuron configurations to process

# Configuration filtering rules
# Format: "layers:neurons" - if empty, processes all combinations
CONFIGURATION_FILTER=()              # Specific config filter (e.g., "1:16,1:32,2:64")
QUICK_TEST_MODE=false                # Run only small configurations for quick testing

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

NEURON_FILTER=()
TIMESTEP_FILTER=()
LAYER_FILTER=()
CONFIGURATION_FILTER=()
FILTER_NEURONS_ENABLED=false
FILTER_TIMESTEPS_ENABLED=false
FILTER_LAYERS_ENABLED=false
FILTER_CONFIGURATIONS_ENABLED=false
QUICK_TEST_MODE=false
TOTAL_SIMULATIONS=0
SUCCESSFUL_SIMULATIONS=0
FAILED_SIMULATIONS=0
EXPECTED_SIMULATIONS=0

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Debug function
debug() {
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1" >&2
    fi
}

# Logging functions
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# Function to display usage
usage() {
    cat << EOF
NEURON ACCELERATOR SIMULATION AUTOMATION
=========================================

Usage: $0 [OPTIONS]

OPTIONS:
  -n, --neurons COUNTS       Specify neuron counts to process (e.g., -n "16,32,64")
                            If not specified, all configurations will be processed
  
  -t, --timesteps STEPS      Specify inference timesteps to test (e.g., -t "25,50,75")
                            Default: 25 50 75 100
  
  -l, --layers LAYERS        Specify layer counts to process (e.g., -l "1,2,3")
                            Default: 1 2 3
  
  -f, --filter PATTERN       Filter configurations by pattern (e.g., "h16_l1", "l2_t25")
                            Supports regex patterns for advanced filtering
  
  -h, --help                 Show this help message
  
  -v, --verbose              Show detailed tool output (VCS, simulation, decoder)
  
  -q, --quick-test           Run quick test with minimal configurations
  
  -o, --output FILE          Specify output CSV file (default: sim_results.csv)
  
  -d, --output-dir DIR       Output directory path (default: ./simulations)
  
  --clean                    Clean previous results and logs before running
  
  --compile-only             Only compile VCS without running simulations
  
  --skip-compile             Skip VCS compilation (use existing simv)

EXAMPLES:
  $0                                    # Process all configurations
  $0 -n "16,32,64"                     # Process only 16, 32, 64 neuron configs
  $0 -l "1,2"                          # Process only 1 and 2 layer configurations
  $0 -t "25,50"                        # Test only with 25 and 50 timesteps
  $0 -n "128" -t "25,50"               # Process 128 neurons with 25 and 50 timesteps
  $0 -l "1,2,3" -n "16,32,64,128"      # All 1&2 layers + 3-layer with limited neurons
  $0 -f "h16_l1"                       # Filter for 16-neuron, 1-layer configs
  $0 -f "l[12]"                        # Filter for layer 1 and 2 using regex
  $0 --clean                           # Clean and run all
  $0 --compile-only                    # Only compile testbench
  $0 -q                                # Quick test mode
  $0 -v -n "16"                        # Verbose mode for 16-neuron config

ADVANCED FILTERING:
  # Run all 1 and 2 layer experiments
  $0 -l "1,2"
  
  # Run 3-layer with specific neuron counts only
  $0 -l "3" -n "16,32,64,128"
  
  # Combine layer and neuron filtering
  $0 -l "1,2,3" -n "16,32,64,128"
  
  # Use pattern matching for complex filtering
  $0 -f "l3_h(16|32|64|128)|l[12]_.*"

SIMULATION PARAMETERS:
  The testbench accepts runtime parameters that are automatically configured:
  - time_step_window: Set from inference timesteps
  - input_neurons:    Fixed at 784 (MNIST input size)
  - nn_layers:        Derived from model configuration
  - input_count:      Set to 960 (number of test samples)

DIRECTORY STRUCTURE:
  experiments/
    └── h{N}_l{L}_t{T}/
        ├── models/
        │   └── neuron_mapping.txt
        ├── mappings/
        │   └── neuron_mapping.txt
        └── test_data/
            ├── test_labels_t{T}.txt
            ├── test_labels_t50.txt
            ├── test_values_t25.txt
            └── test_values_t50.txt

OUTPUT:
  - All outputs in: simulations/
  - Simulation results: simulations/results/
  - Accuracy results: simulations/accelerator_simulation_results.csv
  - Detailed logs: simulations/simulation_automation.log

EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_arguments() {
    CLEAN_MODE=false
    COMPILE_ONLY=false
    SKIP_COMPILE=false
    VERBOSE_MODE=false
    OUTPUT_CSV="accelerator_simulation_results.csv"
    OUTPUT_DIR="$SIMULATIONS_DIR"  # Default to simulations directory
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE_MODE=true
                shift
                ;;
            -n|--neurons)
                FILTER_NEURONS_ENABLED=true
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    # Parse comma-separated values
                    IFS=',' read -ra NEURON_ARRAY <<< "$1"
                    for neuron in "${NEURON_ARRAY[@]}"; do
                        neuron=$(echo "$neuron" | xargs)  # Trim whitespace
                        if [[ "$neuron" =~ ^[0-9]+$ ]]; then
                            NEURON_FILTER+=("$neuron")
                        else
                            error "Invalid neuron count: $neuron (must be a positive integer)"
                            exit 1
                        fi
                    done
                    shift
                else
                    error "Option -n requires a value (e.g., -n \"16,32,64\")"
                    exit 1
                fi
                ;;
            -t|--timesteps)
                FILTER_TIMESTEPS_ENABLED=true
                TIMESTEP_FILTER=()  # Clear defaults
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    # Parse comma-separated values
                    IFS=',' read -ra TIMESTEP_ARRAY <<< "$1"
                    for timestep in "${TIMESTEP_ARRAY[@]}"; do
                        timestep=$(echo "$timestep" | xargs)  # Trim whitespace
                        if [[ "$timestep" =~ ^[0-9]+$ ]]; then
                            TIMESTEP_FILTER+=("$timestep")
                        else
                            error "Invalid timestep: $timestep (must be a positive integer)"
                            exit 1
                        fi
                    done
                    shift
                else
                    error "Option -t requires a value (e.g., -t \"25,50,75\")"
                    exit 1
                fi
                ;;
            -l|--layers)
                FILTER_LAYERS_ENABLED=true
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    # Parse comma-separated values
                    IFS=',' read -ra LAYER_ARRAY <<< "$1"
                    for layer in "${LAYER_ARRAY[@]}"; do
                        layer=$(echo "$layer" | xargs)  # Trim whitespace
                        if [[ "$layer" =~ ^[0-9]+$ ]]; then
                            LAYER_FILTER+=("$layer")
                        else
                            error "Invalid layer count: $layer (must be a positive integer)"
                            exit 1
                        fi
                    done
                    shift
                else
                    error "Option -l requires a value (e.g., -l \"1,2,3\")"
                    exit 1
                fi
                ;;
            -f|--filter)
                FILTER_CONFIGURATIONS_ENABLED=true
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    CONFIGURATION_FILTER+=("$1")
                    shift
                else
                    error "Option -f requires a pattern value"
                    exit 1
                fi
                ;;
            -q|--quick-test)
                QUICK_TEST_MODE=true
                shift
                ;;
            -o|--output)
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    OUTPUT_CSV="$1"
                    shift
                else
                    error "Option -o requires a filename"
                    exit 1
                fi
                ;;
            -d|--output-dir)
                shift
                if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
                    OUTPUT_DIR="$1"
                    shift
                else
                    error "Option -d requires a directory path"
                    exit 1
                fi
                ;;
            --clean)
                CLEAN_MODE=true
                shift
                ;;
            --compile-only)
                COMPILE_ONLY=true
                shift
                ;;
            --skip-compile)
                SKIP_COMPILE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Set default timesteps if not filtered
    if [[ "$FILTER_TIMESTEPS_ENABLED" == false ]]; then
        if [[ "$QUICK_TEST_MODE" == true ]]; then
            TIMESTEP_FILTER=(25)  # Only test 25 timesteps in quick mode
        else
            TIMESTEP_FILTER=("${DEFAULT_INFERENCE_TIMESTEPS[@]}")
        fi
    fi
    
    # Set quick test mode filters if enabled
    if [[ "$QUICK_TEST_MODE" == true ]]; then
        if [[ "$FILTER_NEURONS_ENABLED" == false ]]; then
            NEURON_FILTER=(16 32)  # Only test 16 and 32 neurons in quick mode
            FILTER_NEURONS_ENABLED=true
        fi
        if [[ "$FILTER_LAYERS_ENABLED" == false ]]; then
            LAYER_FILTER=(1)  # Only test 1 layer in quick mode
            FILTER_LAYERS_ENABLED=true
        fi
    fi
    
    # Validate filters
    if [[ "$FILTER_NEURONS_ENABLED" == true && ${#NEURON_FILTER[@]} -eq 0 ]]; then
        error "No valid neuron counts specified with -n option"
        exit 1
    fi
    
    if [[ "$FILTER_LAYERS_ENABLED" == true && ${#LAYER_FILTER[@]} -eq 0 ]]; then
        error "No valid layer counts specified with -l option"
        exit 1
    fi
    
    if [[ ${#TIMESTEP_FILTER[@]} -eq 0 ]]; then
        error "No valid timesteps specified"
        exit 1
    fi
    
    # Update paths based on user-specified output directory and CSV file
    update_output_paths
}

# Function to update output paths based on user arguments
update_output_paths() {
    # Create absolute path for output directory
    if [[ ! "$OUTPUT_DIR" =~ ^/ ]]; then
        OUTPUT_DIR="$(pwd)/$OUTPUT_DIR"
    fi
    
    # Update paths
    RESULTS_DIR="$OUTPUT_DIR"
    RESULTS_CSV="$OUTPUT_DIR/$OUTPUT_CSV"
    LOG_FILE="$OUTPUT_DIR/simulation_automation.log"
    SHARED_SPIKE_DIR="$OUTPUT_DIR/shared_spike_mem"
}

# =============================================================================
# DIRECTORY AND FILE MANAGEMENT
# =============================================================================

# Function to archive previous results
archive_previous_results() {
    if [[ -d "$SIMULATIONS_DIR" ]]; then
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local archive_dir="$SIMULATIONS_DIR/archive"
        
        # Create archive directory structure
        mkdir -p "$archive_dir"
        
        # Archive previous CSV file if it exists (only CSV, not results or logs)
        if [[ -f "$RESULTS_CSV" ]]; then
            info "Archiving previous results CSV..."
            mv "$RESULTS_CSV" "$archive_dir/$(basename "$RESULTS_CSV" .csv)_$timestamp.csv"
            success "Previous CSV archived to: $archive_dir/$(basename "$RESULTS_CSV" .csv)_$timestamp.csv"
        fi
    fi
}

# Function to clean previous results
clean_previous_results() {
    echo -e "${BLUE}[INFO]${NC} Cleaning previous results..."
    
    # Archive individual components instead of entire directory
    archive_previous_results
    
    # Remove temporary simulation files
    rm -f "$OUTPUT_FILE" "$DATA_MEM_FILE" "$SPIKE_MEM_FILE"
    rm -f *.vcd *.vpd *.fsdb
    rm -rf csrc DVEfiles simv.daidir
    
    echo -e "${GREEN}[SUCCESS]${NC} Cleanup completed"
}

# Function to initialize results directory and CSV
initialize_results() {
    # Archive previous results if they exist (unless in clean mode)
    if [[ "$CLEAN_MODE" != true ]]; then
        archive_previous_results
    fi
    
    mkdir -p "$SIMULATIONS_DIR"
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$SHARED_SPIKE_DIR"
    
    # Create CSV with header and metadata
    create_csv_with_metadata
    
    success "Initialized simulations directory structure and CSV file"
}

# Function to create CSV with run configuration metadata
create_csv_with_metadata() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user=$(whoami)
    local hostname=$(hostname)
    
    # Create CSV with metadata comments and header
    cat > "$RESULTS_CSV" << EOF
# Neuromorphic Accelerator Simulation Results
# Generated: $timestamp
# User: $user@$hostname
# Run Configuration:
#   Mode: $(if [[ "$QUICK_TEST_MODE" == true ]]; then echo "Quick Test"; else echo "Full Simulation"; fi)
#   Layer Filter: $(if [[ "$FILTER_LAYERS_ENABLED" == true ]]; then echo "${LAYER_FILTER[*]}"; else echo "All (1 2 3)"; fi)
#   Neuron Filter: $(if [[ "$FILTER_NEURONS_ENABLED" == true ]]; then echo "${NEURON_FILTER[*]}"; else echo "All (16 32 64 128 256 512)"; fi)
#   Timestep Filter: ${TIMESTEP_FILTER[*]}
$(if [[ "$FILTER_CONFIGURATIONS_ENABLED" == true ]]; then echo "#   Pattern Filter: ${CONFIGURATION_FILTER[*]}"; fi)
#   Verbose Mode: $(if [[ "$VERBOSE_MODE" == true ]]; then echo "Enabled"; else echo "Disabled"; fi)
#   Total Expected Simulations: $EXPECTED_SIMULATIONS
#
# CSV Format: Config,Layers,Neurons,Train_TimeSteps,Inference_TimeSteps,Accuracy
Config,Layers,Neurons,Train_TimeSteps,Inference_TimeSteps,Accuracy
EOF
}

# Function to count expected simulations based on filters
count_expected_simulations() {
    EXPECTED_SIMULATIONS=0
    
    # Check if experiments directory exists
    if [[ ! -d "$EXPERIMENTS_DIR" ]]; then
        return 0
    fi
    
    # Find all configuration directories
    local config_dirs=()
    while IFS= read -r -d '' dir; do
        local config_name=$(basename "$dir")
        local config_info=$(extract_config_from_dir "$config_name")
        local neurons=$(echo "$config_info" | cut -d',' -f1)
        local layers=$(echo "$config_info" | cut -d',' -f2)
        
        # Check if this config would be processed
        if should_process_config "$neurons" "$layers" "$config_name"; then
            # Count timesteps that would be processed for this config
            for inf_timesteps in "${TIMESTEP_FILTER[@]}"; do
                if should_process_experiment "$neurons" "$layers" "$inf_timesteps" "$config_name"; then
                    EXPECTED_SIMULATIONS=$((EXPECTED_SIMULATIONS + 1))
                fi
            done
        fi
    done < <(find "$EXPERIMENTS_DIR" -maxdepth 1 -type d -name "h*_l*_t*" -print0 2>/dev/null)
}

# =============================================================================
# CONFIGURATION EXTRACTION
# =============================================================================

# Function to extract configuration from directory name
extract_config_from_dir() {
    local dir_name=$1
    # Format: h{N}_l{L}_t{T}
    local neurons=$(echo "$dir_name" | sed -n 's/h\([0-9]*\)_l[0-9]*_t[0-9]*/\1/p')
    local layers=$(echo "$dir_name" | sed -n 's/h[0-9]*_l\([0-9]*\)_t[0-9]*/\1/p')
    local timesteps=$(echo "$dir_name" | sed -n 's/h[0-9]*_l[0-9]*_t\([0-9]*\)/\1/p')
    
    echo "$neurons,$layers,$timesteps"
}

# Function to check if configuration should be processed
should_process_config() {
    local neurons=$1
    local layers=$2
    local config_name=$3
    
    # Quick test mode - only process first few configs
    if [[ "$QUICK_TEST_MODE" == true ]]; then
        # Only process h16_l1_t25 and h32_l1_t25 for quick testing
        if [[ ! "$config_name" =~ ^h(16|32)_l1_t25$ ]]; then
            return 1
        fi
    fi
    
    # Check neuron filter
    if [[ "$FILTER_NEURONS_ENABLED" == true ]]; then
        local found=false
        for filter_n in "${NEURON_FILTER[@]}"; do
            if [[ "$neurons" == "$filter_n" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            return 1
        fi
    fi
    
    # Check layer filter
    if [[ "$FILTER_LAYERS_ENABLED" == true ]]; then
        local found=false
        for filter_l in "${LAYER_FILTER[@]}"; do
            if [[ "$layers" == "$filter_l" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            return 1
        fi
    fi
    
    # Check configuration pattern filter
    if [[ "$FILTER_CONFIGURATIONS_ENABLED" == true ]]; then
        local found=false
        for pattern in "${CONFIGURATION_FILTER[@]}"; do
            if [[ "$config_name" =~ $pattern ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Function to check if timestep should be processed
should_process_timestep() {
    local timestep=$1
    
    # Check timestep filter
    if [[ "$FILTER_TIMESTEPS_ENABLED" == true ]]; then
        local found=false
        for filter_t in "${TIMESTEP_FILTER[@]}"; do
            if [[ "$timestep" == "$filter_t" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Function to apply combined filtering logic (for complex patterns like "all 1&2 layers + 3-layer with limited neurons")
should_process_experiment() {
    local neurons=$1
    local layers=$2
    local timestep=$3
    local config_name=$4
    
    # First check individual filters
    if ! should_process_config "$neurons" "$layers" "$config_name"; then
        return 1
    fi
    
    if ! should_process_timestep "$timestep"; then
        return 1
    fi
    
    # Advanced filtering logic for complex combinations
    if [[ "$FILTER_LAYERS_ENABLED" == true && "$FILTER_NEURONS_ENABLED" == true ]]; then
        # Special case: If filtering by both layers and neurons
        # Check if this is a 3-layer configuration with limited neurons
        if [[ "$layers" == "3" ]]; then
            # For 3-layer configs, only allow if neuron count is in the filter
            local neuron_allowed=false
            for filter_n in "${NEURON_FILTER[@]}"; do
                if [[ "$neurons" == "$filter_n" ]]; then
                    neuron_allowed=true
                    break
                fi
            done
            if [[ "$neuron_allowed" == false ]]; then
                return 1
            fi
        fi
    fi
    
    return 0
}

# =============================================================================
# FILE PREPARATION
# =============================================================================

# Function to prepare neuron mapping (data_mem.mem)
prepare_neuron_mapping() {
    local mapping_file=$1
    local output_file=$2
    
    info "Copying neuron mapping: $mapping_file -> $output_file"
    
    if [[ ! -f "$mapping_file" ]]; then
        error "Neuron mapping file not found: $mapping_file"
        return 1
    fi
    
    # Directly copy neuron mapping file (no conversion needed)
    if cp "$mapping_file" "$output_file"; then
        success "Copied neuron mapping to data_mem.mem"
        return 0
    else
        error "Failed to copy neuron mapping file"
        return 1
    fi
}

# Function to prepare spike memory (spike_mem.mem)
prepare_spike_memory() {
    local test_values_file=$1
    local inference_timesteps=$2
    local output_file=$3
    
    info "Preparing spike memory: $test_values_file (t=$inference_timesteps) -> $output_file"
    
    if [[ ! -f "$test_values_file" ]]; then
        error "Test values file not found: $test_values_file"
        return 1
    fi
    
    # Check if shared spike memory already exists
    local shared_spike_file="$SHARED_SPIKE_DIR/spike_mem_t${inference_timesteps}.mem"
    
    if [[ -f "$shared_spike_file" ]]; then
        info "Using cached spike memory: $shared_spike_file"
        ln -sf "$(realpath "$shared_spike_file")" "$output_file"
        return 0
    fi
    
    # Directly copy test values file (no conversion needed)
    # Copy to shared location first for caching
    if cp "$test_values_file" "$shared_spike_file"; then
        ln -sf "$(realpath "$shared_spike_file")" "$output_file"
        success "Copied spike memory from test values"
        return 0
    else
        error "Failed to copy test values to spike memory format"
        return 1
    fi
}

# =============================================================================
# VCS COMPILATION AND SIMULATION
# =============================================================================

# Function to compile testbench with VCS
compile_vcs() {
    info "Compiling testbench with VCS..."
    
    if [[ ! -f "$TESTBENCH_FILE" ]]; then
        error "Testbench file not found: $TESTBENCH_FILE"
        return 1
    fi
    
    # Clean previous compilation
    rm -rf csrc simv.daidir simv
    
    # Run VCS compilation
    log "Running: $VCS_EXECUTABLE $VCS_FLAGS $TESTBENCH_FILE -o simv"
    
    if [[ "$VERBOSE_MODE" == true ]]; then
        # Show output in real-time and log
        if $VCS_EXECUTABLE $VCS_FLAGS "$TESTBENCH_FILE" -o simv 2>&1 | tee -a "$LOG_FILE"; then
            success "VCS compilation successful"
            return 0
        else
            error "VCS compilation failed"
            return 1
        fi
    else
        # Only log to file
        if $VCS_EXECUTABLE $VCS_FLAGS "$TESTBENCH_FILE" -o simv >> "$LOG_FILE" 2>&1; then
            success "VCS compilation successful"
            return 0
        else
            error "VCS compilation failed. Check log file: $LOG_FILE"
            return 1
        fi
    fi
}

# Function to run simulation with runtime parameters
run_simulation() {
    local sim_name=$1
    local timeout=$2
    local time_step_window=$3
    local input_neurons=$4
    local nn_layers=$5
    local input_count=$6
    
    info "Running simulation: $sim_name"
    info "  Parameters: time_step_window=$time_step_window, input_neurons=$input_neurons, nn_layers=$nn_layers, input_count=$input_count"
    
    if [[ ! -f "$SIMV_EXECUTABLE" ]]; then
        error "Simulation executable not found: $SIMV_EXECUTABLE"
        error "Run compilation first or use without --skip-compile"
        return 1
    fi
    
    # Check if required memory files exist
    if [[ ! -f "$DATA_MEM_FILE" ]]; then
        error "data_mem.mem not found"
        return 1
    fi
    
    if [[ ! -f "$SPIKE_MEM_FILE" ]]; then
        error "spike_mem.mem not found"
        return 1
    fi
    
    # Build simulation flags with runtime parameter overrides
    local simv_flags="$SIMV_BASE_FLAGS"
    simv_flags="$simv_flags +time_step_window=$time_step_window"
    simv_flags="$simv_flags +input_neurons=$input_neurons"
    simv_flags="$simv_flags +nn_layers=$nn_layers"
    simv_flags="$simv_flags +input_count=$input_count"
    
    # Run simulation with timeout
    local start_time=$(date +%s)
    
    log "Running: $SIMV_EXECUTABLE $simv_flags"
    
    if [[ "$VERBOSE_MODE" == true ]]; then
        echo ""
        echo "=========================================="
        echo "SIMULATION OUTPUT (VERBOSE MODE)"
        echo "=========================================="
        # Show output in real-time and log
        if timeout "$timeout" $SIMV_EXECUTABLE $simv_flags 2>&1 | tee -a "$LOG_FILE"; then
            echo "=========================================="
            echo ""
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            success "Simulation completed: $sim_name (${duration}s)"
            echo "$duration"
            return 0
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                error "Simulation timed out after ${timeout}s: $sim_name"
            else
                error "Simulation failed: $sim_name (exit code: $exit_code)"
            fi
            echo "0"
            return 1
        fi
    else
        # Only log to file, but show progress
        info "Simulation running... (use -v to see output, or check log file)"
        if timeout "$timeout" $SIMV_EXECUTABLE $simv_flags >> "$LOG_FILE" 2>&1; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            success "Simulation completed: $sim_name (${duration}s)"
            echo "$duration"
            return 0
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                error "Simulation timed out after ${timeout}s: $sim_name"
            else
                error "Simulation failed: $sim_name (exit code: $exit_code)"
            fi
            echo "0"
            return 1
        fi
    fi
}

# =============================================================================
# ACCURACY CALCULATION
# =============================================================================

# Function to calculate accuracy using output decoder
calculate_accuracy() {
    local output_file=$1
    local labels_file=$2
    local sim_name=$3
    
    # Redirect ALL function output to stderr by default
    exec 3>&1 1>&2
    
    info "Calculating accuracy for: $sim_name"
    
    if [[ ! -f "$output_file" ]]; then
        error "Output file not found: $output_file"
        return 1
    fi
    
    if [[ ! -f "$labels_file" ]]; then
        error "Labels file not found: $labels_file"
        return 1
    fi
    
    if [[ ! -f "$OUTPUT_DECODER_SCRIPT" ]]; then
        error "Output decoder script not found: $OUTPUT_DECODER_SCRIPT"
        return 1
    fi
    
    # Create results subdirectory for this simulation
    local sim_results_dir="$RESULTS_DIR/$sim_name"
    mkdir -p "$sim_results_dir"
    
    # Run decoder and capture output
    local decoder_log="$sim_results_dir/decoder_output.log"
    
    # Run decoder (always capture to log file first)
    if python3 "$OUTPUT_DECODER_SCRIPT" \
        --output-file "$output_file" \
        --labels-file "$labels_file" \
        --no-details > "$decoder_log" 2>&1; then
        
        # Extract accuracy from decoder output
        local accuracy=$(grep -oP 'Test Accuracy:\s+\K[0-9]+\.[0-9]+' "$decoder_log" || echo "")
        
        if [[ -n "$accuracy" ]]; then
            success "Accuracy calculated: ${accuracy}% for $sim_name"
            
            # Show decoder output in verbose mode
            if [[ "$VERBOSE_MODE" == true ]]; then
                cat "$decoder_log"
            fi
            
            # Copy output file to results directory
            cp "$output_file" "$sim_results_dir/"
            cp "$labels_file" "$sim_results_dir/"
            
            # Restore stdout and return ONLY the accuracy number
            exec 1>&3 3>&-
            echo "$accuracy"
            return 0
        else
            error "Could not extract accuracy from decoder output"
            cat "$decoder_log" >> "$LOG_FILE"
            return 1
        fi
    else
        error "Decoder failed for: $sim_name"
        cat "$decoder_log" >> "$LOG_FILE"
        return 1
    fi
}

# =============================================================================
# MAIN PROCESSING FUNCTIONS
# =============================================================================

# Function to process a single configuration with specific inference timesteps
process_configuration() {
    local config_dir=$1
    local config_name=$(basename "$config_dir")
    
    # Extract configuration parameters
    local config_info=$(extract_config_from_dir "$config_name")
    local neurons=$(echo "$config_info" | cut -d',' -f1)
    local layers=$(echo "$config_info" | cut -d',' -f2)
    local train_timesteps=$(echo "$config_info" | cut -d',' -f3)
    
    # Check if should process
    if ! should_process_config "$neurons" "$layers" "$config_name"; then
        log "Skipping configuration: $config_name (filtered out by layer/neuron/pattern filter)"
        return 0
    fi
    
    log "=========================================="
    log "Processing configuration: $config_name"
    log "  Layers: $layers, Neurons: $neurons, Training timesteps: $train_timesteps"
    log "=========================================="
    
    # Locate neuron mapping file (try both models and mappings directories)
    local neuron_mapping=""
    if [[ -f "$config_dir/models/$NEURON_MAPPING_FILE" ]]; then
        neuron_mapping="$config_dir/models/$NEURON_MAPPING_FILE"
    elif [[ -f "$config_dir/mappings/$NEURON_MAPPING_FILE" ]]; then
        neuron_mapping="$config_dir/mappings/$NEURON_MAPPING_FILE"
    else
        error "Neuron mapping not found in $config_name"
        return 1
    fi
    
    # Locate test data directory
    local test_data_dir="$config_dir/test_data"
    if [[ ! -d "$test_data_dir" ]]; then
        error "Test data directory not found: $test_data_dir"
        return 1
    fi
    
    # Prepare neuron mapping (data_mem.mem)
    if ! prepare_neuron_mapping "$neuron_mapping" "$DATA_MEM_FILE"; then
        error "Failed to prepare neuron mapping for $config_name"
        return 1
    fi
    
    # Process each inference timestep
    for inf_timesteps in "${TIMESTEP_FILTER[@]}"; do
        # Check if this specific experiment combination should be processed
        if ! should_process_experiment "$neurons" "$layers" "$inf_timesteps" "$config_name"; then
            log "Skipping experiment: $config_name with timesteps $inf_timesteps (filtered out)"
            continue
        fi
        
        log "------------------------------------------"
        log "Testing with inference timesteps: $inf_timesteps"
        log "------------------------------------------"
        
        TOTAL_SIMULATIONS=$((TOTAL_SIMULATIONS + 1))
        
        # Locate test values file
        local test_values="$test_data_dir/${TEST_VALUES_PREFIX}${inf_timesteps}.txt"
        if [[ ! -f "$test_values" ]]; then
            warning "Test values not found: $test_values"
            printf "%s,%s,%s,%s,%s,%s\n" "$config_name" "$layers" "$neurons" "$train_timesteps" "$inf_timesteps" "N/A" >> "$RESULTS_CSV"
            continue
        fi
        
        # Locate test labels file (with timestep suffix)
        local test_labels="$test_data_dir/${TEST_LABELS_PREFIX}${inf_timesteps}.txt"
        if [[ ! -f "$test_labels" ]]; then
            warning "Test labels not found: $test_labels"
            printf "%s,%s,%s,%s,%s,%s\n" "$config_name" "$layers" "$neurons" "$train_timesteps" "$inf_timesteps" "N/A" >> "$RESULTS_CSV"
            continue
        fi
        
        # Prepare spike memory (spike_mem.mem)
        if ! prepare_spike_memory "$test_values" "$inf_timesteps" "$SPIKE_MEM_FILE"; then
            error "Failed to prepare spike memory for $config_name (t=$inf_timesteps)"
            printf "%s,%s,%s,%s,%s,%s\n" "$config_name" "$layers" "$neurons" "$train_timesteps" "$inf_timesteps" "N/A" >> "$RESULTS_CSV"
            continue
        fi
        
        # Calculate simulation parameters
        # Use inference timesteps as the time_step_window
        local time_step_window=$inf_timesteps
        local input_neurons=$SIMULATION_INPUT_NEURONS
        local nn_layers=$((layers + 1))  # Hidden layers + output layer
        local input_count=$SIMULATION_INPUT_COUNT
        
        # Run simulation with parameters
        local sim_name="${config_name}_inf${inf_timesteps}"
        local sim_duration
        
        if sim_duration=$(run_simulation "$sim_name" "$TIMEOUT_SECONDS" "$time_step_window" "$input_neurons" "$nn_layers" "$input_count"); then
            
            # Calculate accuracy (capture in a subshell to completely isolate)
            local accuracy
            debug "About to call calculate_accuracy function"
            accuracy=$(calculate_accuracy "$OUTPUT_FILE" "$test_labels" "$sim_name" 2>/dev/null)
            local calc_result=$?
            debug "calculate_accuracy returned: exit_code=$calc_result, accuracy='$accuracy'"
            
            if [[ $calc_result -eq 0 && -n "$accuracy" ]]; then
                success "✓ Completed: $sim_name - Accuracy: ${accuracy}%"
                # Write CSV entry directly (completely isolated)
                local csv_line="$config_name,$layers,$neurons,$train_timesteps,$inf_timesteps,$accuracy"
                debug "Writing to CSV: '$csv_line'"
                {
                    echo "$csv_line"
                } >> "$RESULTS_CSV"
                debug "CSV write completed"
                SUCCESSFUL_SIMULATIONS=$((SUCCESSFUL_SIMULATIONS + 1))
            else
                error "✗ Accuracy calculation failed: $sim_name"
                local csv_line="$config_name,$layers,$neurons,$train_timesteps,$inf_timesteps,N/A"
                debug "Writing to CSV (failed): '$csv_line'"
                {
                    echo "$csv_line"
                } >> "$RESULTS_CSV"
                FAILED_SIMULATIONS=$((FAILED_SIMULATIONS + 1))
            fi
        else
            error "✗ Simulation failed: $sim_name"
            printf "%s,%s,%s,%s,%s,%s\n" "$config_name" "$layers" "$neurons" "$train_timesteps" "$inf_timesteps" "N/A" >> "$RESULTS_CSV"
            FAILED_SIMULATIONS=$((FAILED_SIMULATIONS + 1))
        fi
        
        # Clean up simulation outputs for next run
        rm -f "$OUTPUT_FILE"
    done
    
    # Clean up memory files after processing this configuration
    rm -f "$DATA_MEM_FILE" "$SPIKE_MEM_FILE"
    
    success "Completed all tests for configuration: $config_name"
}

# =============================================================================
# SUMMARY AND REPORTING
# =============================================================================

# Function to generate summary report
generate_summary() {
    log ""
    log "=========================================="
    log "SIMULATION SUMMARY"
    log "=========================================="
    log "Expected simulations: $EXPECTED_SIMULATIONS"
    log "Total simulations run: $TOTAL_SIMULATIONS"
    log "Successful: $SUCCESSFUL_SIMULATIONS"
    log "Failed: $FAILED_SIMULATIONS"
    if [[ $TOTAL_SIMULATIONS -gt 0 ]]; then
        log "Success rate: $(awk "BEGIN {printf \"%.1f\", ($SUCCESSFUL_SIMULATIONS/$TOTAL_SIMULATIONS)*100}")%"
    else
        log "Success rate: N/A (no simulations run)"
    fi
    log "=========================================="
    
    # Find best accuracies
    if [[ $SUCCESSFUL_SIMULATIONS -gt 0 ]]; then
        log ""
        log "TOP 5 ACCURACIES:"
        log "------------------------------------------"
        # Parse CSV correctly: skip header, filter SUCCESS, sort by accuracy (column 6), show top 5
        tail -n +2 "$RESULTS_CSV" | grep -v "N/A" | sort -t',' -k6 -nr | head -5 | while IFS=',' read -r config layers neurons train_t inf_t accuracy; do
            log "  ${config} (inf_t=${inf_t}): ${accuracy}%"
        done
        log "=========================================="
    fi
    
    log ""
    log "All outputs in: $SIMULATIONS_DIR/"
    log "Results CSV: $RESULTS_CSV"
    log "Detailed logs: $LOG_FILE"
    log "Individual results: $RESULTS_DIR/"
    log ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Print header
    echo ""
    echo "=========================================="
    echo "NEURON ACCELERATOR SIMULATION AUTOMATION"
    echo "=========================================="
    echo ""
    
    # Clean if requested (before initializing results)
    if [[ "$CLEAN_MODE" == true ]]; then
        clean_previous_results
    fi
    
    # Count expected simulations before initializing results
    count_expected_simulations
    
    # Initialize results (creates directories including log file location)
    initialize_results
    
    log "Starting simulation automation"
    log "Base directory: $BASE_DIR"
    log "Experiments directory: $EXPERIMENTS_DIR"
    log "Output decoder: $OUTPUT_DECODER_SCRIPT"
    log ""
    
    # Show filtering information
    log "Configuration Summary:"
    if [[ "$QUICK_TEST_MODE" == true ]]; then
        log "Mode: Quick Test (limited configurations)"
    else
        log "Mode: Full Simulation"
    fi
    
    if [[ "$FILTER_LAYERS_ENABLED" == true ]]; then
        log "Layer filter: ${LAYER_FILTER[*]}"
    else
        log "Layers: ${HIDDEN_LAYERS[*]} (all)"
    fi
    
    if [[ "$FILTER_NEURONS_ENABLED" == true ]]; then
        log "Neuron filter: ${NEURON_FILTER[*]}"
    else
        log "Neurons: ${HIDDEN_NEURONS[*]} (all)"
    fi
    
    log "Inference timesteps: ${TIMESTEP_FILTER[*]}"
    
    if [[ "$FILTER_CONFIGURATIONS_ENABLED" == true ]]; then
        log "Configuration patterns: ${CONFIGURATION_FILTER[*]}"
    fi
    
    log "Output CSV: $OUTPUT_CSV"
    log "Output directory: $OUTPUT_DIR"
    
    if [[ "$VERBOSE_MODE" == true ]]; then
        log "Verbose mode: ENABLED (showing tool outputs)"
    else
        log "Verbose mode: DISABLED (use -v to see tool outputs)"
    fi
    
    # Check if experiments directory exists
    if [[ ! -d "$EXPERIMENTS_DIR" ]]; then
        error "Experiments directory not found: $EXPERIMENTS_DIR"
        exit 1
    fi
    
    # Check if output decoder exists
    if [[ ! -f "$OUTPUT_DECODER_SCRIPT" ]]; then
        error "Output decoder script not found: $OUTPUT_DECODER_SCRIPT"
        exit 1
    fi
    
    # Compile VCS if needed
    if [[ "$SKIP_COMPILE" == false ]]; then
        if ! compile_vcs; then
            error "VCS compilation failed. Exiting."
            exit 1
        fi
        
        if [[ "$COMPILE_ONLY" == true ]]; then
            success "Compilation completed. Exiting (--compile-only mode)."
            exit 0
        fi
    else
        info "Skipping compilation (--skip-compile mode)"
        if [[ ! -f "$SIMV_EXECUTABLE" ]]; then
            error "No simulation executable found and --skip-compile was used"
            exit 1
        fi
    fi
    
    # Find all configuration directories
    local config_dirs=()
    while IFS= read -r -d '' dir; do
        config_dirs+=("$dir")
    done < <(find "$EXPERIMENTS_DIR" -maxdepth 1 -type d -name "h*_l*_t*" -print0 | sort -z)
    
    if [[ ${#config_dirs[@]} -eq 0 ]]; then
        error "No configuration directories found in: $EXPERIMENTS_DIR"
        exit 1
    fi
    
    log "Found ${#config_dirs[@]} configuration directories"
    
    # Process each configuration
    for config_dir in "${config_dirs[@]}"; do
        process_configuration "$config_dir"
        echo "" >> "$LOG_FILE"
    done
    
    # Generate summary
    generate_summary
    
    success "Simulation automation completed!"
    echo ""
    echo "All outputs saved in: $SIMULATIONS_DIR/"
    echo "  - Results CSV: $RESULTS_CSV"
    echo "  - Logs: $LOG_FILE"
    echo "  - Individual results: $RESULTS_DIR/"
    echo ""
}

# Handle script interruption
cleanup() {
    warning "Script interrupted by user"
    generate_summary
    exit 1
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
