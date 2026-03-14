#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define TIMESTEPS 16 //timesteps per input
#define INPUT_SIZE 784 // 28x28 input channel 
#define HIDDEN_SIZE 200 // Hidden layer size
#define OUTPUT_SIZE 10 // output layer size
#define SCALE 256 // 8-bit fractional shift
#define THRESHOLD (1 * SCALE) // binary spike shreshold = 1.0
#define BETA 243 // 0.95 * 256
#define LR 150    // Learning rate for weight updates
#define batch_size 32

// Global Weights and History (Stored in RAM)
int16_t W1[INPUT_SIZE][HIDDEN_SIZE]; // Layer 1 weights
int16_t W2[HIDDEN_SIZE][OUTPUT_SIZE]; // Layer 2 weights
uint8_t input_spikes_hist[TIMESTEPS][INPUT_SIZE]; // Storage for input spike activity
uint8_t spikes1_hist[TIMESTEPS][HIDDEN_SIZE]; // History of hidden layer firing
uint8_t spikes2_hist[TIMESTEPS][OUTPUT_SIZE]; // History of output layer firing
int64_t batch_dW1[INPUT_SIZE][HIDDEN_SIZE] = {0}; // Gradient accumulation buffer - L1
int64_t batch_dW2[HIDDEN_SIZE][OUTPUT_SIZE] = {0}; // Gradient accumulation buffer - L2

// Global variable to track best accuracy
float best_accuracy = 0.0f;

// Function to dump best weights to a binary file
void save_weights(const char* filename) {
    FILE *f = fopen(filename, "wb");
    if (!f) {
        printf("Error: Could not open file for saving weights.\n");
        return;
    }
    fwrite(W1, sizeof(int16_t), INPUT_SIZE * HIDDEN_SIZE, f);
    fwrite(W2, sizeof(int16_t), HIDDEN_SIZE * OUTPUT_SIZE, f);
    fclose(f);
    printf(" >>> Best weights saved to %s <<<\n", filename);
}
 
// Function to dump weights to text file
void save_weights_txt(const char* filename) {
    FILE *f = fopen(filename, "w");
    if (!f) {
        printf("Error: Could not open file for saving weights.\n");
        return;
    }

    // Save W1 (Input to Hidden)
    fprintf(f, "W1 Weights (%d x %d):\n", INPUT_SIZE, HIDDEN_SIZE);
    for (int i = 0; i < INPUT_SIZE; i++) {
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            fprintf(f, "%d ", W1[i][j]);
        }
        fprintf(f, "\n"); // New line after each input neuron's weights
    }

    fprintf(f, "\n-------------------------------------\n\n");

    // Save W2 (Hidden to Output)
    fprintf(f, "W2 Weights (%d x %d):\n", HIDDEN_SIZE, OUTPUT_SIZE);
    for (int i = 0; i < HIDDEN_SIZE; i++) {
        for (int j = 0; j < OUTPUT_SIZE; j++) {
            fprintf(f, "%d ", W2[i][j]);
        }
        fprintf(f, "\n");
    }

    fclose(f);
    printf(" >>> Best weights saved to %s (Text Format) <<<\n", filename);
}
//----------Fixed-point Fast Sigmoid: f'(x) = 1/(1+|x|)^2------------//

int32_t fast_sigmoid_deriv(int32_t mem) {
    int32_t x = 8 * (mem - THRESHOLD); // 8 is the scaling factor
    if (x < 0) x = -x; // getting absolute value
    int32_t den = (SCALE + x); // ( 1 +|X| )
    int32_t den_sq = (den * den) >> 8; // square -> shift back to scale
    if (den_sq == 0) return SCALE; // stops division by 0
    return (SCALE * SCALE) / den_sq; // result: 1 / s*( 1 + |x |)^2
}

//------------------------BACKWARD PASS------------------------------//

