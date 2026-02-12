// Minimal SNN for RISC-V - Simpler version without static variables
#define TIMESTEPS 4
#define INPUT_SIZE 8
#define HIDDEN_SIZE 4
#define OUTPUT_SIZE 2
#define SCALE 256
#define THRESHOLD 256
#define BETA 243
#define LR 150

volatile int *DEBUG = (int *)0x200;
volatile int *W1_BASE = (int *)0x100;
volatile int *W2_BASE = (int *)0x180;
volatile int *RESULT = (int *)0x1B0;

void main() {
  // STEP 1: Initialize Weights with simple pattern (no rand)
  for (int i = 0; i < INPUT_SIZE * HIDDEN_SIZE; i++) {
    W1_BASE[i] = (i % 40) - 20; // Deterministic: -20, -19, ..., 19, -20, ...
  }
  for (int i = 0; i < HIDDEN_SIZE * OUTPUT_SIZE; i++) {
    W2_BASE[i] = (i % 40) - 20;
  }
  *DEBUG = 0x1111;

  // STEP 2: Create fake input
  int input_spikes[INPUT_SIZE];
  for (int i = 0; i < INPUT_SIZE; i++) {
    input_spikes[i] = (i % 2); // 0,1,0,1,0,1,0,1
  }

  // STEP 3: Forward Pass
  int mem1[HIDDEN_SIZE] = {0};
  int mem2[OUTPUT_SIZE] = {0};
  int spikes1[HIDDEN_SIZE] = {0};
  int spikes2[OUTPUT_SIZE] = {0};
  int output_count[OUTPUT_SIZE] = {0};

  for (int t = 0; t < TIMESTEPS; t++) {
    for (int j = 0; j < HIDDEN_SIZE; j++) {
      mem1[j] = (mem1[j] * BETA) >> 8;
      for (int i = 0; i < INPUT_SIZE; i++) {
        if (input_spikes[i]) {
          mem1[j] += W1_BASE[i * HIDDEN_SIZE + j];
        }
      }
      spikes1[j] = (mem1[j] >= THRESHOLD) ? 1 : 0;
      if (spikes1[j])
        mem1[j] -= THRESHOLD;
    }

    for (int k = 0; k < OUTPUT_SIZE; k++) {
      mem2[k] = (mem2[k] * BETA) >> 8;
      for (int j = 0; j < HIDDEN_SIZE; j++) {
        if (spikes1[j]) {
          mem2[k] += W2_BASE[j * OUTPUT_SIZE + k];
        }
      }
      spikes2[k] = (mem2[k] >= THRESHOLD) ? 1 : 0;
      if (spikes2[k]) {
        mem2[k] -= THRESHOLD;
        output_count[k]++;
      }
    }
  }
  *DEBUG = 0x2222;

  // STEP 4: Decode prediction
  int prediction = 0;
  int max_count = output_count[0];
  for (int i = 1; i < OUTPUT_SIZE; i++) {
    if (output_count[i] > max_count) {
      max_count = output_count[i];
      prediction = i;
    }
  }
  *RESULT = prediction;
  *DEBUG = 0x3333;

  // STEP 5: Backward Pass
  int label = 1;
  int error[OUTPUT_SIZE];
  for (int k = 0; k < OUTPUT_SIZE; k++) {
    int y_true = (k == label) ? SCALE : 0;
    int rate = (output_count[k] * SCALE) / TIMESTEPS;
    error[k] = 2 * (rate - y_true);
  }

  for (int j = 0; j < HIDDEN_SIZE; j++) {
    for (int k = 0; k < OUTPUT_SIZE; k++) {
      int grad = (error[k] * spikes1[j]) >> 8;
      int delta = (LR * grad) >> 8;
      W2_BASE[j * OUTPUT_SIZE + k] -= delta;
    }
  }
  *DEBUG = 0x4444;

  *DEBUG = 0xAAAA;
}