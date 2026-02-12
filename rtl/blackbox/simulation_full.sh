#!/bin/bash

# Neural Network Simulation Runner
# This script automates the complete testing pipeline for spiking neural networks
# It processes all model configurations, generates memory files, runs simulations, and collects accuracy results

set -e  # Exit on any error

# Configuration
BASE_DIR="../../models/smnist_lif_model/snn_experiments"
BLACKBOX_DIR="."
GEN_DATA_DIR="../../models/gen_blackbox_data"
SHARED_SPIKE_DIR="shared_spike_mem"
RESULTS_FILE="simulation_results.csv"
LOG_FILE="simulation.log"
FIXED_TEST_LABELS="./shared_spike_mem/test_labels.txt"  # Fixed test labels file

# Logging function - writes only to log file, not to CSV
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[ERROR] $1" | tee -a "$LOG_FILE"
}

success() {
    echo "[SUCCESS] $1" | tee -a "$LOG_FILE"
}

warning() {
    echo "[WARNING] $1" | tee -a "$LOG_FILE"
}

# Function to write to CSV - ONLY writes to CSV file, no logging mixed in
write_to_csv() {
    local csv_line="$1"
    # Write directly to CSV file without any logging interference
    echo "$csv_line" >> "$RESULTS_FILE"
}

# Function to extract configuration from folder name
extract_config() {
    local folder_name=$1
    # Extract layers, neurons, and time steps from folder name like "l1_n128_t20"
    local layers=$(echo "$folder_name" | sed 's/l\([0-9]*\)_n[0-9]*_t[0-9]*/\1/')
    local neurons=$(echo "$folder_name" | sed 's/l[0-9]*_n\([0-9]*\)_t[0-9]*/\1/')
    local time_steps=$(echo "$folder_name" | sed 's/l[0-9]*_n[0-9]*_t\([0-9]*\)/\1/')
    echo "$layers,$neurons,$time_steps"
}

# Function to check if required files exist
check_files() {
    local config_dir=$1
    local required_files=("neuron_mapping.txt")
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$config_dir/$file" ]]; then
            error "Required file not found: $config_dir/$file"
            return 1
        fi
    done
    return 0
}

# Function to check inference data files (now only checks test values, not test labels)
check_inference_files() {
    local inference_dir=$1
    local time_step=$2
    
    local test_values="test_values_t${time_step}.txt"
    
    if [[ ! -f "$inference_dir/$test_values" ]]; then
        error "Test values file not found: $inference_dir/$test_values"
        return 1
    fi
    
    echo "$test_values"
}

# Function to check if fixed test labels file exists
check_fixed_test_labels() {
    if [[ ! -f "$FIXED_TEST_LABELS" ]]; then
        error "Fixed test labels file not found: $FIXED_TEST_LABELS"
        return 1
    fi
    return 0
}

# Function to generate data_mem.mem
generate_data_mem() {
    local neuron_mapping_file=$1
    local output_file="data_mem.mem"
    
    log "Generating $output_file from $neuron_mapping_file"
    
    # Redirect output to log file to prevent CSV contamination
    if python3 "$GEN_DATA_DIR/convert_init.py" "$neuron_mapping_file" -o "$output_file" -v >> "$LOG_FILE" 2>&1; then
        success "Generated $output_file"
        return 0
    else
        error "Failed to generate $output_file"
        return 1
    fi
}

