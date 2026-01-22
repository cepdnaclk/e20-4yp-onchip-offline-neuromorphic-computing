.section .text
.globl _start

_start:
    addi x6, x0, 7       # [0] x6 = 7
    addi x4, x0, 11      # [1] x4 = 11
    addi x5, x0, 12      # [2] x5 = 12
    add  x7, x6, x4      # [3] Hazard: x7 depends on x6, x4
    sw   x4, 0(x0)       # [4] Store x4 at mem[0]
    lw   x8, 0(x0)       # [5] Load-Use Hazard: x8 loaded from mem
    add  x7, x7, x5      # [6]
    add  x9, x8, x4      # [7] Hazard: x9 depends on x8 (Load-Use)
    lw   x10, 4(x0)      # [8]
    sw   x10, 8(x0)      # [9]
    add  x11, x10, x5    # [10]
    sub  x12, x11, x6    # [11]
    sw   x12, 8(x0)      # [12]
    lw   x13, 8(x0)      # [13]
    add  x14, x13, x12   # [14]
    ebreak               # [15] End