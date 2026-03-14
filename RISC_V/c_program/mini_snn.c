// XOR SNN with On-Chip Offline Learning on RISC-V (RV32IM)
// Uses hardware MUL - compile with -march=rv32im
// Network: 2 inputs -> 4 hidden (LIF) -> 1 output (LIF)

#define TIMESTEPS 8
#define HIDDEN 4
#define THRESHOLD 128
#define EPOCHS 20
#define LR 24 // Learning rate (Q8: 24/256 ≈ 0.094)

void main() {
  volatile int *DEBUG = (int *)0x200;
  volatile int *RESULT = (int *)0x1B0;
  volatile int *W1_MEM = (int *)0x100;
  volatile int *W2_MEM = (int *)0x180;
  volatile int *TEST_OUT = (int *)0x1C0;

  // XOR dataset (manual init, no .data section)
  int xor_a[4];
  xor_a[0] = 0;
  xor_a[1] = 0;
  xor_a[2] = 1;
  xor_a[3] = 1;
  int xor_b[4];
  xor_b[0] = 0;
  xor_b[1] = 1;
  xor_b[2] = 0;
  xor_b[3] = 1;
  int xor_t[4];
  xor_t[0] = 0;
  xor_t[1] = 1;
  xor_t[2] = 1;
  xor_t[3] = 0;

  // Weights: W1[8] = Input(2)->Hidden(4), W2[4] = Hidden(4)->Output(1)
  int w1[8];
  w1[0] = 50;
  w1[1] = -30;
  w1[2] = 40;
  w1[3] = -50;
  w1[4] = -40;
  w1[5] = 60;
  w1[6] = -20;
  w1[7] = 30;
  int w2[4];
  w2[0] = 50;
  w2[1] = -40;
  w2[2] = 30;
  w2[3] = -50;

  // Save initial weights
  int i, j, s, t;
  for (i = 0; i < 8; i++)
    W1_MEM[i] = w1[i];
  for (i = 0; i < 4; i++)
    W2_MEM[i] = w2[i];
  *DEBUG = 0x1111;

  // ========== TRAINING ==========
  int epoch;
  for (epoch = 0; epoch < EPOCHS; epoch++) {
    for (s = 0; s < 4; s++) {
      int in_a = xor_a[s];
      int in_b = xor_b[s];

      // -- INFERENCE PHASE --
      int h_mem[4];
      int h_count[4];
      for (j = 0; j < HIDDEN; j++) {
        h_mem[j] = 0;
        h_count[j] = 0;
      }
      int o_mem = 0, o_count = 0;

      for (t = 0; t < TIMESTEPS; t++) {
        int h_spike[4];
        for (j = 0; j < HIDDEN; j++) {
          h_mem[j] = h_mem[j] - (h_mem[j] >> 4); // leak
          if (in_a)
            h_mem[j] += w1[j]; // input 0
          if (in_b)
            h_mem[j] += w1[4 + j]; // input 1
          if (h_mem[j] >= THRESHOLD) {
            h_spike[j] = 1;
            h_count[j]++;
            h_mem[j] -= THRESHOLD;
          } else {
            h_spike[j] = 0;
          }
        }
        o_mem = o_mem - (o_mem >> 4);
        for (j = 0; j < HIDDEN; j++)
          if (h_spike[j])
            o_mem += w2[j];
        if (o_mem >= THRESHOLD) {
          o_count++;
          o_mem -= THRESHOLD;
        }
      }

      // -- LEARNING PHASE --
      int out_rate = o_count * 32;      // Hardware MUL!
      int target_rate = xor_t[s] * 256; // Hardware MUL!
      int error = out_rate - target_rate;

      // Update W2: delta = error * LR >> 8
      for (j = 0; j < HIDDEN; j++) {
        if (h_count[j] > 0) {
          int delta = (error * LR) >> 8; // Hardware MUL!
          w2[j] -= delta;
        }
      }

      // Update W1: step proportional to error
      int step = (error * LR) >> 8; // Hardware MUL!
      if (in_a)
        for (j = 0; j < HIDDEN; j++)
          w1[j] -= step;
      if (in_b)
        for (j = 0; j < HIDDEN; j++)
          w1[4 + j] -= step;
    }
  }

  *DEBUG = 0x2222;

  // Save trained weights
  for (i = 0; i < 8; i++)
    W1_MEM[i] = w1[i];
  for (i = 0; i < 4; i++)
    W2_MEM[i] = w2[i];
  *DEBUG = 0x3333;

  // ========== TEST ==========
  int correct = 0;
  for (s = 0; s < 4; s++) {
    int in_a = xor_a[s];
    int in_b = xor_b[s];
    int h_mem[4];
    int h_spike[4];
    for (j = 0; j < HIDDEN; j++)
      h_mem[j] = 0;
    int o_mem = 0, o_count = 0;

    for (t = 0; t < TIMESTEPS; t++) {
      for (j = 0; j < HIDDEN; j++) {
        h_mem[j] = h_mem[j] - (h_mem[j] >> 4);
        if (in_a)
          h_mem[j] += w1[j];
        if (in_b)
          h_mem[j] += w1[4 + j];
        if (h_mem[j] >= THRESHOLD) {
          h_spike[j] = 1;
          h_mem[j] -= THRESHOLD;
        } else {
          h_spike[j] = 0;
        }
      }
      o_mem = o_mem - (o_mem >> 4);
      for (j = 0; j < HIDDEN; j++)
        if (h_spike[j])
          o_mem += w2[j];
      if (o_mem >= THRESHOLD) {
        o_count++;
        o_mem -= THRESHOLD;
      }
    }

    int pred = (o_count > (TIMESTEPS / 2)) ? 1 : 0;
    TEST_OUT[s] = pred;
    if (pred == xor_t[s])
      correct++;
  }

  *RESULT = correct;
  *DEBUG = 0xAAAA;
  while (1)
    ;
}