# Function to generate spike_mem.mem (shared across configurations)
generate_spike_mem() {
    local test_values_file=$1
    local time_steps=$2
    local shared_spike_file="$SHARED_SPIKE_DIR/spike_mem_t${time_steps}.mem"
    local current_spike_file="spike_mem.mem"
    
    # Create shared directory if it doesn't exist
    mkdir -p "$SHARED_SPIKE_DIR"
    
    # Check if shared spike memory file already exists
    if [[ -f "$shared_spike_file" ]]; then
        log "Using existing shared spike memory file: $shared_spike_file"
        # Create symlink or copy to current directory
        ln -sf "$(realpath "$shared_spike_file")" "$current_spike_file"
        success "Linked existing spike_mem.mem for time steps: $time_steps"
        return 0
    fi
    
    log "Generating new shared spike memory file: $shared_spike_file from $test_values_file with time steps: $time_steps"
    
    # Redirect output to log file to prevent CSV contamination
    if python3 "$GEN_DATA_DIR/convert_spikes.py" "$test_values_file" -t "$time_steps" -o "$shared_spike_file" >> "$LOG_FILE" 2>&1; then
        # Create symlink to current directory
        ln -sf "$(realpath "$shared_spike_file")" "$current_spike_file"
        success "Generated and linked shared spike_mem.mem for time steps: $time_steps"
        return 0
    else
        error "Failed to generate $shared_spike_file"
        return 1
    fi
}

# Function to run simulation
run_simulation() {
    local sim_name=$1
    
    log "Running simulation: $sim_name"
    
    # Check if simv executable exists
    if [[ ! -f "./simv" ]]; then
        error "Simulation executable ./simv not found"
        return 1
    fi
    
    # Run simulation with output redirected to log file
    if ./simv +fsdb+all=on +fsdb+delta >> "$LOG_FILE" 2>&1; then
        success "Simulation completed: $sim_name"
        return 0
    else
        error "Simulation failed or timed out: $sim_name"
        return 1
    fi
}

# Function to decode results
decode_results() {
    local sim_name=$1
    
    log "Decoding results for: $sim_name"
    
    # Create log directory if it doesn't exist
    mkdir -p log
    
    if python3 "$GEN_DATA_DIR/decode.py" > "log/decode_${sim_name}.log" 2>&1; then
        success "Decoded results for: $sim_name"
        return 0
    else
        error "Failed to decode results for: $sim_name"
        return 1
    fi
}

# Function to calculate accuracy (now uses fixed test labels file)
calculate_accuracy() {
    local sim_name=$1
    
    log "Calculating accuracy for: $sim_name using fixed test labels: $FIXED_TEST_LABELS"
    
    if [[ ! -f "spike_outputs.txt" ]]; then
        error "spike_outputs.txt not found for accuracy calculation"
        return 1
    fi
    
    # Check if fixed test labels file exists
    if ! check_fixed_test_labels; then
        return 1
    fi
    
    # Log directory should already exist, but ensure it's there
    mkdir -p log
    
    # Run accuracy calculation and capture output properly
    local accuracy_log_file="log/accuracy_${sim_name}.log"
    local temp_output_file=$(mktemp)
    
    # Run accuracy script with fixed test labels file
    if python3 "$GEN_DATA_DIR/accuracy.py" "spike_outputs.txt" "$FIXED_TEST_LABELS" > "$temp_output_file" 2>&1; then
        # Copy output to log file
        cp "$temp_output_file" "$accuracy_log_file"
        
        # Extract accuracy percentage from output
        local accuracy=""
        accuracy=$(grep -oE 'Accuracy:\s*[0-9]+\.[0-9]+' "$accuracy_log_file" | grep -oE '[0-9]+\.[0-9]+' | head -1 2>/dev/null || true)
        
        if [[ -n "$accuracy" ]]; then
            success "Accuracy calculated: $accuracy% for $sim_name"
            rm -f "$temp_output_file"
            ACCURACY_RESULT="$accuracy"   # <-- assign to global variable
            return 0
        else
            error "Could not extract accuracy from output for: $sim_name"
            log "Accuracy script output for debugging:"
            cat "$temp_output_file" >> "$LOG_FILE"
            rm -f "$temp_output_file"
            return 1
        fi
    else
        local exit_code=$?
        # Copy failed output to log file
        cp "$temp_output_file" "$accuracy_log_file"
        error "Failed to calculate accuracy for: $sim_name (exit code: $exit_code)"
        log "Error output:"
        cat "$temp_output_file" >> "$LOG_FILE"
        rm -f "$temp_output_file"
        return 1
    fi
}

