#!/usr/bin/env python3
"""
MNIST Spike Converter and Model Tester

This script converts MNIST test images to spike format for neuromorphic hardware simulation
and tests pre-trained spiking neural network models for accuracy.
"""

import torch
import torch.nn as nn
import torchvision
from torchvision import transforms
from torch.utils.data import DataLoader
import argparse
import os
import sys
import re
from pathlib import Path
import traceback

# Robust path resolution for neuron_mapper module (optional, for future use)
_SCRIPT_DIR = Path(__file__).resolve().parent
_MODEL_COMPILER_PATH = _SCRIPT_DIR.parent.parent / "model_compiler"
if _MODEL_COMPILER_PATH.exists():
    sys.path.insert(0, str(_MODEL_COMPILER_PATH))
else:
    sys.path.append("../../model_compiler")  # Fallback to relative path

try:
    import snntorch as snn
except ImportError:
    print("Warning: snntorch not available. Install with: pip install snntorch")
    snn = None


# =============================================================================
# DEFAULT CONFIGURATION PARAMETERS
# =============================================================================
# Modify these constants to change default behavior without using command-line args
#
# These parameters can be overridden via command-line arguments
#
# =============================================================================

# --- Model Architecture Parameters ---
DEFAULT_INPUT_NODES = 28 * 28           # MNIST image size (784 pixels) - DO NOT CHANGE
DEFAULT_HIDDEN_NEURONS = 128            # Neurons per hidden layer (must match trained model)
DEFAULT_NUM_HIDDEN_LAYERS = 1           # Number of hidden layers (must match trained model)
DEFAULT_OUTPUT_NEURONS = 10             # Number of output classes (digits 0-9) - DO NOT CHANGE

# --- SNN Neuron Parameters ---
DEFAULT_THRESHOLD = 1.0                 # LIF neuron spike threshold (must match training)
DEFAULT_BETA = 0.9                      # Membrane decay rate (must match training)
DEFAULT_DT_STEPS = 25                   # Number of time steps for rate encoding (must match training)

# --- Data Conversion Parameters ---
DEFAULT_NUM_SAMPLES = 320               # Number of test samples to convert
DEFAULT_ENCODING_DT_STEPS = 50          # Time steps for spike encoding (can differ from model)
DEFAULT_BATCH_SIZE = 64                 # Batch size for data loading

# --- Data Preprocessing Parameters ---
MNIST_MEAN = 0.1307                     # MNIST dataset mean (for normalization)
MNIST_STD = 0.3081                      # MNIST dataset std (for normalization)
DEFAULT_DATA_DIR = "./data"             # Directory to store MNIST dataset

# --- System Parameters ---
DEFAULT_USE_CPU = False                 # Force CPU usage (disable CUDA)

# --- Spike Encoding Parameters ---
CLUSTER_SIZE = 32                       # Neurons per cluster in hardware
BASE_CLUSTER_ID = 32                    # Starting cluster ID for input layer
NO_SPIKE_MARKER = "FFF"                 # Marker for no spike (hex)

# =============================================================================


