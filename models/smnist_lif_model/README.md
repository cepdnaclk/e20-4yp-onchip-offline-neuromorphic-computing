# Spiking MNIST Classifier for Neuromorphic Hardware

A configurable Spiking Neural Network (SNN) implementation for MNIST digit classification, designed to generate hardware deployment mappings for neuromorphic accelerators.

## Overview

This project implements a **Leaky Integrate-and-Fire (LIF)** spiking neural network that:

- Trains on the MNIST handwritten digit dataset
- Uses rate-based Poisson encoding for input spikes
- Generates hardware deployment configurations
- Exports trained weights and neuron mappings for FPGA/ASIC implementation

**Default Architecture:**

- **Input**: 784 neurons (28×28 pixels)
- **Hidden**: 128 neurons × 1 layer (configurable)
- **Output**: 10 neurons (digit classes 0-9)
- **Time steps**: 25 (configurable)

## Features

- Configurable network architecture (neurons, layers, time steps)
- GPU acceleration with CUDA support
- CPU fallback for systems without GPU
- Early stopping to prevent overtraining
- Automatic hardware mapping generation
- Progress tracking with percentage display
- Memory-efficient spike accumulation
- Comprehensive error reporting
- Flexible output directory management

## Installation

### Prerequisites

- **Python**: 3.8 or higher (3.10+ recommended)
- **RAM**: 4GB minimum (8GB+ recommended)
- **GPU**: Optional but highly recommended (NVIDIA with CUDA)
- **Storage**: ~500MB for MNIST dataset and dependencies

### Important: Use Virtual Environment

Modern Linux distributions (Ubuntu 24.04+) prevent system-wide pip installations. Create a virtual environment first:

```bash
cd models/smnist_lif_model

# Create virtual environment
python3 -m venv venv

# Activate it
source venv/bin/activate  # Linux/Mac
# or: venv\Scripts\activate  # Windows
```

Your prompt will show `(venv)` when activated. All subsequent installations happen in this isolated environment.

### Step 1: Install PyTorch

**For CPU:**

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
```

**For GPU (CUDA 11.8):**

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu118
```

**For GPU (CUDA 12.1):**

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
```

### Step 2: Install Core Dependencies

```bash
pip install snntorch numpy
```

### Step 3: Install model_compiler

The `neuron_mapper` module from `model_compiler` is required for hardware deployment.

**Standard installation:**

```bash
pip install ../model_compiler
```

**Editable installation (for development):**

```bash
pip install -e ../model_compiler
```

The `-e` flag installs in editable mode, meaning changes to `model_compiler` are immediately reflected without reinstalling.

### Step 4: Verify Installation

```bash
python -c "import torch, snntorch; from neuron_mapper import Neuron_Mapper; print(f'PyTorch: {torch.__version__}'); print(f'CUDA: {torch.cuda.is_available()}'); print('neuron_mapper: OK')"
```

Expected output:

```
PyTorch: 2.x.x
CUDA: True  # or False for CPU-only
neuron_mapper: OK
```

### Quick Install (All-in-One)

If you have `requirements.txt`:

```bash
# Inside virtual environment
pip install -r requirements.txt
pip install -e ../model_compiler
```

## Quick Start

### Basic Training (CPU)

```bash
cd src
python smnist_train.py --cpu --epochs 5
```

### GPU Training (Default)

```bash
cd src
python smnist_train.py
```

### View Help

```bash
python smnist_train.py --help
```

### View Usage Examples

```bash
python smnist_train.py --examples
```

---

## Scripts Overview

This project includes three main scripts for different stages of the neuromorphic deployment pipeline:

### 1. `smnist_train.py` - Train Spiking Neural Networks

**Purpose**: Train SNN models on MNIST dataset and generate initial neuron mappings.

**Key Features**:

- Configurable architecture (neurons, layers, time steps)
- GPU/CPU support with automatic fallback
- Early stopping to prevent overfitting
- Automatic neuron mapping generation
- Progress tracking and comprehensive error reporting

**Quick Example**:

```bash
python smnist_train.py --hidden-neurons 256 --hidden-layers 2 --epochs 10
```

**Output**:

- `outputs/spiking_mnist_h256_l2_t25.pth` - Trained model weights
- `outputs/neuron_mapping.txt` - Hardware deployment configuration

---

### 2. `smnist_generate_mapping.py` - Generate Hardware Mappings

**Purpose**: Load pre-trained models and generate neuron mappings for hardware deployment without retraining.

**Key Features**:

- Auto-detects architecture from filename
- Manual parameter override support
- Model analysis and parameter counting
- Secure model loading with `weights_only=True`
- Multiple filename pattern support

**Quick Example**:

```bash
python smnist_generate_mapping.py --model-path ../outputs/spiking_mnist_h128_l1_t25.pth
```

**Output**:

- `mappings/neuron_mapping.txt` - Hardware configuration file

---

### 3. `smnist_convert_test.py` - Convert Test Data & Test Models

**Purpose**: Convert MNIST test images to spike format for hardware simulation and test model accuracy.

**Key Features**:

- Converts MNIST to hardware-compatible spike format
- Tests pre-trained model accuracy
- Auto-detects model architecture from filename
- Configurable spike encoding parameters
- Supports test-only mode (no data conversion)

**Quick Example**:

```bash
# Test model and convert data
python smnist_convert_test.py --model_path ../outputs/spiking_mnist_h128_l1_t25.pth --samples 1000

