void main() {
    volatile int *DEBUG = (int *)0x200;
    volatile int *RESULT = (int *)0x1B0;
    volatile int *COUNTER = (int *)0x1B4;
    
    *DEBUG = 0x1111;
    
    int sum = 0;
    volatile int limit = 4;  // volatile prevents optimization
    for (int i = 0; i < limit; i++) {
        sum += 10;
        *COUNTER = i;  // Force memory access in loop
    }
    
    *RESULT = sum;
    *DEBUG = 0xAAAA;
    
    while(1);
}