class Config:
    """Configuration class for model parameters."""
    
    def __init__(self, hidden_neurons=None, hidden_layers=None, dt_steps=None, use_cpu=False):
        # Model architecture
        self.input_nodes = DEFAULT_INPUT_NODES
        self.hidden_neurons = hidden_neurons if hidden_neurons is not None else DEFAULT_HIDDEN_NEURONS
        self.num_hidden_layers = hidden_layers if hidden_layers is not None else DEFAULT_NUM_HIDDEN_LAYERS
        self.output_neurons = DEFAULT_OUTPUT_NEURONS
        
        # SNN parameters
        self.threshold = DEFAULT_THRESHOLD
        self.beta = DEFAULT_BETA
        self.dt_steps = dt_steps if dt_steps is not None else DEFAULT_DT_STEPS
        
        # Device configuration
        self.device = 'cuda' if torch.cuda.is_available() and not use_cpu else 'cpu'
        self.dtype = torch.float32
        
        # File naming (for consistency with training script)
        self.model_name = f"spiking_mnist_h{self.hidden_neurons}_l{self.num_hidden_layers}_t{self.dt_steps}"
    
    def print_config(self):
        """Print current configuration."""
        print(f"\n{'='*60}")
        print(f"MODEL CONFIGURATION")
        print(f"{'='*60}")
        print(f"Model Architecture:")
        print(f"  Input nodes: {self.input_nodes}")
        print(f"  Hidden neurons per layer: {self.hidden_neurons}")
        print(f"  Number of hidden layers: {self.num_hidden_layers}")
        print(f"  Output neurons: {self.output_neurons}")
        print(f"\nSNN Parameters:")
        print(f"  Threshold: {self.threshold}")
        print(f"  Beta (decay): {self.beta}")
        print(f"  Time steps: {self.dt_steps}")
        print(f"\nSystem:")
        print(f"  Device: {self.device}")
        print(f"  Model name: {self.model_name}")
        print(f"{'='*60}\n")


class SpikingMNISTClassifier(nn.Module):
    """Dynamic Spiking Neural Network for MNIST classification."""
    
    def __init__(self, config=None, hidden_neurons=128, hidden_layers=1, dt_steps=25):
        super().__init__()
        
        # Handle both config object and individual parameters
        if config is None:
            config = Config(hidden_neurons, hidden_layers, dt_steps)
        
        self.config = config
        self.num_hidden_layers = config.num_hidden_layers
        
        # Build network layers
        self.layers = nn.ModuleList()
        if snn is not None:
            self.lif_neurons = nn.ModuleList()
        
        # Input to first hidden layer
        self.layers.append(
            nn.Linear(config.input_nodes, config.hidden_neurons, bias=False)
        )
        if snn is not None:
            self.lif_neurons.append(
                snn.Leaky(beta=config.beta, threshold=config.threshold)
            )
        
        # Hidden to hidden layers
        for _ in range(config.num_hidden_layers - 1):
            self.layers.append(
                nn.Linear(config.hidden_neurons, config.hidden_neurons, bias=False)
            )
            if snn is not None:
                self.lif_neurons.append(
                    snn.Leaky(beta=config.beta, threshold=config.threshold)
                )
        
        # Last hidden to output layer
        self.layers.append(
            nn.Linear(config.hidden_neurons, config.output_neurons, bias=False)
        )
        if snn is not None:
            self.lif_neurons.append(
                snn.Leaky(beta=config.beta, threshold=config.threshold)
            )

    def forward(self, x):
        """Forward pass through the network."""
        # Reshape input from [batch, 1, 28, 28] to [batch, 784]
        x = x.view(x.size(0), -1)
        
        if snn is not None:
            # Full spiking network forward pass
            x_spike_seq = rate_encode_poisson(x, self.config.dt_steps).to(self.config.device)
            
            # Initialize membrane potentials
            mem_states = [lif.init_leaky() for lif in self.lif_neurons]
            spike_sum = None

            # Process each time step
            for t in range(self.config.dt_steps):
                x_t = x_spike_seq[t]
                current_input = x_t
                
                # Forward pass through all layers
                for layer, lif_neuron, i in zip(self.layers, self.lif_neurons, range(len(self.layers))):
                    current = layer(current_input)
                    spike_out, mem_states[i] = lif_neuron(current, mem_states[i])
                    current_input = spike_out
                
                # Accumulate spikes (memory efficient)
                if spike_sum is None:
                    spike_sum = current_input
                else:
                    spike_sum = spike_sum + current_input

            return spike_sum
        else:
            # Simplified forward pass when snntorch is not available
            current_input = x
            for layer in self.layers[:-1]:
                current_input = torch.relu(layer(current_input))
            output = self.layers[-1](current_input)
            return output