# Test only (no conversion)
python smnist_convert_test.py --test_only --model_path ../outputs/model.pth
```

**Output**:

- `test_values.txt` - Spike data in hex format
- `test_labels.txt` - Corresponding labels
- Model accuracy report

---

## Script 1: Training (`smnist_train.py`)

### Command-Line Arguments

### Architecture Parameters

| Flag               | Type | Default | Description                            |
| ------------------ | ---- | ------- | -------------------------------------- |
| `--hidden-neurons` | int  | 128     | Number of neurons in each hidden layer |
| `--hidden-layers`  | int  | 1       | Number of hidden layers                |
| `--dt-steps`       | int  | 25      | Number of time steps for rate coding   |

### Training Parameters

| Flag                | Type  | Default | Description                       |
| ------------------- | ----- | ------- | --------------------------------- |
| `--epochs`          | int   | 10      | Number of training epochs         |
| `--batch-size`      | int   | 64      | Training batch size               |
| `--learning-rate`   | float | 5e-4    | Learning rate for Adam optimizer  |
| `--early-stopping`  | flag  | False   | Enable early stopping             |
| `--early-stop-loss` | float | 0.1     | Loss threshold for early stopping |

### System Parameters

| Flag           | Type | Default   | Description                               |
| -------------- | ---- | --------- | ----------------------------------------- |
| `--cpu`        | flag | False     | Force CPU usage (disable CUDA)            |
| `--output-dir` | str  | ./outputs | Directory to save model and mapping files |

### Help Options

| Flag         | Description                  |
| ------------ | ---------------------------- |
| `--examples` | Show usage examples and exit |
| `--help`     | Show help message and exit   |

## Usage Examples

### 1. Basic Training (Minimal Configuration)

Train with default settings on CPU:

```bash
python smnist_train.py --cpu
```

Output files:

- `outputs/spiking_mnist_h128_l1_t25.pth` - Model weights
- `outputs/neuron_mapping.txt` - Hardware configuration

---

### 2. Custom Architecture

Train with 256 neurons and 2 hidden layers:

```bash
python smnist_train.py --hidden-neurons 256 --hidden-layers 2
```

This creates a network: **784 → 256 → 256 → 10**

---

### 3. High-Performance Training

Larger network with more time steps:

```bash
python smnist_train.py \
    --hidden-neurons 512 \
    --hidden-layers 3 \
    --dt-steps 50 \
    --batch-size 128 \
    --epochs 15
```

Architecture: **784 → 512 → 512 → 512 → 10** (50 time steps)

---

### 4. Quick Test Run

Fast training for testing (1 epoch, small batch):

```bash
python smnist_train.py --epochs 1 --batch-size 32 --cpu
```

---

### 5. Early Stopping Training

Train with early stopping to prevent overtraining:

```bash
python smnist_train.py \
    --epochs 20 \
    --early-stopping \
    --early-stop-loss 0.15
```

Training stops if average loss drops below 0.15.

---

### 6. Custom Output Directory

Save results to a specific location:

```bash
python smnist_train.py --output-dir ../trained_models/experiment_01
```

---

### 7. Production Training (Recommended)

Best settings for final deployment:

```bash
python smnist_train.py \
    --hidden-neurons 256 \
    --hidden-layers 2 \
    --dt-steps 40 \
    --epochs 15 \
    --batch-size 128 \
    --early-stopping \
    --early-stop-loss 0.1 \
    --output-dir ../production_models
```

---

## Script 2: Hardware Mapping (`smnist_generate_mapping.py`)

### Purpose

Generates hardware neuron mappings from pre-trained PyTorch SNN models without retraining. This script bridges the gap between trained models and hardware deployment.

### Command-Line Arguments

| Flag               | Type  | Default          | Description                   |
| ------------------ | ----- | ---------------- | ----------------------------- |
| `--model-path`     | str   | Required         | Path to pre-trained .pth file |
| `--hidden-neurons` | int   | Auto-detect      | Override model hidden neurons |
| `--hidden-layers`  | int   | Auto-detect      | Override model hidden layers  |
| `--dt-steps`       | int   | Auto-detect      | Override model time steps     |
| `--threshold`      | float | 1.0              | Neuron firing threshold       |
| `--beta`           | str   | DECAY_MODE_LIF_2 | Decay mode string             |
| `--reset-mode`     | str   | RESET_MODE_ZERO  | Reset mode string             |
| `--cpu`            | flag  | False            | Force CPU usage               |
| `--output-dir`     | str   | ./mappings       | Output directory for mappings |
| `--examples`       | flag  | -                | Show usage examples           |

### Usage Examples

#### Basic Usage (Auto-detect from Filename)

```bash
python smnist_generate_mapping.py --model-path ./outputs/spiking_mnist_h128_l1_t25.pth
```

Auto-detects: 128 neurons, 1 layer, 25 time steps

#### Manual Override

```bash
python smnist_generate_mapping.py \
    --model-path ./my_model.pth \
    --hidden-neurons 256 \
    --hidden-layers 2 \
    --dt-steps 50
```

#### Custom Output Directory

```bash
python smnist_generate_mapping.py \
    --model-path ./model.pth \
    --output-dir ./hardware_configs/
