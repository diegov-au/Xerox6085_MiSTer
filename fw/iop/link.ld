MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K }

SECTIONS
{
	.text : {
		KEEP(*(.text.start))
		*(.text .text.*)
		*(.rodata .rodata.* .srodata .srodata.*)
	} > RAM
	.data : { *(.data .data.* .sdata .sdata.*) } > RAM
	.bss (NOLOAD) : {
		__bss_start = .;
		*(.bss .bss.* .sbss .sbss.* COMMON)
		. = ALIGN(4);
		__bss_end = .;
	} > RAM
	__stack_top = ORIGIN(RAM) + LENGTH(RAM);
	ASSERT(__bss_end <= __stack_top - 2048, "IOP firmware: under 2 KB left for the stack")
}
