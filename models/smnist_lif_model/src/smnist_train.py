#!/usr/bin/env python3
"""
Spiking Neural Network MNIST Classifier

This script trains a spiking neural network on the MNIST dataset with configurable architecture.
The trained model can be deployed on neuromorphic hardware using the generated neuron mapping.
"""

import torch
import torch.nn as nn
import snntorch as snn
import torchvision
from torchvision import transforms
from torch.utils.data import DataLoader
import argparse
import sys
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
# QUICK TUNING GUIDE:
# - For higher accuracy: Increase HIDDEN_NEURONS (256, 512) and NUM_HIDDEN_LAYERS (2, 3)
# - For better temporal coding: Increase DT_STEPS (50, 100)
# - For faster training: Increase BATCH_SIZE (128, 256) if GPU memory allows
# - For careful tuning: Adjust LEARNING_RATE (1e-4 to 1e-3)
# - For preventing overfitting: Enable EARLY_STOPPING with appropriate threshold
#
# =============================================================================

# --- Model Architecture Parameters ---
DEFAULT_INPUT_NODES = 28 * 28           # MNIST image size (784 pixels) - DO NOT CHANGE
DEFAULT_HIDDEN_NEURONS = 128            # Neurons per hidden layer (try: 256, 512 for better accuracy)
DEFAULT_NUM_HIDDEN_LAYERS = 1           # Number of hidden layers (try: 2, 3 for deeper networks)
DEFAULT_OUTPUT_NEURONS = 10             # Number of output classes (digits 0-9) - DO NOT CHANGE

# --- SNN Neuron Parameters ---
DEFAULT_THRESHOLD = 1.0                 # LIF neuron spike threshold (try: 0.5-2.0)
DEFAULT_RESET_MODE = None               # Will be set to Neuron_LIF.RESET_MODE_ZERO
DEFAULT_BETA = None                     # Will be set to Neuron_LIF.DECAY_MODE_LIF_2 (decay rate ~0.9)
DEFAULT_DT_STEPS = 25                   # Number of time steps for rate encoding (try: 50, 100 for better accuracy)

# --- Training Hyperparameters ---
DEFAULT_EPOCHS = 10                     # Number of training epochs
DEFAULT_BATCH_SIZE = 64                 # Training batch size
DEFAULT_LEARNING_RATE = 5e-4            # Adam optimizer learning rate
DEFAULT_EARLY_STOPPING = False          # Enable early stopping
DEFAULT_EARLY_STOP_LOSS = 0.1           # Loss threshold for early stopping

# --- Data Preprocessing Parameters ---
MNIST_MEAN = 0.1307                     # MNIST dataset mean (for normalization)
MNIST_STD = 0.3081                      # MNIST dataset std (for normalization)
DEFAULT_DATA_DIR = "./data"             # Directory to store MNIST dataset

# --- System Parameters ---
DEFAULT_OUTPUT_DIR = "./outputs"        # Default output directory for models
DEFAULT_USE_CPU = False                 # Force CPU usage (disable CUDA)

# --- Progress Reporting ---
PROGRESS_REPORT_INTERVAL = 100          # Print progress every N batches

# =============================================================================


