MEMORY
{
    /* Define your memory size here. Example: 4KB */
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 4K
}

SECTIONS
{
    /* Put the code (.text) at the start */
    .text :
    {
        *(.init)   /* This places crt0.s first */
        *(.text)   /* Then your C code */
    } > RAM

    /* Place data variables next */
    .data : { *(.data) } > RAM
    .bss  : { *(.bss)  } > RAM
}