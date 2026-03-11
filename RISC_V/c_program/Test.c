#include "snn_backprop.c"

int main() {
    uint16_t spikes = 0xB0F5;
    int16_t grads[16] = {200,-100,-50,0,1,3,6,12,25,50,100,-128,0,128,255,0};
    
    int16_t result = snn_backprop(spikes, grads, -512, 20);

    // Bare-metal build: expose result for debugger/waveform instead of stdio.
    volatile int16_t final_result = result;
    (void)final_result;

    return (result == 398) ? 0 : 1;
}