void backward_pass(uint8_t label, int32_t *output_rates) {
    // Local gradient registers
    int32_t dW2[HIDDEN_SIZE][OUTPUT_SIZE] = {0};
    int32_t dW1[INPUT_SIZE][HIDDEN_SIZE] = {0};
    
    // calculating final error ------- d/dx(x-y)^2 = 2(x-y)
    int32_t delta_out[OUTPUT_SIZE];
    for(int i=0; i<OUTPUT_SIZE; i++) {
        int32_t y_true = (i == label) ? SCALE : 0;
        delta_out[i] = 2 * (output_rates[i] - y_true); 
    }

    int32_t dm2_next[OUTPUT_SIZE] = {0}; // error signal carrier for layer 2
    int32_t dm1_next[HIDDEN_SIZE] = {0}; // error signal carrier for layer 1

    // walk backwards through time steps
    for (int t = TIMESTEPS - 1; t >= 0; t--) {
        // Layer 2 Gradients ---> adjust W2
        for (int j = 0; j < OUTPUT_SIZE; j++) {
            // Get surrogate gradient based on membrane state at time 't'
            int32_t grad_s2 = fast_sigmoid_deriv(spikes2_hist[t][j] * THRESHOLD);
            // Combine current error with error leaked from the future (t+1)
            int32_t delta2 = ((delta_out[j] + (BETA * dm2_next[j] >> 8)) * grad_s2) >> 8;
            
            for (int i = 0; i < HIDDEN_SIZE; i++) {
                // if neuron 'i' fired, it gets credit/blame
                if (spikes1_hist[t][i]) dW2[i][j] += delta2;
            }
            // propagate error to previous time step
            dm2_next[j] = delta2 * (1 - spikes2_hist[t][j]);
        }
        
        // Layer 1 Gradients ---> adjust W1
        for (int i = 0; i < HIDDEN_SIZE; i++) {
            int32_t error_l1 = 0;
            // Backpropagate error from Layer 2 through the W2 weights
            for(int j = 0; j < OUTPUT_SIZE; j++) {
                int32_t grad_s2_tmp = fast_sigmoid_deriv(spikes2_hist[t][j] * THRESHOLD);
                int32_t delta2_tmp = ((delta_out[j] + (BETA * dm2_next[j] >> 8)) * grad_s2_tmp) >> 8;
                error_l1 += (delta2_tmp * W2[i][j]) >> 8;
            }
            
            int32_t grad_s1 = fast_sigmoid_deriv(spikes1_hist[t][i] * THRESHOLD);
            int32_t delta1 = ((error_l1 + (BETA * dm1_next[i] >> 8)) * grad_s1) >> 8;
            
            for (int k = 0; k < INPUT_SIZE; k++) {
                // update W1 if input 'k' spiked
                if (input_spikes_hist[t][k]) dW1[k][i] += delta1;
            }
            // temporal error propagation
            dm1_next[i] = delta1 * (1 - spikes1_hist[t][i]);
        }
    }
    
    
    for(int i=0; i<INPUT_SIZE; i++) {
        for(int j=0; j<HIDDEN_SIZE; j++) batch_dW1[i][j] += dW1[i][j];
    }
    for(int i=0; i<HIDDEN_SIZE; i++) {
        for(int j=0; j<OUTPUT_SIZE; j++) batch_dW2[i][j] += dW2[i][j];
    }
}

//------------------------FORWARD PASS------------------------------//

