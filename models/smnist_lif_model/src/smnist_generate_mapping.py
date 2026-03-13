#!/usr/bin/env python3
"""
Generate Neuron Mapping from Pre-trained Spiking Neural Network

This script loads a pre-trained spiking neural network model (.pth file) and generates
the neuron mapping for neuromorphic hardware deployment without retraining.
"""

import torch
import torch.nn as nn
import snntorch as snn
import argparse
import sys
import re
from pathlib import Path
import traceback

# Robust path resolution for neuron_mapper module
_SCRIPT_DIR = Path(__file__).resolve().parent
_MODEL_COMPILER_PATH = _SCRIPT_DIR.parent.parent / "model_compiler"
if _MODEL_COMPILER_PATH.exists():
    sys.path.insert(0, str(_MODEL_COMPILER_PATH))
else:
    print(f"Warning: model_compiler not found at {_MODEL_COMPILER_PATH}")
    sys.path.append("../../model_compiler")  # Fallback to relative path

from neuron_mapper import Neuron_Mapper, Neuron_LIF


# =============================================================================
# DEFAULT CONFIGURATION PARAMETERS
# =============================================================================
# Modify these constants to change default behavior without using command-line args
#
# These parameters MUST match the training configuration used to create the model!
#
# =============================================================================

# --- Model Architecture Parameters ---
DEFAULT_INPUT_NODES = 28 * 28           # MNIST image size (784 pixels) - DO NOT CHANGE
DEFAULT_HIDDEN_NEURONS = 128            # Neurons per hidden layer (must match training)
DEFAULT_NUM_HIDDEN_LAYERS = 1           # Number of hidden layers (must match training)
DEFAULT_OUTPUT_NEURONS = 10             # Number of output classes (digits 0-9) - DO NOT CHANGE

# --- SNN Neuron Parameters ---
DEFAULT_THRESHOLD = 1.0                 # LIF neuron spike threshold (must match training)
DEFAULT_RESET_MODE = None               # Will be set to Neuron_LIF.RESET_MODE_ZERO
DEFAULT_BETA = None                     # Will be set to Neuron_LIF.DECAY_MODE_LIF_2 (decay rate ~0.9)
DEFAULT_DT_STEPS = 25                   # Number of time steps for rate encoding (must match training)

# --- System Parameters ---
DEFAULT_OUTPUT_DIR = "./mappings"       # Default output directory for mapping files
DEFAULT_USE_CPU = False                 # Force CPU usage (disable CUDA)

# =============================================================================


class SpikingMNISTClassifier(nn.Module):
    """Dynamic Spiking Neural Network for MNIST classification."""
    
    def __init__(self, config):
        super().__init__()
        
        self.config = config
        self.num_hidden_layers = config.num_hidden_layers
        
        # Build network layers
        self.layers = nn.ModuleList()
        self.lif_neurons = nn.ModuleList()
        
        # Input to first hidden layer
        self.layers.append(
            nn.Linear(config.input_nodes, config.hidden_neurons, bias=False)
        )
        self.lif_neurons.append(
            snn.Leaky(beta=config.beta, threshold=config.threshold)
        )
        
        # Hidden to hidden layers
        for _ in range(config.num_hidden_layers - 1):
            self.layers.append(
                nn.Linear(config.hidden_neurons, config.hidden_neurons, bias=False)
            )
            self.lif_neurons.append(
                snn.Leaky(beta=config.beta, threshold=config.threshold)
            )
        
        # Last hidden to output layer
        self.layers.append(
            nn.Linear(config.hidden_neurons, config.output_neurons, bias=False)
        )
        self.lif_neurons.append(
            snn.Leaky(beta=config.beta, threshold=config.threshold)
        )

    def forward(self, x):
        """Forward pass through the spiking network."""
        # This is not used for mapping generation, but kept for compatibility
        pass


