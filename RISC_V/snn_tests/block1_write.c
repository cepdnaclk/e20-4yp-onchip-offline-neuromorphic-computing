// Block 1: Simplest possible write test
void main() {
  volatile int *DEBUG = (int *)0x200;
  *DEBUG = 0xDEADBEEF;
}