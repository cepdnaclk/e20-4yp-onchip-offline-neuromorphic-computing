#include "snn_backprop.c"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

/**
 * Complete SNN Training Example
 * 
 * Demonstrates training a single artificial neuron using:
 * - Hardware-accelerated backpropagation with custom instructions
 * - Batch processing of multiple datasets
 * - Learning curve tracking
 */

typedef struct {
    uint16_t spike_pattern;     // 16-bit spike pattern (1 bit per timestep)
    int16_t gradients[16];      // 16 surrogate gradient values
    int16_t error_signal;       // Error signal from loss function
} TrainingDataset;

typedef struct {
    int16_t weight;             // Current neuron weight
    int32_t total_loss;         // Accumulated loss over batch
    int num_updates;            // Count of backprop computations
} NeuronState;


/**
 * Initialize training state
 */
NeuronState init_neuron(int16_t initial_weight)
{
    NeuronState neuron;
    neuron.weight = initial_weight;
    neuron.total_loss = 0;
    neuron.num_updates = 0;
    return neuron;
}


/**
 * Process one training dataset
 * 
 * This is the critical function - it replaces ~100 lines of code
 * with a SINGLE FUNCTION CALL to snn_backprop()
 */
void train_on_dataset(
    NeuronState *neuron,
    const TrainingDataset *dataset
)
{
    // Execute entire backpropagation in one call
    int16_t updated_weight = snn_backprop(
        dataset->spike_pattern,      // 16-bit spike input
        dataset->gradients,          // 16 surrogate gradient values
        dataset->error_signal,       // Error from loss function
        neuron->weight               // Current weight
    );
    
    // Calculate weight change for loss tracking
    int32_t weight_delta = (int32_t)updated_weight - (int32_t)neuron->weight;
    
    // Update tracking
    neuron->weight = updated_weight;
    neuron->total_loss += weight_delta * weight_delta;  // MSE
    neuron->num_updates++;
}


/**
 * Training loop for one epoch
 */
void train_epoch(
    NeuronState *neuron,
    const TrainingDataset *datasets,
    int num_samples
)
{
    printf("Epoch: Processing %d training samples...\n", num_samples);
    printf("  Init weight: %d\n", neuron->weight);
    
    // Process each sample
    for (int i = 0; i < num_samples; i++) {
        train_on_dataset(neuron, &datasets[i]);
        
        // Print progress every 10 samples
        if ((i + 1) % 10 == 0) {
            printf("  Sample %d/%d: weight=%d, loss=%.2f\n",
                   i + 1, num_samples,
                   neuron->weight,
                   (float)neuron->total_loss / neuron->num_updates);
        }
    }
    
    printf("  Final weight: %d\n", neuron->weight);
    printf("  Avg loss: %.4f\n\n",
           (float)neuron->total_loss / neuron->num_updates);
}


/**
 * Generate synthetic training data for testing
 * In practice, these would come from your dataset
 */
void generate_training_data(
    TrainingDataset *datasets,
    int num_samples
)
{
    for (int i = 0; i < num_samples; i++) {
        // Generate random spike pattern (16 bits)
        datasets[i].spike_pattern = (uint16_t)(i * 12345) & 0xFFFF;
        
        // Generate synthetic gradients
        for (int j = 0; j < 16; j++) {
            // Simulate surrogate gradients from forward pass
            datasets[i].gradients[j] = (int16_t)((i + j) * 50 - 400);
        }
        
        // Target error (would come from loss function)
        datasets[i].error_signal = (int16_t)(-(i % 512));
    }
}


/**
 * Main training program
 */
int main(void)
{
    printf("================================================================================\n");
    printf("SNN Backpropagation Hardware Accelerator - Training Example\n");
    printf("================================================================================\n\n");
    
    // Training configuration
    #define NUM_EPOCHS 3
    #define SAMPLES_PER_EPOCH 50
    #define INIT_WEIGHT 0
    
    // Allocate training data
    TrainingDataset *training_data = (TrainingDataset *)malloc(
        SAMPLES_PER_EPOCH * sizeof(TrainingDataset)
    );
    
    if (!training_data) {
        printf("ERROR: Memory allocation failed\n");
        return 1;
    }
    
    // Initialize neuron
    NeuronState neuron = init_neuron(INIT_WEIGHT);
    
    printf("Training Configuration:\n");
    printf("  Epochs:           %d\n", NUM_EPOCHS);
    printf("  Samples/epoch:    %d\n", SAMPLES_PER_EPOCH);
    printf("  Total iterations: %d\n", NUM_EPOCHS * SAMPLES_PER_EPOCH);
    printf("  Init weight:      %d\n\n", INIT_WEIGHT);
    
    // Generate training data once
    generate_training_data(training_data, SAMPLES_PER_EPOCH);
    printf("Training data generated.\n\n");
    
    // Training loop
    for (int epoch = 0; epoch < NUM_EPOCHS; epoch++) {
        printf(">>> EPOCH %d/%d\n", epoch + 1, NUM_EPOCHS);
        train_epoch(&neuron, training_data, SAMPLES_PER_EPOCH);
    }
    
    // Final results
    printf("================================================================================\n");
    printf("Training Complete!\n");
    printf("================================================================================\n");
    printf("Final weight:      %d\n", neuron.weight);
    printf("Total updates:     %d\n", neuron.num_updates);
    printf("Total loss:        %d\n", neuron.total_loss);
    printf("Avg loss per step: %.4f\n\n",
           (float)neuron.total_loss / neuron.num_updates);
    
    // Cleanup
    free(training_data);
    
    // Success
    printf("Training successful! Weight evolved from %d to %d\n",
           INIT_WEIGHT, neuron.weight);
    
    return 0;
}

/**
 * Compilation Instructions:
 * 
 * For RISC-V 32-bit target:
 *   riscv32-unknown-elf-gcc -march=rv32i -O2 training_example.c -o training_sim
 *   
 * For simulation with your CPU (add include path):
 *   riscv32-unknown-elf-gcc -I../CPU training_example.c -o training_sim
 *   
 * For native simulation (for testing logic):
 *   gcc -O2 training_example.c -o training_sim
 *   ./training_sim
 */