def rate_encode_poisson(inputs, num_steps):
    """
    Convert normalized inputs to Poisson spike trains.
    
    Args:
        inputs: [batch, features] — normalized input data
        num_steps: number of time steps for encoding
        
    Returns:
        [num_steps, batch, features] — binary spike trains
    """
    # Ensure inputs are in [0, 1] range
    inputs_norm = torch.clamp(inputs, 0, 1)
    
    # Generate spikes with probability equal to input value
    spike_prob = inputs_norm.unsqueeze(0).expand(num_steps, -1, -1)
    spikes = torch.rand_like(spike_prob) < spike_prob
    return spikes.float()


def test_classifier(model, test_loader, device):
    """
    Test the classifier accuracy on MNIST test data.
    
    Args:
        model: trained classifier model
        test_loader: DataLoader for test data
        device: computation device (cpu/cuda)
        
    Returns:
        correct: number of correct predictions
        total: total number of samples
    """
    model.eval()
    correct = 0
    total = 0
    
    with torch.no_grad():
        for data, labels in test_loader:
            data, labels = data.to(device), labels.to(device)
            data_flat = data.view(data.size(0), -1)  # Flatten to [batch, 784]
            
            outputs = model(data_flat)
            _, predicted = torch.max(outputs.data, 1)
            total += labels.size(0)
            correct += (predicted == labels).sum().item()
            
    return correct, total