```

#### Force CPU Usage

```bash
python smnist_generate_mapping.py --model-path ./model.pth --cpu
```

### Supported Filename Patterns

The script auto-detects parameters from these patterns:

- `spiking_mnist_h128_l1_t25.pth` ✓
- `my_model_h256_l2_t50.pth` ✓
- `h128_l1_t25.pth` ✓
- `custom_h512_layers3_t100.pth` ✓

Format: `*_h{neurons}_l{layers}_t{timesteps}.pth`

### Output

**File**: `mappings/neuron_mapping.txt`

**Contents**:

- Neuron layer definitions (neurons, threshold, decay mode, reset mode)
- Synaptic weight matrices (all trained weights)
- Hardware parameters (cluster assignments, routing info)

---

## Script 3: Test Conversion (`smnist_convert_test.py`)

### Purpose

Converts MNIST test images to spike format for neuromorphic hardware simulation and tests pre-trained model accuracy.

### Command-Line Arguments

#### Data Conversion Parameters

| Flag           | Type | Default | Description                       |
| -------------- | ---- | ------- | --------------------------------- |
| `--samples`    | int  | 320     | Number of test samples to convert |
| `--dt_steps`   | int  | 50      | Time steps for spike encoding     |
| `--batch_size` | int  | 64      | Batch size for data loading       |

#### Model Testing Parameters

| Flag               | Type | Default     | Description                     |
| ------------------ | ---- | ----------- | ------------------------------- |
| `--model_path`     | str  | None        | Path to saved model file        |
| `--test_only`      | flag | False       | Only test model (no conversion) |
| `--hidden_neurons` | int  | Auto-detect | Override model hidden neurons   |
| `--hidden_layers`  | int  | Auto-detect | Override model hidden layers    |
| `--model_dt_steps` | int  | Auto-detect | Override model time steps       |

#### System Parameters

| Flag         | Type | Default | Description         |
| ------------ | ---- | ------- | ------------------- |
| `--cpu`      | flag | False   | Force CPU usage     |
| `--examples` | flag | -       | Show usage examples |

### Usage Examples

#### Basic Conversion (Default Settings)

```bash
python smnist_convert_test.py
```

Converts 320 samples with 50 time steps

#### Custom Sample Count

```bash
python smnist_convert_test.py --samples 1000 --dt_steps 100
```

#### Test Model and Convert Data

```bash
python smnist_convert_test.py --model_path ./outputs/spiking_mnist_h128_l1_t25.pth
```

#### Test Only (No Conversion)

```bash
python smnist_convert_test.py --test_only --model_path ./model.pth
```

#### Advanced Configuration

```bash
python smnist_convert_test.py \
    --samples 500 \
    --dt_steps 75 \
    --batch_size 32 \
    --model_path ./model.pth \
    --hidden_neurons 256 \
    --hidden_layers 2
