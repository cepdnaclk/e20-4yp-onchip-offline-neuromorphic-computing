#include <stdint.h>
#include <string.h>

// Define memory-mapped region for gradient data (adjust base address as needed for your system)
#define GRADIENT_MEM_BASE 0x20000000  // Adjust to your memory layout

/**
 * SNN Backpropagation with RISC-V Custom Instructions
 * 
 * Performs one complete backpropagation iteration:
 * - Loads 16 spike bits into spike LIFO
 * - Loads 16 gradient values into gradient LIFO from memory
 * - Loads initial weight and error term
 * - Computes weight update with temporal recurrence (BETA=0.95)
 * - Returns updated weight
 * 
 * @param spike_pattern: 16-bit pattern, 1 bit per timestep (MSB = timestep 15, LSB = timestep 0)
 * @param gradients: Pointer to array of 16 signed 16-bit gradient values
 * @param error_term: Initial error term (signed 16-bit)
 * @param initial_weight: Initial weight value (signed 16-bit)
 * @param grad_mem_addr: Memory address where gradients will be loaded from
 * @return: Updated weight value (signed 32-bit, saturated to int16 range)
 */
int32_t snn_backprop_compute(
    uint16_t spike_pattern,
    int16_t *gradients,
    int16_t error_term,
    int16_t initial_weight,
    uint32_t grad_mem_addr
)
{
    int32_t updated_weight = 0;
    uint32_t grad_count = 16;  // Always 16 gradient values per dataset
    
    // Copy gradient data to memory at grad_mem_addr
    // This allows the memory-to-LIFO loader to read them during streaming
    uint16_t *grad_mem = (uint16_t *)grad_mem_addr;
    for (int i = 0; i < grad_count; i++) {
        grad_mem[i] = (uint16_t)gradients[i];
    }
    
    // Inline assembly to execute custom RISC-V instructions
    // The entire process takes ~95 cycles:
    //   5 cycles: register initialization (ADDI)
    //   1 cycle:  LIFOPUSH spike pattern
    //   62 cycles: LIFOPUSHMG gradient load from memory
    //   17+ cycles: LIFOPOP + computation
    //   4 cycles: LIFOWB writeback
    
    asm volatile (
        /* 1. Initialize temporaries with necessary values */
        "mv x28, %[grad_addr] \n"         /* x28/t3 = gradient memory base address */
        "li x29, 16 \n"                   /* x29/t4 = gradient count (16 values) */
        "mv x30, %[spike] \n"             /* x30/t5 = spike pattern */
        "mv x31, %[error] \n"             /* x31/t6 = error term */
        "mv x5, %[weight] \n"             /* x5/t0  = initial weight */

        /* 2. LIFOPUSH x30, x0 - Push spike pattern to spike LIFO */
        ".word 0x000F000B \n"

        /* 3. LIFOPUSHMG x28, x29 - Load gradients from memory to gradient LIFO */
        ".word 0x01DE500B \n"

        /* 4. Wait for gradient loader to complete (~62 NOPs) */
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n"

        /* 5. LIFOPOP x5, x31 - Start streaming + load weight + error + enable computation */
        ".word 0x01F2900B \n"

        /* 6. Wait for computation to complete (17 cycles) */
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n" "nop \n" "nop \n" "nop \n"
        "nop \n" "nop \n"

        /* 7. LIFOWB x6 - Write computed weight from custom unit to register x6 */
        ".word 0x0000630B \n"

        /* 8. Recover the result from x6 into updated_weight */
        "mv %[result], x6 \n"

        : [result] "=r" (updated_weight)
        : [grad_addr] "r" (grad_mem_addr),
          [spike] "r" ((uint32_t)spike_pattern),
          [error] "r" ((int32_t)error_term),
          [weight] "r" ((int32_t)initial_weight)
        : "x5", "x6", "x28", "x29", "x30", "x31", "memory"
    );
    
    return updated_weight;
}


/**
 * Wrapper function for easier use with default memory address
 * 
 * @param spike_pattern: 16-bit spike pattern
 * @param gradients: Pointer to 16 gradient values
 * @param error_term: Error term for this iteration
 * @param initial_weight: Weight before update
 * @return: Updated weight after backpropagation
 */
int16_t snn_backprop(
    uint16_t spike_pattern,
    int16_t *gradients,
    int16_t error_term,
    int16_t initial_weight
)
{
    // Use default gradient memory address (adjust if needed)
    int32_t result = snn_backprop_compute(
        spike_pattern,
        gradients,
        error_term,
        initial_weight,
        GRADIENT_MEM_BASE
    );
    
    // Saturate to 16-bit range
    if (result > 32767) result = 32767;
    if (result < -32768) result = -32768;
    
    return (int16_t)result;
}


/**
 * Example usage demonstrating the single-function backpropagation call
 */
#ifdef ENABLE_EXAMPLE
int main(void)
{
    // Test case from hardware testbench
    // Spike pattern: 0xB0F5 = [1,0,1,0,1,1,1,1,0,0,0,0,1,1,0,1]
    uint16_t spike_pattern = 0xB0F5;
    
    // Surrogate gradient values (manually chosen for this test)
    int16_t gradient_data[16] = {
        200, -100, -50, 0, 1, 3, 6, 12,
        25, 50, 100, -128, 0, 128, 255, 0
    };
    
    // Backpropagation parameters
    int16_t error = -512;         // Initial error term
    int16_t weight = 20;          // Initial weight
    
    // Execute entire backpropagation in one call
    int16_t updated_weight = snn_backprop(
        spike_pattern,
        gradient_data,
        error,
        weight
    );
    
    // Result: updated_weight should be 398 (from hardware test)
    // This demonstrates:
    // - Spike gating (spike=1 resets delta)
    // - Temporal recurrence (spike=0 accumulates with BETA=0.95)
    // - Learning rate scaling (LR=150, divides by 256)
    
    return updated_weight;
}
#endif
