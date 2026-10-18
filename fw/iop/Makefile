CROSS   = riscv64-unknown-elf-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
SIZE    = $(CROSS)size

SIM     = .
CFLAGS  = -march=rv32i -mabi=ilp32 -O2 -flto -ffreestanding -fno-builtin -nostdlib \
          -DIOP_FIRMWARE -Wall -Wextra -I$(SIM) -I.
LDFLAGS = -march=rv32i -mabi=ilp32 -O2 -flto -nostdlib -Wl,-T,link.ld -Wl,--gc-sections
CFLAGS += $(EXTRA)

SRC = start.S main.c host.c $(SIM)/iop.c

all: iop.hex

iop.elf: $(SRC) mmio.h link.ld $(SIM)/iop.h Makefile
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRC) -lgcc
	$(SIZE) $@

iop.bin: iop.elf
	$(OBJCOPY) -O binary $< $@

iop.hex: iop.bin
	python3 -c "import sys,struct; d=open('$<','rb').read(); d+=bytes((-len(d))%4); \
w=[struct.unpack_from('<I',d,i)[0] for i in range(0,len(d),4)]; \
w+=[0]*(8192-len(w)); open('$@','w').write(''.join('%08x\n'%x for x in w))"

clean:
	rm -f iop.elf iop.bin iop.hex

.PHONY: all clean
