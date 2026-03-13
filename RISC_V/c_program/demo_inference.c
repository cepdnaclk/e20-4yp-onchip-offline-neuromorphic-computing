// Block 4: Single LIF Neuron Simulation
// Goal: Verify we can update v_mem over time

void main() {
  volatile int *DEBUG = (int *)0x200;
  volatile int *RESULT = (int *)0x1B0;

  // Simulation Parameters
  int v_mem = 0;   // Initial membrane potential
  int v_th = 30;   // Threshold
  int decay = 2;   // Simple decay (subtraction)
  int input = 10;  // Constant input current
  int v_reset = 0; // Reset value

  *DEBUG = 0x1111; // Start

  // Simulate 5 Timesteps
  // Expected behavior:
  // t=0: v=0
  // t=1: v = 0 + 10 - 2 = 8
  // t=2: v = 8 + 10 - 2 = 16
  // t=3: v = 16 + 10 - 2 = 24
  // t=4: v = 24 + 10 - 2 = 32 -> SPIKE! -> v_mem becomes 0
  // t=5: v = 0 + 10 - 2 = 8

  volatile int *TRACE = (int *)0x100; // Use 0x100 to record trace

  for (int t = 0; t < 5; t++) {
    // 1. Leak & Integrate
    v_mem = v_mem + input - decay;

    // 2. Fire & Reset
    if (v_mem > v_th) {
      // Spike!
      *RESULT = 0xFFFF; // Mark a spike at 0x1B0
      v_mem = v_reset;
    } else {
      *RESULT = 0x0000; // No spike
    }

    // 3. Store State for Trace (at 0x100, 0x104, etc.)
    TRACE[t] = v_mem;
  }

  *DEBUG = 0xAAAA; // Done
  while (1)
    ;
}