# Function to process a single configuration
process_configuration() {
    local config_dir=$1
    local config_name=$(basename "$config_dir")
    local config_info=$(extract_config "$config_name")
    local layers=$(echo "$config_info" | cut -d',' -f1)
    local neurons=$(echo "$config_info" | cut -d',' -f2)
    local time_steps=$(echo "$config_info" | cut -d',' -f3)
    
    log "Processing configuration: $config_name (L:$layers, N:$neurons, T:$time_steps)"
    
    # Check required files
    if ! check_files "$config_dir"; then
        return 1
    fi
    
    # Generate data_mem.mem
    if ! generate_data_mem "$config_dir/neuron_mapping.txt"; then
        return 1
    fi
    
    # Check for inference data directory
    local inference_dir="$config_dir/inference_data"
    if [[ ! -d "$inference_dir" ]]; then
        warning "No inference data directory found for $config_name"
        return 1
    fi
    
    # Initialize accuracy results array - Updated to include all time steps
    local accuracy_t10="N/A"
    local accuracy_t20="N/A"
    local accuracy_t40="N/A"
    local accuracy_t50="N/A"
    local accuracy_t100="N/A"
    local accuracy_t200="N/A"
    
    # Process different time step configurations - Updated to include new time steps
    local inference_time_steps=(10 20 40 50 100 200)
    
    for inf_time in "${inference_time_steps[@]}"; do
        log "Processing inference time steps: $inf_time for $config_name"
        
        # Check inference files (only test values now)
        local test_values
        if test_values=$(check_inference_files "$inference_dir" "$inf_time"); then
            
            # Generate spike_mem.mem
            if generate_spike_mem "$inference_dir/$test_values" "$inf_time"; then
                
                # Run simulation
                local sim_name="${config_name}_inf${inf_time}"
                if run_simulation "$sim_name"; then
                    
                    # Decode results
                    if decode_results "$sim_name"; then
                        
                        # Calculate accuracy (now uses fixed test labels)
                        local accuracy
                        if calculate_accuracy "$sim_name"; then
                            accuracy="$ACCURACY_RESULT"
                            # Store accuracy based on inference time steps - Updated to include all time steps
                            case $inf_time in
                                10) accuracy_t10="$accuracy" ;;
                                20) accuracy_t20="$accuracy" ;;
                                40) accuracy_t40="$accuracy" ;;
                                50) accuracy_t50="$accuracy" ;;
                                100) accuracy_t100="$accuracy" ;;
                                200) accuracy_t200="$accuracy" ;;
                            esac
                            
                            success "Completed processing: $sim_name with accuracy: $accuracy%"
                        else
                            warning "Accuracy calculation failed for: $sim_name"
                            case $inf_time in
                                10) accuracy_t10="FAILED" ;;
                                20) accuracy_t20="FAILED" ;;
                                40) accuracy_t40="FAILED" ;;
                                50) accuracy_t50="FAILED" ;;
                                100) accuracy_t100="FAILED" ;;
                                200) accuracy_t200="FAILED" ;;
                            esac
                        fi
                    else
                        warning "Decode failed for: $sim_name"
                        case $inf_time in
                            10) accuracy_t10="DECODE_FAILED" ;;
                            20) accuracy_t20="DECODE_FAILED" ;;
                            40) accuracy_t40="DECODE_FAILED" ;;
                            50) accuracy_t50="DECODE_FAILED" ;;
                            100) accuracy_t100="DECODE_FAILED" ;;
                            200) accuracy_t200="DECODE_FAILED" ;;
                        esac
                    fi
                else
                    warning "Simulation failed for: $sim_name"
                    case $inf_time in
                        10) accuracy_t10="SIM_FAILED" ;;
                        20) accuracy_t20="SIM_FAILED" ;;
                        40) accuracy_t40="SIM_FAILED" ;;
                        50) accuracy_t50="SIM_FAILED" ;;
                        100) accuracy_t100="SIM_FAILED" ;;
                        200) accuracy_t200="SIM_FAILED" ;;
                    esac
                fi
            else
                warning "Spike memory generation failed for: $sim_name"
                case $inf_time in
                    10) accuracy_t10="SPIKE_MEM_FAILED" ;;
                    20) accuracy_t20="SPIKE_MEM_FAILED" ;;
                    40) accuracy_t40="SPIKE_MEM_FAILED" ;;
                    50) accuracy_t50="SPIKE_MEM_FAILED" ;;
                    100) accuracy_t100="SPIKE_MEM_FAILED" ;;
                    200) accuracy_t200="SPIKE_MEM_FAILED" ;;
                esac
            fi
        else
            warning "Required inference files not found for time step $inf_time in $config_name"
            case $inf_time in
                10) accuracy_t10="FILES_MISSING" ;;
                20) accuracy_t20="FILES_MISSING" ;;
                40) accuracy_t40="FILES_MISSING" ;;
                50) accuracy_t50="FILES_MISSING" ;;
                100) accuracy_t100="FILES_MISSING" ;;
                200) accuracy_t200="FILES_MISSING" ;;
            esac
        fi
    done
    
    # Write single row to CSV with all accuracy results - Updated to include all time steps
    write_to_csv "$config_name,$layers,$neurons,$time_steps,$accuracy_t10,$accuracy_t20,$accuracy_t40,$accuracy_t50,$accuracy_t100,$accuracy_t200"
    success "Completed configuration: $config_name"
}

