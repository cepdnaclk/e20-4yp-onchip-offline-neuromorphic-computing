.section .init
.global _start

_start:
    # 1. Initialize the Stack Pointer (sp)
    # We set it to 4KB (0x1000) assuming your Verilog memory is at least that big.
    # The stack grows DOWN from this address.
    li sp, 1020

    # 2. Jump to the main C function
    call main

    # 3. Halt loop (in case main returns)
loop:
    j loop