class Config:
    """Configuration class for model parameters."""
    
    def __init__(self, args):
        # Model architecture (must match the trained model)
        self.input_nodes = DEFAULT_INPUT_NODES
        self.hidden_neurons = args.hidden_neurons
        self.num_hidden_layers = args.hidden_layers
        self.output_neurons = DEFAULT_OUTPUT_NEURONS
        
        # SNN parameters (must match training configuration)
        self.threshold = args.threshold
        self.reset_mode = getattr(Neuron_LIF, args.reset_mode)
        self.beta = getattr(Neuron_LIF, args.beta)
        self.dt_steps = args.dt_steps
        
        # Device configuration
        self.device = 'cuda' if torch.cuda.is_available() and not args.cpu else 'cpu'
        self.dtype = torch.float32
        
        # File naming (for consistency with training script)
        self.model_name = f"spiking_mnist_h{self.hidden_neurons}_l{self.num_hidden_layers}_t{self.dt_steps}"
        
        # Output directory
        self.output_dir = Path(args.output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
    
    def print_config(self):
        """Print current configuration."""
        print(f"\n{'='*60}")
        print(f"MAPPING GENERATION CONFIGURATION")
        print(f"{'='*60}")
        print(f"Model Architecture:")
        print(f"  Input nodes: {self.input_nodes}")
        print(f"  Hidden neurons per layer: {self.hidden_neurons}")
        print(f"  Number of hidden layers: {self.num_hidden_layers}")
        print(f"  Output neurons: {self.output_neurons}")
        print(f"\nSNN Parameters:")
        print(f"  Threshold: {self.threshold}")
        print(f"  Beta (decay): {self.beta}")
        print(f"  Reset mode: {self.reset_mode}")
        print(f"  Time steps: {self.dt_steps}")
        print(f"\nSystem:")
        print(f"  Device: {self.device}")
        print(f"  Output directory: {self.output_dir}")
        print(f"  Model name: {self.model_name}")
        print(f"{'='*60}\n")


class NeuronMapper:
    """Handle neuron mapping for hardware deployment."""
    
    def __init__(self, model, config):
        self.model = model
        self.config = config
    
    def create_neuron_layers(self):
        """Create neuron layers configuration."""
        neuron_layers = {
            "Input": {
                "decay_mode": self.config.beta,
                "threshold": self.config.threshold,
                "neurons": self.config.input_nodes,
                "reset_mode": self.config.reset_mode,
                "is_virtual": True
            }
        }
        
        # Add hidden layers
        for i in range(self.config.num_hidden_layers):
            layer_name = f"Layer{i+1}"
            neuron_layers[layer_name] = {
                "decay_mode": self.config.beta,
                "threshold": self.config.threshold,
                "neurons": self.config.hidden_neurons,
                "reset_mode": self.config.reset_mode
            }
        
        # Add output layer
        neuron_layers[f"Layer{self.config.num_hidden_layers+1}"] = {
            "decay_mode": self.config.beta,
            "threshold": self.config.threshold,
            "neurons": self.config.output_neurons,
            "reset_mode": self.config.reset_mode
        }
        
        return neuron_layers
    
    def create_neuron_weights(self):
        """Extract and organize neuron weights."""
        neuron_weights = {}
        
        # Input to first hidden layer
        neuron_weights["Input-Layer1"] = {
            "weights": self.model.layers[0].weight.detach().cpu().numpy().tolist()
        }
        
        # Hidden to hidden connections
        for i in range(self.config.num_hidden_layers - 1):
            connection_name = f"Layer{i+1}-Layer{i+2}"
            neuron_weights[connection_name] = {
                "weights": self.model.layers[i+1].weight.detach().cpu().numpy().tolist()
            }
        
        # Last hidden to output connection
        last_connection = f"Layer{self.config.num_hidden_layers}-Layer{self.config.num_hidden_layers+1}"
        neuron_weights[last_connection] = {
            "weights": self.model.layers[-1].weight.detach().cpu().numpy().tolist()
        }
        
        return neuron_weights
    
    def generate_mapping(self):
        """Generate and save neuron mapping."""
        print("Generating neuron mapping...")
        
        neuron_layers = self.create_neuron_layers()
        neuron_weights = self.create_neuron_weights()
        
        neuron_mapper = Neuron_Mapper(neuron_layers, neuron_weights)
        neuron_mapper.map()
        
        # Save mapping to file
        mapping_filename = self.config.output_dir / "neuron_mapping.txt"
        
        try:
            with open(mapping_filename, 'w') as f:
                for line in neuron_mapper.generate_init():
                    # Handle both list and string line formats
                    if isinstance(line, (list, tuple)):
                        f.write(" ".join(str(item) for item in line) + "\n")
                    else:
                        f.write(str(line) + "\n")
        except Exception as e:
            print(f"Warning: Error writing mapping file: {e}")
            # Fallback: try simpler approach
            with open(mapping_filename, 'w') as f:
                mapping_data = neuron_mapper.generate_init()
                if isinstance(mapping_data, str):
                    f.write(mapping_data)
                else:
                    for line in mapping_data:
                        f.write(str(line) + "\n")
        
        print(f"Neuron mapping saved to {mapping_filename}")
        return mapping_filename


def parse_model_filename(model_path):
    """
    Parse model filename to extract architecture parameters.
    
    Expected format: spiking_mnist_h{hidden_neurons}_l{hidden_layers}_t{dt_steps}.pth
    Example: spiking_mnist_h128_l1_t10.pth
    
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


def load_model(model_path, config):
    """Load the pre-trained model."""
    print(f"Loading model from {model_path}...")
    
    # Create model with the same architecture
    model = SpikingMNISTClassifier(config)
    
    # Load the state dict (weights_only=True for security)
    state_dict = torch.load(model_path, map_location=config.device, weights_only=True)
    model.load_state_dict(state_dict)
    
    # Set to evaluation mode
    model.eval()
    
    print("Model loaded successfully!")
    return model


def analyze_model(model, config):
    """Analyze the loaded model and print information."""
    print(f"\n{'='*60}")
    print(f"MODEL ANALYSIS")
    print(f"{'='*60}")
    
    total_params = sum(p.numel() for p in model.parameters())
    trainable_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
    
    print(f"Total parameters: {total_params:,}")
    print(f"Trainable parameters: {trainable_params:,}")
    print(f"Number of layers: {len(model.layers)}")
    
    # Print layer shapes
    for i, layer in enumerate(model.layers):
        weight_shape = layer.weight.shape
        print(f"Layer {i+1}: {weight_shape[1]} → {weight_shape[0]}")
    
    print(f"{'='*60}\n")


def print_usage_examples():
    """Print usage examples and help information."""
    print(f"\n{'='*60}")
    print(f"USAGE EXAMPLES")
    print(f"{'='*60}")
    print("Basic usage (auto-detect from filename):")
    print("  python smnist_generate_mapping.py --model-path ./outputs/spiking_mnist_h128_l1_t25.pth")
    print()
    print("Manual specification (override auto-detection):")
    print("  python smnist_generate_mapping.py --model-path ./model.pth --hidden-neurons 128 --hidden-layers 1")
    print()
    print("Custom architecture with different parameters:")
    print("  python smnist_generate_mapping.py --model-path ./my_model.pth \\")
    print("                                    --hidden-neurons 256 --hidden-layers 2 \\")
    print("                                    --threshold 1.5 --dt-steps 50")
    print()
    print("Custom output directory:")
    print("  python smnist_generate_mapping.py --model-path ./outputs/spiking_mnist_h128_l1_t25.pth \\")
    print("                                    --output-dir ./hardware_configs/")
    print()
    print("Force CPU usage:")
    print("  python smnist_generate_mapping.py --model-path ./model.pth --cpu")
    print()
    print("Supported filename patterns for auto-detection:")
    print("  - spiking_mnist_h{neurons}_l{layers}_t{steps}.pth")
    print("  - any_prefix_h{neurons}_l{layers}_t{steps}.pth")
    print("  - h{neurons}_l{layers}_t{steps}.pth")
    print("  Example: spiking_mnist_h128_l1_t25.pth → 128 neurons, 1 layer, 25 steps")
    print()
    print("Note: Manually specified parameters will override auto-detection!")
    print(f"{'='*60}\n")


def main():
    """Main mapping generation pipeline."""
    parser = argparse.ArgumentParser(
        description='Generate neuron mapping from pre-trained spiking neural network',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        epilog="For more examples, run with --examples flag"
    )
    
    # Required parameters
    parser.add_argument(
        '--model-path', type=str, required=False,
        help='Path to the pre-trained model (.pth file)'
    )
    
    # Architecture parameters (can be auto-detected from filename)
    arch_group = parser.add_argument_group('Architecture Parameters (auto-detected from filename if not specified)')
    arch_group.add_argument(
        '--hidden-neurons', type=int, default=None,
        help=f'Number of neurons in each hidden layer (default: auto-detect or {DEFAULT_HIDDEN_NEURONS})'
    )
    arch_group.add_argument(
        '--hidden-layers', type=int, default=None,
        help=f'Number of hidden layers (default: auto-detect or {DEFAULT_NUM_HIDDEN_LAYERS})'
    )
    arch_group.add_argument(
        '--dt-steps', type=int, default=None,
        help=f'Number of time steps for rate coding (default: auto-detect or {DEFAULT_DT_STEPS})'
    )
    
    # SNN parameters (must match training config)
    snn_group = parser.add_argument_group('SNN Parameters (must match training)')
    snn_group.add_argument(
        '--threshold', type=float, default=DEFAULT_THRESHOLD,
        help=f'Neuron firing threshold (default: {DEFAULT_THRESHOLD})'
    )
    snn_group.add_argument(
        '--beta', type=str, default='DECAY_MODE_LIF_2',
        help='Decay mode (default: DECAY_MODE_LIF_2)'
    )
    snn_group.add_argument(
        '--reset-mode', type=str, default='RESET_MODE_ZERO',
        help='Reset mode (default: RESET_MODE_ZERO)'
    )
    
    # System parameters
    sys_group = parser.add_argument_group('System Parameters')
    sys_group.add_argument(
        '--cpu', action='store_true', default=DEFAULT_USE_CPU,
        help='Force CPU usage even if CUDA is available'
    )
    sys_group.add_argument(
        '--output-dir', type=str, default=DEFAULT_OUTPUT_DIR,
        help=f'Directory to save mapping files (default: {DEFAULT_OUTPUT_DIR})'
    )
    
    # Help and examples
    help_group = parser.add_argument_group('Help')
    help_group.add_argument(
        '--examples', action='store_true',
        help='Show usage examples and exit'
    )
    
    args = parser.parse_args()
    
    # Show examples if requested
    if args.examples:
        print_usage_examples()
        return
    
    # Validate model path is provided
    if not args.model_path:
        print("Error: --model-path is required (unless using --examples)")
        parser.print_help()
        sys.exit(1)
    
    # Validate model path exists
    model_path = Path(args.model_path)
    if not model_path.exists():
        print(f"Error: Model file '{model_path}' not found!")
        sys.exit(1)
    
    # Try to auto-detect architecture parameters from filename
    parsed_params = parse_model_filename(model_path)
    
    if parsed_params:
        print(f"Auto-detected parameters from filename:")
        print(f"  Hidden neurons: {parsed_params['hidden_neurons']}")
        print(f"  Hidden layers: {parsed_params['hidden_layers']}")
        print(f"  Time steps: {parsed_params['dt_steps']}")
        
        # Use parsed values if not explicitly provided
        if args.hidden_neurons is None:
            args.hidden_neurons = parsed_params['hidden_neurons']
        if args.hidden_layers is None:
            args.hidden_layers = parsed_params['hidden_layers']
        if args.dt_steps is None:
            args.dt_steps = parsed_params['dt_steps']
    else:
        print("Warning: Could not auto-detect parameters from filename.")
        print("Using default values or provided arguments.")
        
        # Set defaults if not provided
        if args.hidden_neurons is None:
            args.hidden_neurons = DEFAULT_HIDDEN_NEURONS
        if args.hidden_layers is None:
            args.hidden_layers = DEFAULT_NUM_HIDDEN_LAYERS
        if args.dt_steps is None:
            args.dt_steps = DEFAULT_DT_STEPS
    
    # Initialize configuration
    config = Config(args)
    
    # Print configuration
    config.print_config()
    
    try:
        # Check CUDA availability
        if not torch.cuda.is_available() and not args.cpu:
            print("Warning: CUDA not available, using CPU")
        
        # Load model
        model = load_model(model_path, config)
        
        # Analyze model
        analyze_model(model, config)
        
        # Generate neuron mapping
        mapper = NeuronMapper(model, config)
        mapping_file = mapper.generate_mapping()
        
        # Final summary
        print(f"\n{'='*60}")
        print(f"MAPPING GENERATION COMPLETED SUCCESSFULLY!")
        print(f"{'='*60}")
        print(f"Input model: {model_path}")
        print(f"Neuron mapping saved to: {mapping_file}")
        print(f"Architecture: {config.input_nodes} → {config.hidden_neurons}×{config.num_hidden_layers} → {config.output_neurons}")
        print(f"Time steps: {config.dt_steps}")
        print(f"{'='*60}")
        
    except KeyboardInterrupt:
        print("\n\nMapping generation interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n{'='*60}")
        print(f"ERROR DURING MAPPING GENERATION")
        print(f"{'='*60}")
        print(f"Error: {e}")
        print(f"\nFull traceback:")
        traceback.print_exc()
        print(f"{'='*60}")
        sys.exit(1)


if __name__ == "__main__":
    main()