def convert_mnist_to_spikes(num_samples=None, dt_steps=None, batch_size=None):
    """
    Convert MNIST test data to spike format and save to files.
    
    Args:
        num_samples: number of test samples to convert (default: DEFAULT_NUM_SAMPLES)
        dt_steps: number of time steps for rate encoding (default: DEFAULT_ENCODING_DT_STEPS)
        batch_size: batch size for data loading (default: DEFAULT_BATCH_SIZE)
    """
    # Use defaults if not provided
    num_samples = num_samples if num_samples is not None else DEFAULT_NUM_SAMPLES
    dt_steps = dt_steps if dt_steps is not None else DEFAULT_ENCODING_DT_STEPS
    batch_size = batch_size if batch_size is not None else DEFAULT_BATCH_SIZE
    
    print(f"Converting {num_samples} MNIST samples with {dt_steps} time steps...")
    
    # Data preprocessing
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((MNIST_MEAN,), (MNIST_STD,))
    ])
    
    # Load MNIST test dataset
    test_dataset = torchvision.datasets.MNIST(
        root=DEFAULT_DATA_DIR, 
        train=False, 
        download=True, 
        transform=transform
    )
    
    test_loader = DataLoader(test_dataset, batch_size=batch_size, shuffle=False)
    
    # Collect test data
    test_data_list = []
    test_labels_list = []
    samples_collected = 0
    
    for data, labels in test_loader:
        remaining_samples = num_samples - samples_collected
        if remaining_samples <= 0:
            break
            
        # Take only what we need
        samples_to_take = min(data.size(0), remaining_samples)
        test_data_list.append(data[:samples_to_take])
        test_labels_list.append(labels[:samples_to_take])
        samples_collected += samples_to_take
    
    # Combine all data
    test_data = torch.cat(test_data_list, dim=0)
    test_labels = torch.cat(test_labels_list, dim=0)
    
    print(f"Collected {test_data.shape[0]} samples, shape: {test_data.shape}")
    
    # Flatten images and encode to spikes
    test_data_flat = test_data.view(test_data.size(0), -1)  # [samples, 784]
    test_encoded = rate_encode_poisson(test_data_flat, dt_steps)  # [time_steps, samples, 784]
    
    print(f"Encoded spike data shape: {test_encoded.shape}")
    
    # Save spike data
    print("Saving spike data...")
    with open("test_values.txt", 'w') as f:
        for sample in range(test_encoded.shape[1]):  # For each sample
            if sample % 50 == 0:
                print(f"Processing sample {sample + 1}/{test_encoded.shape[1]}")
                
            for t in range(test_encoded.shape[0]):  # For each time step
                for pixel in range(test_encoded.shape[2]):  # For each pixel (784)
                    if test_encoded[t][sample][pixel] > 0:
                        # Generate packet: cluster_id (6 bits) + neuron_id (5 bits)
                        cluster_id = (pixel // CLUSTER_SIZE) + BASE_CLUSTER_ID
                        neuron_id = pixel % CLUSTER_SIZE
                        packet = (cluster_id << 5) | neuron_id
                        f.write(f"{packet:03X}\n")
                    else:
                        f.write(f"{NO_SPIKE_MARKER}\n")
    
    # Save labels
    print("Saving labels...")
    with open("test_labels.txt", 'w') as f:
        for label in test_labels.numpy():
            f.write(f"{label}\n")
    
    print(f"Data conversion complete!")
    print(f"- Spike data saved to: test_values.txt")
    print(f"- Labels saved to: test_labels.txt")
    print(f"- Total samples: {len(test_labels)}")
    print(f"- Time steps per sample: {dt_steps}")
    print(f"- Input features per time step: 784 (28x28 pixels)")
    
    return test_loader


def parse_model_filename(model_path):
    """
    Parse model filename to extract architecture parameters.
    
    Expected format: spiking_mnist_h{hidden_neurons}_l{hidden_layers}_t{dt_steps}.pth
    Example: spiking_mnist_h128_l1_t25.pth
    
    Returns:
        dict: Dictionary containing parsed parameters or None if parsing fails
    """
    filename = Path(model_path).name
    
    # Pattern to match: spiking_mnist_h{num}_l{num}_t{num}.pth
    pattern = r'spiking_mnist_h(\d+)_l(\d+)_t(\d+)\.pth'
    match = re.search(pattern, filename)
    
    if match:
        return {
            'hidden_neurons': int(match.group(1)),
            'hidden_layers': int(match.group(2)),
            'dt_steps': int(match.group(3))
        }
    
    # Try alternative patterns
    patterns = [
        r'h(\d+)_l(\d+)_t(\d+)',  # More flexible pattern
        r'.*_h(\d+)_l(\d+)_t(\d+)',  # Any prefix
        r'h(\d+)_layers(\d+)_t(\d+)',  # Alternative naming
        r'hidden(\d+)_layers(\d+)_time(\d+)',  # Full words
    ]
    
    for pattern in patterns:
        match = re.search(pattern, filename)
        if match:
            return {
                'hidden_neurons': int(match.group(1)),
                'hidden_layers': int(match.group(2)),
                'dt_steps': int(match.group(3))
            }
    
    return None


def load_and_test_model(model_path, test_loader, device, args=None):
    """
    Load a trained model and test its accuracy.
    
    Args:
        model_path: path to the saved model file
        test_loader: DataLoader for test data
        device: computation device (cpu/cuda)
        args: command line arguments (optional overrides)
    """
    model_path_obj = Path(model_path)
    if not model_path_obj.exists():
        print(f"Error: Model file '{model_path}' not found!")
        return
    
    print(f"Loading model from: {model_path}")
    
    # Try to auto-detect architecture parameters from filename
    parsed_params = parse_model_filename(model_path)
    
    if parsed_params:
        print(f"Auto-detected parameters from filename:")
        print(f"  Hidden neurons: {parsed_params['hidden_neurons']}")
        print(f"  Hidden layers: {parsed_params['hidden_layers']}")
        print(f"  Time steps: {parsed_params['dt_steps']}")
        
        hidden_neurons = parsed_params['hidden_neurons']
        hidden_layers = parsed_params['hidden_layers']
        dt_steps = parsed_params['dt_steps']
    else:
        print("Warning: Could not auto-detect parameters from filename.")
        print("Using default values or provided arguments.")
        hidden_neurons = DEFAULT_HIDDEN_NEURONS
        hidden_layers = DEFAULT_NUM_HIDDEN_LAYERS
        dt_steps = DEFAULT_DT_STEPS
    
    # Override with command line arguments if provided
    if args:
        if args.hidden_neurons is not None:
            hidden_neurons = args.hidden_neurons
            print(f"Overriding hidden neurons: {hidden_neurons}")
        if args.hidden_layers is not None:
            hidden_layers = args.hidden_layers
            print(f"Overriding hidden layers: {hidden_layers}")
        if args.model_dt_steps is not None:
            dt_steps = args.model_dt_steps
            print(f"Overriding model time steps: {dt_steps}")
    
    # Recreate the model architecture with correct parameters
    use_cpu = (device == 'cpu')
    config = Config(hidden_neurons, hidden_layers, dt_steps, use_cpu)
    
    # Print configuration
    config.print_config()
    
    classifier = SpikingMNISTClassifier(config)
    
    try:
        # Load the state dict from file (weights_only=True for security)
        state_dict = torch.load(model_path, map_location=device, weights_only=True)
        classifier.load_state_dict(state_dict)
        
        # Move model to device
        classifier.to(device)
        
        # Set model to evaluation mode
        classifier.eval()
        
        print("Model loaded successfully!")
        
        # Count parameters
        total_params = sum(p.numel() for p in classifier.parameters())
        trainable_params = sum(p.numel() for p in classifier.parameters() if p.requires_grad)
        print(f"Total parameters: {total_params:,}")
        print(f"Trainable parameters: {trainable_params:,}")
        
        # Test the model
        print("\nTesting model accuracy...")
        correct, total = test_classifier(classifier, test_loader, device)
        accuracy = 100 * correct / total
        
        print(f"\n{'='*60}")
        print(f"MODEL TEST RESULTS")
        print(f"{'='*60}")
        print(f"Correct predictions: {correct}/{total}")
        print(f"Test Accuracy: {accuracy:.2f}%")
        print(f"{'='*60}\n")
        
        return accuracy
        
    except KeyboardInterrupt:
        print("\n\nModel testing interrupted by user")
        return None
    except Exception as e:
        print(f"\n{'='*60}")
        print(f"ERROR LOADING MODEL")
        print(f"{'='*60}")
        print(f"Error: {e}")
        print(f"\nFull traceback:")
        traceback.print_exc()
        print(f"\nMake sure the model architecture matches the saved model.")
        print(f"Expected architecture: {hidden_neurons} hidden neurons, {hidden_layers} hidden layers")
        print(f"{'='*60}")
        return None


def print_usage_examples():
    """Print usage examples and available options."""
    print(f"\n{'='*80}")
    print(f"MNIST SPIKE CONVERTER - USAGE EXAMPLES")
    print(f"{'='*80}")
    
    print(f"\nBASIC USAGE:")
    print(f"  python smnist_convert_test.py                    # Convert {DEFAULT_NUM_SAMPLES} samples with defaults")
    print(f"  python smnist_convert_test.py --samples 1000     # Convert 1000 samples")
    print(f"  python smnist_convert_test.py --dt_steps 100     # Use 100 time steps for encoding")
    
    print(f"\nMODEL TESTING:")
    print(f"  python smnist_convert_test.py --model_path ./outputs/spiking_mnist_h128_l1_t25.pth")
    print(f"  python smnist_convert_test.py --test_only --model_path model.pth  # Only test model")
    
    print(f"\nADVANCED OPTIONS:")
    print(f"  python smnist_convert_test.py --samples 500 --dt_steps 75 --batch_size 32")
    print(f"  python smnist_convert_test.py --model_path model.pth --hidden_neurons 256 --hidden_layers 2")
    
    print(f"\nEXPECTED MODEL FILENAME FORMAT:")
    print(f"  spiking_mnist_h{{neurons}}_l{{layers}}_t{{timesteps}}.pth")
    print(f"  Example: spiking_mnist_h128_l1_t25.pth")
    
    print(f"\nOUTPUT FILES:")
    print(f"  - test_values.txt: Spike data in hex format")
    print(f"  - test_labels.txt: Corresponding labels")
    
    print(f"\nALL AVAILABLE OPTIONS:")
    print(f"  --samples N         Number of test samples to convert (default: {DEFAULT_NUM_SAMPLES})")
    print(f"  --dt_steps N        Time steps for rate encoding (default: {DEFAULT_ENCODING_DT_STEPS})")
    print(f"  --batch_size N      Batch size for data loading (default: {DEFAULT_BATCH_SIZE})")
    print(f"  --model_path PATH   Path to saved model file")
    print(f"  --test_only         Only test model, don't convert data")
    print(f"  --hidden_neurons N  Override model hidden neurons (default: auto-detect or {DEFAULT_HIDDEN_NEURONS})")
    print(f"  --hidden_layers N   Override model hidden layers (default: auto-detect or {DEFAULT_NUM_HIDDEN_LAYERS})")
    print(f"  --model_dt_steps N  Override model time steps (default: auto-detect or {DEFAULT_DT_STEPS})")
    print(f"  --cpu               Force CPU usage even if CUDA is available")
    print(f"  --examples          Show usage examples and exit")
    print(f"  --help              Show detailed help message")
    print(f"{'='*80}")


def main():
    """Main pipeline for MNIST spike conversion and model testing."""
    parser = argparse.ArgumentParser(
        description='Convert MNIST to Spike Format and Test Spiking Neural Network Models',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Examples:
  %(prog)s                                          # Convert {DEFAULT_NUM_SAMPLES} samples with defaults
  %(prog)s --samples 1000 --dt_steps 100            # Convert 1000 samples, 100 time steps
  %(prog)s --model_path outputs/spiking_mnist_h128_l1_t25.pth  # Test model and convert data
  %(prog)s --test_only --model_path model.pth       # Only test model accuracy

For more examples, use --examples flag
        """
    )
    
    # Data conversion parameters
    data_group = parser.add_argument_group('Data Conversion Parameters')
    data_group.add_argument('--samples', type=int, default=DEFAULT_NUM_SAMPLES, 
                        help=f'Number of test samples to convert (default: {DEFAULT_NUM_SAMPLES})')
    data_group.add_argument('--dt_steps', type=int, default=DEFAULT_ENCODING_DT_STEPS, 
                        help=f'Number of time steps for rate encoding (default: {DEFAULT_ENCODING_DT_STEPS})')
    data_group.add_argument('--batch_size', type=int, default=DEFAULT_BATCH_SIZE,
                        help=f'Batch size for data loading (default: {DEFAULT_BATCH_SIZE})')
    
    # Model testing parameters
    model_group = parser.add_argument_group('Model Testing Parameters')
    model_group.add_argument('--model_path', type=str, default=None,
                        help='Path to saved model file (e.g., spiking_mnist_h128_l1_t25.pth)')
    model_group.add_argument('--test_only', action='store_true',
                        help='Only test model accuracy without converting data')
    model_group.add_argument('--hidden_neurons', type=int, default=None,
                        help=f'Override hidden neurons (default: auto-detect or {DEFAULT_HIDDEN_NEURONS})')
    model_group.add_argument('--hidden_layers', type=int, default=None,
                        help=f'Override hidden layers (default: auto-detect or {DEFAULT_NUM_HIDDEN_LAYERS})')
    model_group.add_argument('--model_dt_steps', type=int, default=None,
                        help=f'Override model time steps (default: auto-detect or {DEFAULT_DT_STEPS})')
    
    # System parameters
    sys_group = parser.add_argument_group('System Parameters')
    sys_group.add_argument('--cpu', action='store_true', default=DEFAULT_USE_CPU,
                        help='Force CPU usage even if CUDA is available')
    
    # Help and examples
    help_group = parser.add_argument_group('Help')
    help_group.add_argument('--examples', action='store_true',
                        help='Show usage examples and exit')
    
    # Parse arguments
    args = parser.parse_args()
    
    # Show examples if requested
    if args.examples:
        print_usage_examples()
        return
    
    # If no arguments provided, show brief info
    if len(sys.argv) == 1:
        print(f"No arguments provided. Running with default settings...")
        print(f"(Converting {DEFAULT_NUM_SAMPLES} samples with {DEFAULT_ENCODING_DT_STEPS} time steps)")
        print(f"\nFor more options, use --help or --examples")
        print(f"Proceeding with default conversion...")
        print("-" * 60)
    
    # Check for conflicting arguments
    if args.test_only and not args.model_path:
        print("Error: --test_only requires --model_path to be specified")
        print("Use: python smnist_convert_test.py --test_only --model_path your_model.pth")
        sys.exit(1)
    
    # Validate arguments
    if args.samples <= 0:
        print("Error: --samples must be positive")
        sys.exit(1)
    
    if args.dt_steps <= 0:
        print("Error: --dt_steps must be positive")
        sys.exit(1)
    
    if args.batch_size <= 0:
        print("Error: --batch_size must be positive")
        sys.exit(1)
    
    # Set device
    device = torch.device('cuda' if torch.cuda.is_available() and not args.cpu else 'cpu')
    
    # Check CUDA availability
    if not torch.cuda.is_available() and not args.cpu:
        print("Warning: CUDA not available, using CPU")
    
    print(f"Using device: {device}")
    
    # Show current configuration
    print(f"\n{'='*60}")
    print(f"CURRENT CONFIGURATION")
    print(f"{'='*60}")
    print(f"Data Conversion:")
    print(f"  Samples to convert: {args.samples}")
    print(f"  Time steps: {args.dt_steps}")
    print(f"  Batch size: {args.batch_size}")
    if args.model_path:
        print(f"\nModel Testing:")
        print(f"  Model path: {args.model_path}")
    if args.test_only:
        print(f"  Mode: Test only (no data conversion)")
    print(f"\nSystem:")
    print(f"  Device: {device}")
    print(f"{'='*60}\n")
    
    try:
        # Load MNIST test data for model testing
        if args.model_path or args.test_only:
            print("Loading MNIST test dataset...")
            transform = transforms.Compose([
                transforms.ToTensor(),
                transforms.Normalize((MNIST_MEAN,), (MNIST_STD,))
            ])
            
            test_dataset = torchvision.datasets.MNIST(
                root=DEFAULT_DATA_DIR, 
                train=False, 
                download=True, 
                transform=transform
            )
            
            test_loader = DataLoader(test_dataset, batch_size=args.batch_size, shuffle=False)
            print("Test dataset loaded successfully!\n")
        
        # Test model if model path is provided
        if args.model_path:
            print("Testing model...")
            accuracy = load_and_test_model(args.model_path, test_loader, device, args)
        
        # Convert MNIST data unless test_only is specified
        if not args.test_only:
            print("Converting MNIST data to spike format...")
            test_loader = convert_mnist_to_spikes(
                num_samples=args.samples,
                dt_steps=args.dt_steps,
                batch_size=args.batch_size
            )
        
        # Final summary
        print(f"\n{'='*60}")
        print(f"SCRIPT EXECUTION COMPLETED SUCCESSFULLY!")
        print(f"{'='*60}")
        if not args.test_only:
            print(f"Output files:")
            print(f"  - test_values.txt (spike data)")
            print(f"  - test_labels.txt (labels)")
        if args.model_path:
            print(f"Model testing completed")
        print(f"{'='*60}")
        
    except KeyboardInterrupt:
        print("\n\nScript interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n{'='*60}")
        print(f"ERROR DURING EXECUTION")
        print(f"{'='*60}")
        print(f"Error: {e}")
        print(f"\nFull traceback:")
        traceback.print_exc()
        print(f"{'='*60}")
        sys.exit(1)


if __name__ == "__main__":
    main()