# Function to initialize shared spike memory files
initialize_shared_spike_mem() {
    log "Initializing shared spike memory files..."
    
    # Create shared directory
    mkdir -p "$SHARED_SPIKE_DIR"
    
    # Check if fixed test labels file exists, if not try to find one to copy
    if [[ ! -f "$FIXED_TEST_LABELS" ]]; then
        log "Fixed test labels file not found, attempting to create from available data..."
        
        # Find any configuration with inference data to copy test labels
        local sample_config_dir=""
        while IFS= read -r -d '' dir; do
            if [[ -d "$dir/inference_data" ]]; then
                sample_config_dir="$dir"
                break
            fi
        done < <(find "$BASE_DIR" -maxdepth 1 -type d -name "l*_n*_t*" -print0)
        
        if [[ -n "$sample_config_dir" ]]; then
            local inference_dir="$sample_config_dir/inference_data"
            # Look for any test labels file to copy as the fixed one
            local sample_labels_file=""
            for time_step in 10 20 40 50 100 200; do
                local test_labels="test_labels_t${time_step}.txt"
                if [[ -f "$inference_dir/$test_labels" ]]; then
                    sample_labels_file="$inference_dir/$test_labels"
                    break
                fi
            done
            
            if [[ -n "$sample_labels_file" ]]; then
                log "Copying $sample_labels_file to $FIXED_TEST_LABELS"
                cp "$sample_labels_file" "$FIXED_TEST_LABELS"
                success "Created fixed test labels file: $FIXED_TEST_LABELS"
            else
                warning "No test labels file found to create fixed test labels file"
            fi
        else
            warning "No configuration with inference data found"
        fi
    else
        log "Fixed test labels file already exists: $FIXED_TEST_LABELS"
    fi
    
    # Find any configuration with inference data to generate shared spike memory files
    local sample_config_dir=""
    while IFS= read -r -d '' dir; do
        if [[ -d "$dir/inference_data" ]]; then
            sample_config_dir="$dir"
            break
        fi
    done < <(find "$BASE_DIR" -maxdepth 1 -type d -name "l*_n*_t*" -print0)
    
    if [[ -z "$sample_config_dir" ]]; then
        warning "No configuration with inference data found for shared spike memory generation"
        return 1
    fi
    
    local inference_dir="$sample_config_dir/inference_data"
    # Updated to include all time steps
    local inference_time_steps=(10 20 40 50 100 200)
    
    for inf_time in "${inference_time_steps[@]}"; do
        local test_values="test_values_t${inf_time}.txt"
        local shared_spike_file="$SHARED_SPIKE_DIR/spike_mem_t${inf_time}.mem"
        
        if [[ ! -f "$shared_spike_file" ]]; then
            if [[ -f "$inference_dir/$test_values" ]]; then
                log "Generating shared spike memory for time steps: $inf_time"
                if python3 "$GEN_DATA_DIR/convert_spikes.py" "$inference_dir/$test_values" -t "$inf_time" -o "$shared_spike_file" >> "$LOG_FILE" 2>&1; then
                    success "Generated shared spike memory: $shared_spike_file"
                else
                    error "Failed to generate shared spike memory for time steps: $inf_time"
                    return 1
                fi
            else
                warning "Test values file not found: $inference_dir/$test_values"
            fi
        else
            log "Shared spike memory already exists: $shared_spike_file"
        fi
    done
}

