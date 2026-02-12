// Block 2: Loop write test
void main() {
  volatile int *DEBUG = (int *)0x200;
  volatile int *W1 = (int *)0x100;

  *DEBUG = 0x1111; // Mark: starting

  // Write 8 values to W1 array
  for (int i = 0; i < 8; i++) {
    W1[i] = i + 100; // Write 100, 101, 102, 103, 104, 105, 106, 107
  }

  *DEBUG = 0xAAAA; // Mark: done
}