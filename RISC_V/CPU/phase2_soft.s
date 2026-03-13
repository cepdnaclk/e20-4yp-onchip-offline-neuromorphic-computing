# Phase 2 software backpropagation benchmark
# Registers:
#   x10 = loop counter (16->0)
#   x11 = spike pattern (0xB0F5)
#   x12 = weight (init 20)
#   x13 = error (-512)
#   x14 = delta (0)
#   x15 = grad base addr (0x100)
#   x16 = current gradient
#   x17 = current spike bit
#   x24 = current bit position (15->0)
#   x25,x26 = temporaries

.section .text
.global _start
_start:
    # init
    addi  x10, x0,  16          # counter = 16
    lui   x11, 0                 # spike pattern upper
    addi  x11, x11, 0x7F5       # x11 = 0x0000B000 + 0xF5... need to set properly
    # Actually: 0xB0F5 = 45301
    # lui loads upper 20 bits (sign-extended)
    # 0xB0F5 >> 12 = 0xB (= 11), but addi lower 12 = 0x0F5 = 245
    # lui x11, 0xB  -> x11 = 0x0000B000
    # addi x11, x11, 0xF5 -> x11 = 0x0000B0F5
    # can't use above since first attempt was wrong. Rewrite:
    addi  x10, x0,  16          # counter = 16 (redo)
    lui   x11, 11               # x11 = 0x0000B000
    addi  x11, x11, 245         # x11 = 0x0000B0F5
    addi  x12, x0,  20          # weight = 20
    addi  x13, x0,  -512        # error = -512  (0xFFFFFE00)
    addi  x14, x0,  0           # delta = 0
    addi  x15, x0,  256         # grad base = 0x100
    addi  x24, x0,  15          # bit pos = 15

loop:
    beq   x10, x0, done         # if counter == 0, exit
    addi  x10, x10, -1          # counter--
    lw    x16, 0(x15)           # load gradient
    addi  x15, x15, 4           # advance pointer
    srl   x17, x11, x24         # spike_pattern >> bit_pos
    andi  x17, x17, 1           # extract bit
    addi  x24, x24, -1          # bit_pos--
    bne   x17, x0, spike_high   # if spike=1, branch

    # spike_low: delta = (delta * 243) >> 8
    # 243 = 0b11110011, bits set: 0,1,4,5,6,7
    mv    x25, x0
    add   x25, x25, x14         # + delta<<0
    slli  x26, x14, 1
    add   x25, x25, x26         # + delta<<1
    slli  x26, x14, 4
    add   x25, x25, x26         # + delta<<4
    slli  x26, x14, 5
    add   x25, x25, x26         # + delta<<5
    slli  x26, x14, 6
    add   x25, x25, x26         # + delta<<6
    slli  x26, x14, 7
    add   x25, x25, x26         # + delta<<7
    srai  x14, x25, 8
    j     delta_update

spike_high:
    mv    x14, x0               # delta = 0

delta_update:
    # delta += (error * grad) >> 8
    # error = -512 = -2*256, so error*grad>>8 = -2*grad
    slli  x25, x16, 1           # x25 = grad*2
    sub   x25, x0,  x25         # x25 = -grad*2
    add   x14, x14, x25         # delta += -2*grad

weight_update:
    # weight += (delta * 150) >> 8
    # 150 = 0b10010110, bits set: 1,2,4,7
    mv    x25, x0
    slli  x26, x14, 1
    add   x25, x25, x26         # + delta<<1
    slli  x26, x14, 2
    add   x25, x25, x26         # + delta<<2
    slli  x26, x14, 4
    add   x25, x25, x26         # + delta<<4
    slli  x26, x14, 7
    add   x25, x25, x26         # + delta<<7
    srai  x25, x25, 8
    add   x12, x12, x25         # weight += scaled_delta

    j     loop

done:
    j     done                  # infinite loop (halt)