class Config:
    """Configuration class for training parameters."""
    
    def __init__(self, args):
        # Model architecture
        self.input_nodes = DEFAULT_INPUT_NODES
        self.hidden_neurons = args.hidden_neurons
        self.num_hidden_layers = args.hidden_layers
        self.output_neurons = DEFAULT_OUTPUT_NEURONS
        
        # SNN parameters
        self.threshold = DEFAULT_THRESHOLD
        self.reset_mode = DEFAULT_RESET_MODE if DEFAULT_RESET_MODE else Neuron_LIF.RESET_MODE_ZERO
        self.beta = DEFAULT_BETA if DEFAULT_BETA else Neuron_LIF.DECAY_MODE_LIF_2
        self.dt_steps = args.dt_steps
        
        # Training parameters
        self.epochs = args.epochs
        self.batch_size = args.batch_size
        self.learning_rate = args.learning_rate
        self.early_stopping = args.early_stopping
        self.early_stop_loss = args.early_stop_loss
        
        # Device configuration
        self.device = 'cuda' if torch.cuda.is_available() and not args.cpu else 'cpu'
        self.dtype = torch.float32
        
        # File naming
        self.model_name = f"spiking_mnist_h{self.hidden_neurons}_l{self.num_hidden_layers}_t{self.dt_steps}"
        
        # Output directory
        self.output_dir = Path(args.output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
    
    def print_config(self):
        """Print current configuration."""
        print(f"\n{'='*60}")
        print(f"TRAINING CONFIGURATION")
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
        print(f"\nTraining Parameters:")
        print(f"  Epochs: {self.epochs}")
        print(f"  Batch size: {self.batch_size}")
        print(f"  Learning rate: {self.learning_rate}")
        print(f"  Early stopping: {self.early_stopping}")
        if self.early_stopping:
            print(f"  Early stop loss threshold: {self.early_stop_loss}")
        print(f"\nSystem:")
        print(f"  Device: {self.device}")
        print(f"  Output directory: {self.output_dir}")
        print(f"  Model name: {self.model_name}")
        print(f"{'='*60}\n")


def rate_encode_poisson(inputs, num_steps):
    """
    Convert normalized inputs to Poisson spike trains.
    
    Args:
        inputs: [batch, features] — normalized input data
        num_steps: number of time steps for encoding
        
    Returns:
        [num_steps, batch, features] — binary spike trains
    """
    inputs_norm = torch.clamp(inputs, 0, 1)
    spike_prob = inputs_norm.unsqueeze(0).expand(num_steps, -1, -1)
    spikes = torch.rand_like(spike_prob) < spike_prob
    return spikes.float()


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
        # Reshape input from [batch, 1, 28, 28] to [batch, 784]
        x = x.view(x.size(0), -1)
        
        # Rate encode the input
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


class MNISTDataLoader:
    """MNIST data loading and preprocessing."""
    
    @staticmethod
    def get_mnist_loaders(batch_size, data_dir=DEFAULT_DATA_DIR):
        """Create MNIST train and test data loaders."""
        transform = transforms.Compose([
            transforms.ToTensor(),
            transforms.Normalize((MNIST_MEAN,), (MNIST_STD,))
        ])
        
        train_dataset = torchvision.datasets.MNIST(
            root=data_dir, train=True, download=True, transform=transform
        )
        
        test_dataset = torchvision.datasets.MNIST(
            root=data_dir, train=False, download=True, transform=transform
        )
        
        train_loader = torch.utils.data.DataLoader(
            train_dataset, batch_size=batch_size, shuffle=True
        )
        test_loader = torch.utils.data.DataLoader(
            test_dataset, batch_size=batch_size, shuffle=False
        )
        
        return train_loader, test_loader


class Trainer:
    """Training and evaluation utilities."""
    
    def __init__(self, model, config):
        self.model = model
        self.config = config
        self.loss_function = nn.CrossEntropyLoss()
        self.optimizer = torch.optim.Adam(model.parameters(), lr=config.learning_rate)
        
    def train(self, train_loader):
        """Train the spiking neural network."""
        print(f"Training started on {self.config.device}...")
        
        loss_history = []
        
        for epoch in range(self.config.epochs):
            self.model.train()
            total_loss = 0
            num_batches = 0
            
            for batch_idx, (data, targets) in enumerate(train_loader):
                data, targets = data.to(self.config.device), targets.to(self.config.device)
                
                # Training step
                self.optimizer.zero_grad()
                outputs = self.model(data)
                loss = self.loss_function(outputs, targets)
                loss.backward()
                self.optimizer.step()
                
                total_loss += loss.item()
                num_batches += 1
                
                # Progress reporting
                if batch_idx % PROGRESS_REPORT_INTERVAL == 0:
                    progress = 100.0 * batch_idx / len(train_loader)
                    print(f'Epoch {epoch+1}/{self.config.epochs} '
                          f'[{progress:5.1f}%] '
                          f'Batch {batch_idx}/{len(train_loader)}, '
                          f'Loss: {loss.item():.4f}')
            
            # Epoch summary
            avg_loss = total_loss / num_batches
            loss_history.append(avg_loss)
            print(f"Epoch {epoch + 1}/{self.config.epochs} - Average Loss: {avg_loss:.4f}")
            
            # Early stopping
            if self.config.early_stopping and avg_loss < self.config.early_stop_loss:
                print(f"Early stopping at epoch {epoch + 1} (loss: {avg_loss:.4f})")
                break
        
        return loss_history
    
    def evaluate(self, test_loader):
        """Evaluate the model on test data."""
        print("Evaluating model...")
        self.model.eval()
        
        correct = 0
        total = 0
        
        with torch.no_grad():
            for data, targets in test_loader:
                data, targets = data.to(self.config.device), targets.to(self.config.device)
                outputs = self.model(data)
                _, predicted = torch.max(outputs, 1)
                
                total += targets.size(0)
                correct += (predicted == targets).sum().item()
        
        accuracy = 100 * correct / total
        print(f"Test Accuracy: {accuracy:.2f}% ({correct}/{total})")
        return accuracy


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


def print_usage_examples():
    """Print usage examples and help information."""
    print(f"\n{'='*60}")
    print(f"USAGE EXAMPLES")
    print(f"{'='*60}")
    print("Basic usage (minimal configuration):")
    print("  python train_spiking_mnist.py")
    print()
    print("Custom architecture:")
    print("  python train_spiking_mnist.py --hidden-neurons 256 --hidden-layers 2")
    print()
    print("Longer training with early stopping:")
    print("  python train_spiking_mnist.py --epochs 20 --early-stopping")
    print()
    print("High-performance training:")
    print("  python train_spiking_mnist.py --hidden-neurons 512 --hidden-layers 3 \\")
    print("                                --dt-steps 50 --batch-size 128 --epochs 15")
    print()
    print("CPU-only training:")
    print("  python train_spiking_mnist.py --cpu")
    print()
    print("Custom output directory:")
    print("  python train_spiking_mnist.py --output-dir ./my_models/")
    print(f"{'='*60}\n")


def main():
    """Main training pipeline."""
    parser = argparse.ArgumentParser(
        description='Train a Spiking Neural Network on MNIST dataset',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        epilog="For more examples, run with --examples flag"
    )
    
    # Architecture parameters
    arch_group = parser.add_argument_group('Architecture Parameters')
    arch_group.add_argument(
        '--hidden-neurons', type=int, default=DEFAULT_HIDDEN_NEURONS,
        help=f'Number of neurons in each hidden layer (default: {DEFAULT_HIDDEN_NEURONS})'
    )
    arch_group.add_argument(
        '--hidden-layers', type=int, default=DEFAULT_NUM_HIDDEN_LAYERS,
        help=f'Number of hidden layers (default: {DEFAULT_NUM_HIDDEN_LAYERS})'
    )
    arch_group.add_argument(
        '--dt-steps', type=int, default=DEFAULT_DT_STEPS,
        help=f'Number of time steps for rate coding (default: {DEFAULT_DT_STEPS})'
    )
    
    # Training parameters
    train_group = parser.add_argument_group('Training Parameters')
    train_group.add_argument(
        '--epochs', type=int, default=DEFAULT_EPOCHS,
        help=f'Number of training epochs (default: {DEFAULT_EPOCHS})'
    )
    train_group.add_argument(
        '--batch-size', type=int, default=DEFAULT_BATCH_SIZE,
        help=f'Training batch size (default: {DEFAULT_BATCH_SIZE})'
    )
    train_group.add_argument(
        '--learning-rate', type=float, default=DEFAULT_LEARNING_RATE,
        help=f'Learning rate for Adam optimizer (default: {DEFAULT_LEARNING_RATE})'
    )
    train_group.add_argument(
        '--early-stopping', action='store_true', default=DEFAULT_EARLY_STOPPING,
        help='Enable early stopping when loss threshold is reached'
    )
    train_group.add_argument(
        '--early-stop-loss', type=float, default=DEFAULT_EARLY_STOP_LOSS,
        help=f'Loss threshold for early stopping (default: {DEFAULT_EARLY_STOP_LOSS})'
    )
    
    # System parameters
    sys_group = parser.add_argument_group('System Parameters')
    sys_group.add_argument(
        '--cpu', action='store_true', default=DEFAULT_USE_CPU,
        help='Force CPU usage even if CUDA is available'
    )
    sys_group.add_argument(
        '--output-dir', type=str, default=DEFAULT_OUTPUT_DIR,
        help=f'Directory to save model and mapping files (default: {DEFAULT_OUTPUT_DIR})'
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
    
    # Initialize configuration
    config = Config(args)
    
    # Print configuration
    config.print_config()
    
    try:
        # Check CUDA availability
        if not torch.cuda.is_available() and not args.cpu:
            print("Warning: CUDA not available, using CPU")
        
        # Load data
        print("Loading MNIST dataset...")
        train_loader, test_loader = MNISTDataLoader.get_mnist_loaders(config.batch_size)
        print(f"Loaded {len(train_loader.dataset)} training samples and {len(test_loader.dataset)} test samples")
        
        # Create model
        print("Creating spiking neural network...")
        model = SpikingMNISTClassifier(config).to(config.device)
        
        # Count parameters
        total_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
        print(f"Model created with {total_params:,} trainable parameters")
        
        # Train model
        trainer = Trainer(model, config)
        loss_history = trainer.train(train_loader)
        
        # Save model
        model_filename = config.output_dir / f"{config.model_name}.pth"
        torch.save(model.state_dict(), model_filename)
        print(f"Model saved to {model_filename}")
        
        # Evaluate model
        accuracy = trainer.evaluate(test_loader)
        
        # Generate neuron mapping
        mapper = NeuronMapper(model, config)
        mapper.generate_mapping()
        
        # Final summary
        print(f"\n{'='*60}")
        print(f"TRAINING COMPLETED SUCCESSFULLY!")
        print(f"{'='*60}")
        print(f"Final accuracy: {accuracy:.2f}%")
        print(f"Model saved to: {model_filename}")
        print(f"Neuron mapping saved to: {config.output_dir / 'neuron_mapping.txt'}")
        print(f"{'='*60}")
        
    except KeyboardInterrupt:
        print("\n\nTraining interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n{'='*60}")
        print(f"ERROR DURING TRAINING")
        print(f"{'='*60}")
        print(f"Error: {e}")
        print(f"\nFull traceback:")
        traceback.print_exc()
        print(f"{'='*60}")
        sys.exit(1)


if __name__ == "__main__":
    main()