/* Linker script for bare-metal RISC-V — targets LiteX ROM at 0x00000000 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
}

SECTIONS
{
    .text : {
        *(.text)
        *(.text.*)
    } > ROM

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > ROM
}
