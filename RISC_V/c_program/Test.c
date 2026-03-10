#include "snn_backprop.c"
#include <stdio.h>

int main() {
    uint16_t spikes = 0xB0F5;
    int16_t grads[16] = {200,-100,-50,0,1,3,6,12,25,50,100,-128,0,128,255,0};
    
    int16_t result = snn_backprop(spikes, grads, -512, 20);
    
    printf("Result: %d (Expected: 398)\n", result);  // Should output: 398
    
    return 0;
}