
# RISC-V Firmware for Inference Test
# Address Map:
# 0x80000000: Data1
# 0x80000008: Data2
# 0x80000010: Funct (Trigger)
# 0x80000018: Status

start:
    # Load MMIO Base Address into s0 (0x80000000)
    LUI s0, 0x80000
    
    # Prepare Data1: Opcode=1 (Init Write), Count=1
    # 0x11000000...
    LUI t0, 0x11000
    # Store bits [63:32] of Data1 (Offset 4)
    # Since we are 32-bit, we write 64-bit split registers
    # My simple SoC has: 
    # 0x80000000: Data1[31:0]
    # 0x80000004: Data1[63:32]
    # 0x80000008: Data2[31:0]
    # 0x8000000C: Data2[63:32]
    
    SW t0, 4(s0)    # Write Data1[63:32]
    ADDI t1, zero, 1
    SW t1, 0(s0)    # Write Data1[31:0] (Dummy data)
    
    # Prepare Data2: Dummy
    SW zero, 8(s0)
    SW zero, 12(s0)
    
    # Trigger Fire (Write to Funct, Offset 16 = 0x10)
    ADDI t2, zero, 1 # Funct = 1
    SW t2, 16(s0)

wait_loop:
    # Read Status (Offset 24 = 0x18)
    LW t3, 24(s0)
    # Check bit 0 (ready)
    ANDI t3, t3, 1
    # If t3 is 0, loop
    BEQ t3, zero, wait_loop
    
done:
    # Loop forever
    BEQ zero, zero, done
