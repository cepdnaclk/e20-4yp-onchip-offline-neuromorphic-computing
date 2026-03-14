# =============================================================================
# Bare-metal RISC-V assembly: Print "Hello!\n" to LiteX UART
# =============================================================================
# Uses ONLY immediate values (li/addi) and sw — no lw from data memory.
# This avoids dbus reads entirely; only dbus writes to UART CSR.
# =============================================================================

.section .text
.global _start

_start:
    lui   a0, 0xf0001        # 0xf0001000(uart_rxtx)
    addi  a1, a0, 4          # a1 = 0x82001004 (uart_txfull)

    # --- Print 'H' ---
    li    a3, 'H'            # a3 = 0x48
    sw    a3, 0(a0)          # Write to UART

    # --- Print 'e' ---
    li    a3, 'e'            # a3 = 0x65
    sw    a3, 0(a0)

    # --- Print 'l' ---
    li    a3, 'l'            # a3 = 0x6C
    sw    a3, 0(a0)

    # --- Print 'l' ---
    li    a3, 'l'
    sw    a3, 0(a0)

    # --- Print 'o' ---
    li    a3, 'o'            # a3 = 0x6F
    sw    a3, 0(a0)

    # --- Print '!' ---
    li    a3, '!'            # a3 = 0x21
    sw    a3, 0(a0)

    # --- Print newline ---
    li    a3, '\n'           # a3 = 0x0A
    sw    a3, 0(a0)

done:
    j     done               # Infinite loop (halt)