```

#### Force CPU

```bash
python smnist_convert_test.py --cpu --samples 500
```

### Output Files

**`test_values.txt`**: Spike data in hexadecimal format

- Format: 11-bit packet (6-bit cluster ID + 5-bit neuron ID)
- `FFF`: No spike marker
- One line per pixel per time step

**`test_labels.txt`**: Corresponding ground truth labels

- One label per sample
- Values: 0-9 (digit classes)

### Spike Encoding Format

Each spike is encoded as:

```
packet = (cluster_id << 5) | neuron_id
cluster_id = (pixel_index // 32) + 32
neuron_id = pixel_index % 32
```

Example:

- Pixel 0 → Cluster 32, Neuron 0 → `0x400`
- Pixel 31 → Cluster 32, Neuron 31 → `0x41F`
- Pixel 32 → Cluster 33, Neuron 0 → `0x420`

---

## Complete Workflow

### End-to-End Pipeline

This shows how to use all three scripts together for neuromorphic hardware deployment:

```bash
# Step 1: Train a spiking neural network
cd src
python smnist_train.py \
    --hidden-neurons 256 \
    --hidden-layers 2 \
    --dt-steps 50 \
    --epochs 15 \
    --output-dir ../outputs

# Output: outputs/spiking_mnist_h256_l2_t50.pth
#         outputs/neuron_mapping.txt

# Step 2: (Optional) Generate mapping from existing model
python smnist_generate_mapping.py \
    --model-path ../outputs/spiking_mnist_h256_l2_t50.pth \
    --output-dir ../mappings

# Output: mappings/neuron_mapping.txt

# Step 3: Test model accuracy
python smnist_convert_test.py \
    --test_only \
    --model_path ../outputs/spiking_mnist_h256_l2_t50.pth

# Output: Model accuracy report

# Step 4: Convert test data to spike format
python smnist_convert_test.py \
    --samples 1000 \
    --dt_steps 100 \
    --model_path ../outputs/spiking_mnist_h256_l2_t50.pth

# Output: test_values.txt, test_labels.txt

# Step 5: Deploy to hardware
# Copy neuron_mapping.txt to RTL synthesis directory
# Use test_values.txt for hardware simulation
```

### Workflow Diagram

```
┌─────────────────────────┐
│   MNIST Dataset         │
│   (Training Data)       │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────────────────────┐
│  1. smnist_train.py                     │
│     Train SNN Model                     │
│                                         │
│  Input:  MNIST images                   │
│  Output: - spiking_mnist_*.pth          │
│          - neuron_mapping.txt           │
└────────────┬────────────────────────────┘
             │
             ├──────────────────┬─────────────────┐
             │                  │                 │
             ▼                  ▼                 ▼
┌───────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│ 2a. Generate Map  │  │ 2b. Test Model   │  │ 2c. Convert Test │
│ (smnist_generate_ │  │ (smnist_convert_ │  │ (smnist_convert_ │
│  mapping.py)      │  │  test.py)        │  │  test.py)        │
│                   │  │                  │  │                  │
│ Optional step to  │  │ Test accuracy on │  │ Convert MNIST to │
│ regenerate mapping│  │ test dataset     │  │ spike format     │
│                   │  │                  │  │                  │
│ Output:           │  │ Output:          │  │ Output:          │
│ - mapping.txt     │  │ - Accuracy %     │  │ - test_values.txt│
│                   │  │                  │  │ - test_labels.txt│
└───────┬───────────┘  └────────┬─────────┘  └────────┬─────────┘
        │                       │                     │
        └───────────────────────┴─────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  3. Hardware Deploy   │
                    │     RTL Synthesis     │
                    │                       │
                    │  Use neuron_mapping   │
                    │  for configuration    │
                    │                       │
                    │  Use test_values for  │
                    │  simulation           │
                    └───────────────────────┘
```

### Quick Reference

| Task                | Script                       | Key Flags                      |
| ------------------- | ---------------------------- | ------------------------------ |
| Train new model     | `smnist_train.py`            | `--hidden-neurons`, `--epochs` |
| Generate mapping    | `smnist_generate_mapping.py` | `--model-path`, `--output-dir` |
| Test accuracy       | `smnist_convert_test.py`     | `--test_only`, `--model_path`  |
| Convert test data   | `smnist_convert_test.py`     | `--samples`, `--dt_steps`      |
| Both test & convert | `smnist_convert_test.py`     | `--model_path`, `--samples`    |

---

## Automated Workflow Script

### Overview

The `snn_workflow_automation.sh` script **automates the complete pipeline** for training and testing multiple SNN configurations. It:

1. **Trains** models with different architectures (neurons, layers, time steps)
2. **Generates** hardware neuron mappings for each trained model
3. **Tests** model accuracy on the test dataset
4. **Converts** test data to spike format with different inference time steps
5. **Generates** comprehensive performance analysis and summary reports

### Quick Start

```bash
# Run with default configurations (5 models: 16, 32, 64, 128, 256 neurons)
bash snn_workflow_automation.sh

# Custom training parameters
bash snn_workflow_automation.sh --epochs 20 --batch-size 128 --samples 1000

# Force CPU mode with full test dataset
bash snn_workflow_automation.sh --cpu --full-dataset

# Show all options
bash snn_workflow_automation.sh --help
```

### Configuration

All parameters are defined at the top of the script and can be customized:

**Network Architectures** (edit script to modify):

```bash
HIDDEN_LAYERS=(1 2)              # Test 1 and 2 hidden layers
HIDDEN_NEURONS=(64 128 256)      # Test 3 neuron counts
TRAINING_TIME_STEPS=(25 50)      # Test 2 training time steps
INFERENCE_TIME_STEPS=(25 50 100) # Test 3 inference time steps
```

**Training Hyperparameters** (edit script or use flags):

```bash
EPOCHS=10                        # Number of training epochs
BATCH_SIZE=64                    # Training batch size
LEARNING_RATE=5e-4               # Learning rate
BETA=0.9                         # LIF neuron decay rate
```

**Data Conversion** (edit script or use flags):

```bash
TEST_SAMPLES=960                 # Test samples to convert (30 per class)
ENCODING_DT_STEPS=50             # Spike encoding time steps
USE_FULL_DATASET=false           # Set to true for all 10000 test samples
```

**Hardware Encoding**:

```bash
CLUSTER_SIZE=32                  # Neurons per hardware cluster
BASE_CLUSTER_ID=32               # Starting cluster ID
NO_SPIKE_MARKER="FFF"            # Hex marker for no-spike
```

### Command-Line Options

| Option                 | Description                                 | Default   |
| ---------------------- | ------------------------------------------- | --------- |
| `--help`               | Show help message and configuration summary | -         |
| `--dry-run`            | Show configuration without executing        | -         |
| `--epochs N`           | Number of training epochs                   | `10`      |
| `--batch-size N`       | Training batch size                         | `64`      |
| `--learning-rate RATE` | Learning rate for optimizer                 | `5e-4`    |
| `--beta RATE`          | LIF neuron decay rate (0-1)                 | `0.9`     |
| `--samples N`          | Number of test samples to convert           | `960`     |
| `--encoding-steps N`   | Time steps for spike encoding               | `50`      |
| `--full-dataset`       | Test on full 10000 samples                  | `false`   |
| `--cpu`                | Force CPU execution (no GPU)                | `false`   |
| `--python CMD`         | Python command to use                       | `python3` |

### Output Structure

The script creates an organized directory structure:

```
experiments/
├── experiment_results.csv          # CSV with all results
├── experiment_summary.txt          # Human-readable summary
├── logs/                           # Execution logs
│   ├── train_h16_l1_t25.log       # Training logs
│   ├── mapping_h16_l1_t25.log     # Mapping generation logs
│   └── convert_h16_l1_t25_inf25.log
└── h{N}_l{L}_t{T}/                # Per-configuration directories
    ├── models/
    │   └── spiking_mnist_h{N}_l{L}_t{T}.pth
    ├── mappings/
    │   └── neuron_mapping.txt
    └── test_data/
        ├── test_values_t25.txt
        ├── test_values_t50.txt
        ├── test_labels_t25.txt
        └── test_labels_t50.txt
```

### Example Configurations

**Quick test with small models:**

```bash
# Edit script: HIDDEN_NEURONS=(16 32)
# Edit script: TRAINING_TIME_STEPS=(25)
# Edit script: INFERENCE_TIME_STEPS=(25)
bash snn_workflow_automation.sh --epochs 5
# Results: 2 models × 1 inference config = 2 experiments
```

**Comprehensive evaluation:**

```bash
# Edit script: HIDDEN_NEURONS=(64 128 256 512)
# Edit script: TRAINING_TIME_STEPS=(25 50)
# Edit script: INFERENCE_TIME_STEPS=(25 50 100)
bash snn_workflow_automation.sh --epochs 15 --full-dataset
# Results: 4 models × 2 training steps × 3 inference steps = 24 experiments
```

**CPU-only mode (no GPU):**

```bash
bash snn_workflow_automation.sh --cpu --epochs 10 --samples 320
```

### Results Analysis

After completion, review the generated reports:

**1. Summary Report** (`experiments/experiment_summary.txt`):

- Top performing models by training accuracy
- Top performing models by test accuracy
- Detailed results for each configuration
- Configuration parameters used

**2. CSV Results** (`experiments/experiment_results.csv`):

- Importable into Excel, Python, R for further analysis
- Columns: Config, Layers, Neurons, TrainSteps, TrainAccuracy, InfSteps, TestAccuracy, Paths

**Example CSV entry:**

```
h128_l1_t25,1,128,25,98.5,50,97.8,experiments/h128_l1_t25/models/...,experiments/h128_l1_t25/mappings/...,experiments/h128_l1_t25/test_data/...
```

### Workflow Phases

The script executes four phases for each configuration:

1. **Phase 1: Model Training**

   - Trains SNN with specified architecture
   - Saves model checkpoint (`.pth` file)
   - Logs training progress and final accuracy

2. **Phase 2: Hardware Mapping Generation**

   - Loads trained model
   - Generates `neuron_mapping.txt` for hardware deployment
   - Validates mapping format

3. **Phase 3: Model Evaluation**

   - Tests model accuracy on MNIST test set
   - Records training accuracy baseline

4. **Phase 4: Test Data Conversion**
   - Converts test images to spike format
   - Tests with different inference time steps
   - Generates `test_values.txt` and `test_labels.txt`
   - Records test accuracy for each inference configuration

### Execution Time

Approximate times (on NVIDIA GPU):

| Configuration          | Training | Total Per Config | 5 Configs |
| ---------------------- | -------- | ---------------- | --------- |
| 16 neurons, 10 epochs  | ~3 min   | ~5 min           | ~25 min   |
| 128 neurons, 10 epochs | ~5 min   | ~8 min           | ~40 min   |
| 256 neurons, 15 epochs | ~10 min  | ~15 min          | ~75 min   |

**CPU-only mode**: 3-5× slower

### Troubleshooting

**Prerequisites check fails:**

```bash
# Ensure you're in a virtual environment
cd models/smnist_lif_model
python3 -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate
pip install -r requirements.txt
pip install -e ../model_compiler
```

**Script not found error:**

```bash
# Make sure you're in the correct directory
cd models/smnist_lif_model
bash snn_workflow_automation.sh --help
```

**Permission denied:**

```bash
# Make script executable (Linux/macOS)
chmod +x snn_workflow_automation.sh
./snn_workflow_automation.sh
```

**Out of memory (GPU):**

```bash
# Use smaller batch size or force CPU mode
bash snn_workflow_automation.sh --batch-size 32
# OR
bash snn_workflow_automation.sh --cpu
```

---

## Training Output Files

After training, you'll find these files in the output directory:

### 1. Model Checkpoint (`*.pth`)

**Filename format**: `spiking_mnist_h{neurons}_l{layers}_t{steps}.pth`

**Example**: `spiking_mnist_h256_l2_t40.pth`

**Content**: PyTorch state dictionary with trained weights

**Usage**:

```python
import torch
model = SpikingMNISTClassifier(config)
model.load_state_dict(torch.load('spiking_mnist_h256_l2_t40.pth'))
```

---

### 2. Neuron Mapping (`neuron_mapping.txt`)

**Purpose**: Hardware deployment configuration for neuromorphic accelerator

**Format**: Space-separated values, one initialization command per line

**Content**:

- Neuron layer configurations (decay mode, threshold, reset mode)
- Synaptic weight matrices
- Cluster assignments
- Network topology

**Usage**: Feed this file into the RTL synthesis pipeline:

```bash
# Example: Use mapping for RTL synthesis
cd ../../../synopsys/primepower/tech_sky130/blackbox_fd_sc_hd/
# Copy neuron_mapping.txt to synthesis input directory
# Run synthesis with mapped configuration
```

---

## Architecture Details

### Network Structure

```
Input Layer (784 neurons, virtual)
    ↓ [Fully Connected, Weight Matrix W₁]
Hidden Layer 1 (128 neurons, LIF)
    ↓ [Fully Connected, Weight Matrix W₂]
    ⋮ (Additional hidden layers if specified)
Output Layer (10 neurons, LIF)
```

### Neuron Model: Leaky Integrate-and-Fire (LIF)

**Dynamics**:

```
V[t+1] = β·V[t] + I[t]
spike = 1 if V[t+1] ≥ threshold else 0
V[t+1] = 0 if spike else V[t+1]  (reset to zero)
```

**Parameters**:

- **Threshold**: 1.0 (fixed)
- **Beta (β)**: 0.9 (LIF_2 decay mode)
- **Reset mode**: Zero reset

### Rate Encoding

Input pixels (0-1 normalized) are converted to spike trains using **Poisson encoding**:

- Higher pixel intensity → Higher spike probability
- Each pixel generates a spike train over `dt_steps` time steps

### Training

- **Loss**: Cross-entropy on accumulated output spikes
- **Optimizer**: Adam with learning rate 5e-4
- **Backpropagation**: Surrogate gradient method (handled by SNNTorch)

---

## Hardware Deployment

### Deployment Pipeline

```
1. Train Model
   └─> smnist_train.py --hidden-neurons 256 --epochs 10

2. Generate Mapping
   └─> outputs/neuron_mapping.txt

3. RTL Synthesis
   └─> synopsys/primepower/tech_*/script.sh --rtla

4. Hardware Compilation
   └─> Verilog → FPGA/ASIC bitstream
```

### Integration with Neuromorphic Accelerator

The generated `neuron_mapping.txt` configures:

1. **Neuron Clusters**: Assigns neurons to hardware clusters
2. **Weight Memory**: Loads synaptic weights into on-chip SRAM
3. **LIF Parameters**: Configures threshold and decay circuits
4. **Spike Routing**: Sets up inter-layer spike forwarding

### Technology Nodes Supported

- **SKY130** (130nm, open-source PDK)
- **16nm FinFET**
- **45nm CMOS**

---

## Configuration Parameters

All configurable parameters are defined at the **top of the script** (lines 33-76 in `smnist_train.py`) for easy modification.

### Quick Access: Modify Defaults Without Command-Line

Edit these constants in the script to change default behavior:

```python
# Location: models/smnist_lif_model/src/smnist_train.py (lines 33-76)

# Model Architecture
DEFAULT_HIDDEN_NEURONS = 128        # Change to 256 or 512 for better accuracy
DEFAULT_NUM_HIDDEN_LAYERS = 1       # Change to 2 or 3 for deeper networks

# SNN Parameters
DEFAULT_DT_STEPS = 25               # Change to 50 or 100 for better temporal coding

# Training Hyperparameters
DEFAULT_EPOCHS = 10                 # Change to 15-30 for longer training
DEFAULT_BATCH_SIZE = 64             # Change to 128-256 for faster GPU training
DEFAULT_LEARNING_RATE = 5e-4        # Adjust between 1e-4 and 1e-3
DEFAULT_EARLY_STOPPING = False      # Change to True to enable
DEFAULT_EARLY_STOP_LOSS = 0.1       # Lower for stricter early stopping

# System
DEFAULT_OUTPUT_DIR = "./outputs"    # Change to custom directory
DEFAULT_USE_CPU = False             # Change to True to force CPU
PROGRESS_REPORT_INTERVAL = 100      # Change to 50 for more frequent updates
```

### Parameter Categories

#### 1. Model Architecture Parameters

| Parameter                   | Default | Description              | Tuning Tips                     |
| --------------------------- | ------- | ------------------------ | ------------------------------- |
| `DEFAULT_INPUT_NODES`       | 784     | MNIST pixels (28×28)     | **DO NOT CHANGE**               |
| `DEFAULT_HIDDEN_NEURONS`    | 128     | Neurons per hidden layer | Try 256, 512 for +2-3% accuracy |
| `DEFAULT_NUM_HIDDEN_LAYERS` | 1       | Number of hidden layers  | Try 2, 3 for deeper networks    |
| `DEFAULT_OUTPUT_NEURONS`    | 10      | Output classes (digits)  | **DO NOT CHANGE**               |

#### 2. SNN Neuron Parameters

| Parameter            | Default | Description             | Tuning Tips                    |
| -------------------- | ------- | ----------------------- | ------------------------------ |
| `DEFAULT_THRESHOLD`  | 1.0     | LIF spike threshold     | Try 0.5-2.0 (advanced)         |
| `DEFAULT_RESET_MODE` | ZERO    | Membrane reset mode     | Fixed to zero reset            |
| `DEFAULT_BETA`       | 0.9     | Membrane decay rate     | Fixed (LIF_2 mode)             |
| `DEFAULT_DT_STEPS`   | 25      | Time steps for encoding | Try 50, 100 for +1-2% accuracy |

#### 3. Training Hyperparameters

| Parameter                 | Default | Description           | Tuning Tips                     |
| ------------------------- | ------- | --------------------- | ------------------------------- |
| `DEFAULT_EPOCHS`          | 10      | Training epochs       | Try 15-30 with early stopping   |
| `DEFAULT_BATCH_SIZE`      | 64      | Batch size            | Try 128-256 for GPU speedup     |
| `DEFAULT_LEARNING_RATE`   | 5e-4    | Learning rate         | Try 1e-4 (slow) to 1e-3 (fast)  |
| `DEFAULT_EARLY_STOPPING`  | False   | Enable early stopping | Set True to prevent overfitting |
| `DEFAULT_EARLY_STOP_LOSS` | 0.1     | Early stop threshold  | Lower to 0.05-0.03 for stricter |

#### 4. Data Preprocessing Parameters

| Parameter          | Default  | Description                | Tuning Tips                |
| ------------------ | -------- | -------------------------- | -------------------------- |
| `MNIST_MEAN`       | 0.1307   | Dataset normalization mean | **DO NOT CHANGE**          |
| `MNIST_STD`        | 0.3081   | Dataset normalization std  | **DO NOT CHANGE**          |
| `DEFAULT_DATA_DIR` | "./data" | MNIST storage directory    | Change for custom location |

#### 5. System Parameters

| Parameter                  | Default     | Description                   | Tuning Tips                  |
| -------------------------- | ----------- | ----------------------------- | ---------------------------- |
| `DEFAULT_OUTPUT_DIR`       | "./outputs" | Model save directory          | Change for custom location   |
| `DEFAULT_USE_CPU`          | False       | Force CPU usage               | Set True if no GPU available |
| `PROGRESS_REPORT_INTERVAL` | 100         | Batches between progress logs | Lower to 50 for more updates |

### Parameter Usage Examples

#### Example 1: Quick Edit for Better Accuracy

Edit the script:

```python
DEFAULT_HIDDEN_NEURONS = 256
DEFAULT_NUM_HIDDEN_LAYERS = 2
DEFAULT_DT_STEPS = 50
DEFAULT_EPOCHS = 15
```

Then run without arguments:

```bash
python smnist_train.py
```

#### Example 2: Use Command-Line to Override

Keep defaults in script, override specific values:

```bash
python smnist_train.py --hidden-neurons 512 --hidden-layers 3 --epochs 20
```

#### Example 3: Force CPU Training

Edit the script:

```python
DEFAULT_USE_CPU = True
```

Or use command-line:

```bash
python smnist_train.py --cpu
```

### Command-Line Override Priority

Command-line arguments **always override** the defaults in the script:

```
Script Defaults → Overridden by → Command-Line Arguments
```

Example:

- Script has: `DEFAULT_HIDDEN_NEURONS = 128`
- Command: `python smnist_train.py --hidden-neurons 256`
- Result: Uses 256 (command-line wins)

### Recommended Configurations

#### Configuration 1: Fast Testing

```python
DEFAULT_HIDDEN_NEURONS = 64
DEFAULT_EPOCHS = 5
DEFAULT_BATCH_SIZE = 32
DEFAULT_DT_STEPS = 15
```

**Result**: ~2 min training, ~92% accuracy

#### Configuration 2: Balanced (Default)

```python
DEFAULT_HIDDEN_NEURONS = 128
DEFAULT_EPOCHS = 10
DEFAULT_BATCH_SIZE = 64
DEFAULT_DT_STEPS = 25
```

**Result**: ~5 min training, ~95% accuracy

#### Configuration 3: High Accuracy

```python
DEFAULT_HIDDEN_NEURONS = 256
DEFAULT_NUM_HIDDEN_LAYERS = 2
DEFAULT_EPOCHS = 20
DEFAULT_BATCH_SIZE = 128
DEFAULT_DT_STEPS = 50
DEFAULT_EARLY_STOPPING = True
DEFAULT_EARLY_STOP_LOSS = 0.05
```

**Result**: ~20 min training, ~97-98% accuracy

#### Configuration 4: Maximum Performance

```python
DEFAULT_HIDDEN_NEURONS = 512
DEFAULT_NUM_HIDDEN_LAYERS = 3
DEFAULT_EPOCHS = 30
DEFAULT_BATCH_SIZE = 128
DEFAULT_DT_STEPS = 100
DEFAULT_EARLY_STOPPING = True
DEFAULT_EARLY_STOP_LOSS = 0.03
```

**Result**: ~60 min training, ~98-99% accuracy

---

## Troubleshooting

### Issue: `externally-managed-environment` error

**Cause**: Modern Linux distributions (Ubuntu 24.04+) prevent system-wide pip installations (PEP 668).

**Solution**: Use a virtual environment (see [Installation](#installation)):

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

---

### Issue: `ModuleNotFoundError: No module named 'snntorch'`

**Solution**:

```bash
pip install snntorch
```

---

### Issue: `CUDA out of memory`

**Solutions**:

1. **Reduce batch size**:

   ```bash
   python smnist_train.py --batch-size 32
   ```

2. **Use CPU**:

   ```bash
   python smnist_train.py --cpu
   ```

3. **Reduce time steps**:

   ```bash
   python smnist_train.py --dt-steps 15
   ```

4. **Smaller architecture**:
   ```bash
   python smnist_train.py --hidden-neurons 64
   ```

---

### Issue: `neuron_mapper not found`

**Cause**: The script can't find the `model_compiler` module

**Solution**:
The script automatically resolves paths. Verify directory structure:

```bash
models/
  smnist_lif_model/
    src/
      smnist_train.py  ← You are here
  model_compiler/
    neuron_mapper/     ← Should be here
```

If structure is different, adjust the path in the script or run from the correct directory.

---

### Issue: Low accuracy (<80%)

**Solutions**:

1. **Train longer**:

   ```bash
   python smnist_train.py --epochs 20
   ```

2. **Increase time steps**:

   ```bash
   python smnist_train.py --dt-steps 50
   ```

3. **Larger network**:

   ```bash
   python smnist_train.py --hidden-neurons 256 --hidden-layers 2
   ```

4. **Check CUDA usage**:
   ```bash
   # GPU training is faster and may converge better
   python smnist_train.py  # without --cpu flag
   ```

---

### Issue: Training interrupted

**Resume training**:

```python
# Modify script to load checkpoint:
model.load_state_dict(torch.load('outputs/spiking_mnist_*.pth'))
# Then continue training
```

---

## Performance Tips

### Training Speed

| Configuration | Training Time (10 epochs) | GPU Memory | Accuracy |
| ------------- | ------------------------- | ---------- | -------- |
| Default (CPU) | ~45 min                   | N/A        | ~95%     |
| Default (GPU) | ~5 min                    | ~2GB       | ~95%     |
| Large (GPU)   | ~15 min                   | ~6GB       | ~97%     |

**Large config**: `--hidden-neurons 512 --hidden-layers 3 --dt-steps 50`

### Memory Optimization

The script uses **in-place spike accumulation** to reduce memory:

- Old method: Stores all time steps → ~24GB for 512 steps
- New method: Accumulates on-the-fly → ~50MB constant

### GPU Utilization

**Check GPU usage** (Linux/WSL):

```bash
nvidia-smi
```

**Maximize GPU utilization**:

```bash
python smnist_train.py \
    --batch-size 128 \
    --hidden-neurons 512 \
    --dt-steps 50
```

### Hyperparameter Tuning

| Goal                   | Recommended Settings                                                    |
| ---------------------- | ----------------------------------------------------------------------- |
| **Fast prototyping**   | `--epochs 5 --batch-size 32 --dt-steps 15`                              |
| **Best accuracy**      | `--hidden-neurons 512 --hidden-layers 3 --dt-steps 50 --epochs 20`      |
| **Memory constrained** | `--batch-size 16 --hidden-neurons 64 --cpu`                             |
| **Production**         | `--hidden-neurons 256 --hidden-layers 2 --dt-steps 40 --early-stopping` |

---

## Expected Results

### Typical Training Output

```
============================================================
TRAINING CONFIGURATION
============================================================
Model Architecture:
  Input nodes: 784
  Hidden neurons per layer: 128
  Number of hidden layers: 1
  Output neurons: 10

SNN Parameters:
  Threshold: 1.0
  Beta (decay): 0.9
  Time steps: 25

Training Parameters:
  Epochs: 10
  Batch size: 64
  Learning rate: 0.0005
  Early stopping: False

System:
  Device: cuda
  Output directory: outputs
  Model name: spiking_mnist_h128_l1_t25
============================================================

Loading MNIST dataset...
Loaded 60000 training samples and 10000 test samples
Creating spiking neural network...
Model created with 101,770 trainable parameters
Training started on cuda...
Epoch 1/10 [  0.0%] Batch 0/938, Loss: 2.3156
Epoch 1/10 [ 10.7%] Batch 100/938, Loss: 0.8234
...
Epoch 1/10 - Average Loss: 0.6543
Epoch 2/10 - Average Loss: 0.3214
...
Epoch 10/10 - Average Loss: 0.0987

Evaluating model...
Test Accuracy: 95.32% (9532/10000)

Generating neuron mapping...
Neuron mapping saved to outputs/neuron_mapping.txt

============================================================
TRAINING COMPLETED SUCCESSFULLY!
============================================================
Final accuracy: 95.32%
Model saved to: outputs/spiking_mnist_h128_l1_t25.pth
Neuron mapping saved to: outputs/neuron_mapping.txt
============================================================
```

### Accuracy Benchmarks

| Architecture    | Time Steps | Accuracy | Parameters |
| --------------- | ---------- | -------- | ---------- |
| 128×1 (default) | 25         | 94-96%   | ~100K      |
| 256×1           | 25         | 96-97%   | ~200K      |
| 256×2           | 40         | 97-98%   | ~265K      |
| 512×3           | 50         | 98-99%   | ~1.3M      |

---

## References

- **SNNTorch Documentation**: https://snntorch.readthedocs.io/
- **PyTorch**: https://pytorch.org/
- **MNIST Dataset**: http://yann.lecun.com/exdb/mnist/
- **LIF Neuron Model**: Gerstner & Kistler, "Spiking Neuron Models"

---

## License

Part of the Neuromorphic Accelerator Project.

---

## Contributing

For bug reports or feature requests related to the SNN training pipeline, please open an issue in the main repository.

---

## Support

If you encounter issues:

1. Check the [Troubleshooting](#troubleshooting) section
2. Verify installation: `python -c "import torch, snntorch"`
3. Run with verbose errors to get full traceback
4. Check GPU/CUDA compatibility: `nvidia-smi` (if using GPU)

---

**Last Updated**: October 2025  
**Version**: 1.0.0