# Function to archive previous logs
archive_previous_logs() {
    if [[ -d "log" ]]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local archive_dir="log_archive_${timestamp}"
        
        log "Archiving previous log directory to: $archive_dir"
        mv "log" "$archive_dir"
        success "Previous logs archived to: $archive_dir"
    fi
    
    # Create fresh log directory
    mkdir -p log
}

# Function to clean and validate CSV file
clean_and_validate_csv() {
    local csv_file="$1"
    if [[ -f "$csv_file" ]]; then
        log "Cleaning and validating CSV file: $csv_file"
        
        # Create a temporary file for cleaned CSV
        local temp_csv=$(mktemp)
        
        # Remove any ANSI color codes and ensure proper CSV format
        sed 's/\x1b\[[0-9;]*m//g' "$csv_file" | \
        grep -v '^\[' | \
        grep -E '^(Configuration|l[0-9]+_n[0-9]+_t[0-9]+)' > "$temp_csv"
        
        # Replace original file with cleaned version
        mv "$temp_csv" "$csv_file"
        
        success "Cleaned and validated CSV file: $csv_file"
        
        # Show CSV contents for verification
        log "CSV file contents:"
        cat "$csv_file" >> "$LOG_FILE"
    fi
}

# Main execution function
main() {
    log "Starting Neural Network Simulation Runner"
    log "Base directory: $BASE_DIR"
    log "Results file: $RESULTS_FILE"
    log "Fixed test labels file: $FIXED_TEST_LABELS"
    
    # Archive previous logs and create fresh log directory
    archive_previous_logs
    
    # Initialize shared spike memory files
    initialize_shared_spike_mem
    
    # Archive previous results file if it exists
    if [[ -f "$RESULTS_FILE" ]]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local archive_results="results_archive_${timestamp}.csv"
        log "Archiving previous results file to: $archive_results"
        mv "$RESULTS_FILE" "$archive_results"
        success "Previous results archived to: $archive_results"
    fi
    
    # Initialize results file with header - Updated to include all time steps
    echo "Configuration,Layers,Neurons,TimeSteps,Accuracy_T10,Accuracy_T20,Accuracy_T40,Accuracy_T50,Accuracy_T100,Accuracy_T200" > "$RESULTS_FILE"
    
    # Check if base directory exists
    if [[ ! -d "$BASE_DIR" ]]; then
        error "Base directory not found: $BASE_DIR"
        exit 1
    fi
    
    # Check if required Python scripts exist
    local required_scripts=("convert_init.py" "convert_spikes.py" "decode.py" "accuracy.py")
    for script in "${required_scripts[@]}"; do
        if [[ ! -f "$GEN_DATA_DIR/$script" ]]; then
            error "Required script not found: $GEN_DATA_DIR/$script"
            exit 1
        fi
    done
    
    # Find all configuration directories
    local config_dirs=()
    while IFS= read -r -d '' dir; do
        config_dirs+=("$dir")
    done < <(find "$BASE_DIR" -maxdepth 1 -type d -name "l*_n*_t*" -print0 | sort -z)
    
    if [[ ${#config_dirs[@]} -eq 0 ]]; then
        error "No configuration directories found in $BASE_DIR"
        exit 1
    fi
    
    log "Found ${#config_dirs[@]} configuration directories"
    
    # Process each configuration
    local total_configs=${#config_dirs[@]}
    local current_config=0
    
    for config_dir in "${config_dirs[@]}"; do
        current_config=$((current_config + 1))
        log "Processing configuration $current_config/$total_configs: $(basename "$config_dir")"
        
        process_configuration "$config_dir"
        
        log "Completed configuration $current_config/$total_configs"
        echo "----------------------------------------" >> "$LOG_FILE"
    done
    
    # Clean and validate the final CSV file
    clean_and_validate_csv "$RESULTS_FILE"
    
    # Generate summary
    log "Generating summary..."
    
    local total_configs_processed=$(tail -n +2 "$RESULTS_FILE" | wc -l)
    local successful_configs=$(tail -n +2 "$RESULTS_FILE" | grep -c -E '[0-9]+\.[0-9]+' || echo "0")
    local failed_configs=$((total_configs_processed - successful_configs))
    
    success "Simulation completed!"
    success "Total configurations processed: $total_configs_processed"
    success "Successful configurations: $successful_configs"
    success "Failed configurations: $failed_configs"
    success "Results saved to: $RESULTS_FILE"
    success "Log saved to: $LOG_FILE"
    
    # Show best accuracies - Updated to include all time steps
    if [[ $successful_configs -gt 0 ]]; then
        local best_t10=$(tail -n +2 "$RESULTS_FILE" | awk -F',' '{print $5}' | grep -E '^[0-9]+\.[0-9]+$' | sort -nr | head -1 || echo "")
        local best_t20=$(tail -n +2 "$RESULTS_FILE" | awk -F',' '{print $6}' | grep -E '^[0-9]+\.[0-9]+$' | sort -nr | head -1 || echo "")
        local best_t40=$(tail -n +2 "$RESULTS_FILE" | awk -F',' '{print $7}' | grep -E '^[0-9]+\.[0-9]+$' | sort -nr | head -1 || echo "")
        local best_t50=$(tail -n +2 "$RESULTS_FILE" | awk -F',' '{print $8}' | grep -E '^[0-9]+\.[0-9]+$' | sort -nr | head -1 || echo "")
        local best_t100=$(tail -n +2 "$RESULTS_FILE" | awk -F',' '{print $9}' | grep -E '^[0-9]+\.[0-9]+$' | sort -nr | head -1 || echo "")
        local best_t200=$(tail -n +2 "$RESULTS_FILE" | awk -F',' '{print $10}' | grep -E '^[0-9]+\.[0-9]+$' | sort -nr | head -1 || echo "")
        
        if [[ -n "$best_t10" ]]; then
            success "Best accuracy for T10: $best_t10%"
        fi
        if [[ -n "$best_t20" ]]; then
            success "Best accuracy for T20: $best_t20%"
        fi
        if [[ -n "$best_t40" ]]; then
            success "Best accuracy for T40: $best_t40%"
        fi
        if [[ -n "$best_t50" ]]; then
            success "Best accuracy for T50: $best_t50%"
        fi
        if [[ -n "$best_t100" ]]; then
            success "Best accuracy for T100: $best_t100%"
        fi
        if [[ -n "$best_t200" ]]; then
            success "Best accuracy for T200: $best_t200%"
        fi
    fi
    
    # Display final CSV file
    log "Final CSV Results:"
    cat "$RESULTS_FILE" >> "$LOG_FILE"
    
    echo ""
    echo "CSV file created successfully: $RESULTS_FILE"
    echo "Check the log file for detailed execution info: $LOG_FILE"
}

# Handle script interruption
cleanup() {
    warning "Script interrupted by user"
    exit 1
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"