int train_on_sample_with_result(uint8_t label, uint8_t* pixels) {
    int32_t mem1[HIDDEN_SIZE] = {0}; // Layer 1 membrane potential registers
    int32_t mem2[OUTPUT_SIZE] = {0}; // Layer 2 membrane potential registers
    int32_t output_spikes_total[OUTPUT_SIZE] = {0}; // count spikes for rate decoding

    for (int t = 0; t < TIMESTEPS; t++) {
        // --- Layer 1 Forward ---
        // Step 1: Encoder - Convert 8-bit pixels to spikes (Poisson Encoding)
        for (int i = 0; i < INPUT_SIZE; i++) {
            input_spikes_hist[t][i] = (pixels[i] > (rand() % 255));
        }

        // Step 2: Layer 1 LIF Simulation
        for (int j = 0; j < HIDDEN_SIZE; j++) {
            mem1[j] = (mem1[j] * BETA) >> 8; // Leak
            for (int i = 0; i < INPUT_SIZE; i++) {
                // INTEGRATE: sum weights if input spikes
                if (input_spikes_hist[t][i]) mem1[j] += W1[i][j];
            }
            // FIRE: check if threshold reached
            spikes1_hist[t][j] = (mem1[j] >= THRESHOLD);
            // RESET: subtract threshold potential
            if (spikes1_hist[t][j]) mem1[j] -= THRESHOLD; 
        }

        // Step 3: Layer 2 LIF Simulation
        for (int k = 0; k < OUTPUT_SIZE; k++) {
            mem2[k] = (mem2[k] * BETA) >> 8; //Leak
            for (int j = 0; j < HIDDEN_SIZE; j++) {
                if (spikes1_hist[t][j]) mem2[k] += W2[j][k]; // INTEGRATE
            }
            if (mem2[k] >= THRESHOLD) {
                spikes2_hist[t][k] = 1; // FIRE
                output_spikes_total[k]++;  // Increment spike counter for this digit
                mem2[k] -= THRESHOLD;   // RESET
            } else {
                spikes2_hist[t][k] = 0; // NO FIRE
            }
        }
    }

    // Step 4: Decoding - Which neuron fired most
    int prediction = 0;
    int max_spikes = -1;
    for (int i = 0; i < OUTPUT_SIZE; i++) {
        if (output_spikes_total[i] > max_spikes) {
            max_spikes = output_spikes_total[i];
            prediction = i;
        }
    }
    // Step 5: Convert spike counts back to rates and start learning
    int32_t output_rates[OUTPUT_SIZE];
    for(int i=0; i<10; i++) output_rates[i] = (output_spikes_total[i] * SCALE) / TIMESTEPS;
    backward_pass(label, output_rates);

    return prediction;
}

void apply_batch_update() {
    // Update W1 based on averaged batch gradients
    for(int i=0; i<INPUT_SIZE; i++) {
        for(int j=0; j<HIDDEN_SIZE; j++) {
            W1[i][j] -= (int16_t)((LR * (batch_dW1[i][j] / batch_size)) >> 8); 
        }
    }
    // Update W2 based on averaged batch gradients
    for(int i=0; i<HIDDEN_SIZE; i++) {
        for(int j=0; j<OUTPUT_SIZE; j++) {
            W2[i][j] -= (int16_t)((LR * (batch_dW2[i][j] / batch_size)) >> 8);
        }
    }
}

int main() {
    // Weight Initialization: Hardware would load these from memory
    for(int i=0; i<INPUT_SIZE; i++) for(int j=0; j<HIDDEN_SIZE; j++) W1[i][j] = (rand() % 40) - 20;
    for(int i=0; i<HIDDEN_SIZE; i++) for(int j=0; j<OUTPUT_SIZE; j++) W2[i][j] = (rand() % 40) - 20;

    int total_epochs = 5;
    uint8_t label, pixels[INPUT_SIZE];

    for (int epoch = 0; epoch < total_epochs; epoch++) {
        FILE *file = fopen("mnist_full_train.bin", "rb"); // Stream data from external flash
        if (!file) { printf("Error opening file\n"); return 1; }
        
        int count = 0;
        int correct_in_epoch = 0;

        while (fread(&label, 1, 1, file) && fread(pixels, 1, INPUT_SIZE, file)) {
            int prediction = train_on_sample_with_result(label, pixels);
            if (prediction == label) correct_in_epoch++;
            count++;

            // Batch Update
            if (count % batch_size == 0) {
                apply_batch_update(); 
                memset(batch_dW1, 0, sizeof(batch_dW1));
                memset(batch_dW2, 0, sizeof(batch_dW2));
            }

            if (count % 1000 == 0) { 
                float acc = (float)correct_in_epoch / count * 100.0f;
                printf("Epoch %d | Progress: %d/60000 | Accuracy: %.2f%%\n", epoch + 1, count, acc);
                
                if (acc > best_accuracy) {
                    best_accuracy = acc;
                    save_weights_txt("best_weights_new.txt");
                }
            }
        }
        fclose(file);
    }
    return 0;
}