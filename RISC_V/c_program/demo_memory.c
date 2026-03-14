// DEMO 2: Memory & Math Update Verification
// Purpose: Prove RISC-V core can perform specific weight updates (Learning
// Step). This isolates the "Backward Pass" logic: Load -> Calculate -> Store.

void main() {
  volatile int *DEBUG = (int *)0x200;
  volatile int *W_MEM = (int *)0x100; // Base address for weights

  // 1. Initialize Memory with a "Starting Weight"
  int weight = 50;
  W_MEM[0] = weight;

  *DEBUG = 0x1111; // Initialized

  // 2. Simulate Training Loop (5 steps)
  // We want the weight to increase by 10 each step
  // Target Final Weight: 50 + (10*5) = 100

  int i;
  int error_signal = 10; // Simple dummy error

  for (i = 0; i < 5; i++) {
    // Load
    int current_w = W_MEM[0];

    // Compute Update (Simulating: w = w + lr * error)
    // Using hardware MUL if available, or just add for safety
    int update = error_signal;

    // Modify
    current_w += update;

    // Store
    W_MEM[0] = current_w;
  }

  *DEBUG = 0xAAAA; // Done
  while (1)
    ;
}
