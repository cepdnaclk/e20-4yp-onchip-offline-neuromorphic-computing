void main() {
  // We declare pointers to specific memory locations for inputs.
  // In simulation, we can assume values are already there, or write them first.
  volatile int *input_a_ptr = (int *)0x10;
  volatile int *input_b_ptr = (int *)0x14;
  volatile int *output_ptr = (int *)0x20;

  // 1. Initialize values (compiler is forced to use registers)
  *input_a_ptr = 10;
  *input_b_ptr = 20;

  // 2. Load back from memory (forces the CPU to not know the values ahead of
  // time)
  int a = *input_a_ptr;
  int b = *input_b_ptr;

  // 3. This will now generate an actual 'ADD' instruction
  int c = a + b;

  // 4. Store result
  *output_ptr = c;
}