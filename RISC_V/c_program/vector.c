void main() {
  // 1. Define Arrays in Memory
  // We assume these addresses are valid in your Data Memory
  volatile int *A = (int *)0x100;     // Input Vector A
  volatile int *B = (int *)0x114;     // Input Vector B (5 integers later)
  volatile int *C = (int *)0x128;     // Output Vector C
  volatile int *DEBUG = (int *)0x200; // Debug/Done address

  int size = 4;

  // 2. Initialization Loop (Optional, helps if memory is empty)
  // A = {1, 2, 3, 4}, B = {10, 20, 30, 40}
  for (int i = 0; i < size; i++) {
    A[i] = i + 1;
    B[i] = (i + 1) * 10;
  }

  // 3. Vector Addition Loop: C[i] = A[i] + B[i]
  // This is the critical part for SNNs (accumulating weights)
  for (int i = 0; i < size; i++) {
    C[i] = A[i] + B[i];
  }

  // 4. Verification Signal
  // If code reaches here, loops exited correctly.
  *DEBUG = 0xAAAA;
}