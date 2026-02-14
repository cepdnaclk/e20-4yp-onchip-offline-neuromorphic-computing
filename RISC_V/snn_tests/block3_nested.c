// Block 3 simplified - no loops
void main() {
  volatile int *DEBUG = (int *)0x200;
  volatile int *W1 = (int *)0x100;
  volatile int *RESULT = (int *)0x1B0;

  *DEBUG = 0x1111;

  // Manually unroll - no branches
  W1[0] = 1;
  W1[1] = 2;
  W1[2] = 3;
  W1[3] = 4;
  W1[4] = 5;
  W1[5] = 6;
  W1[6] = 7;
  W1[7] = 8;

  *DEBUG = 0x2222;

  // Manual accumulation
  int sum = W1[0] + W1[1] + W1[2] + W1[3] + W1[4] + W1[5] + W1[6] + W1[7];
  sum = sum * 4; // Simulate 4 timesteps

  *RESULT = sum; // Should be 144
  *DEBUG = 0xAAAA;

  while (1)
    ;
}