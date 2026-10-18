# IOP firmware

The firmware for the core's I/O processor: a PicoRV32 (RV32I) soft CPU that
takes the place of the 6085's 80186. It implements the IOP's device handlers
at the protocol level (disk, floppy, display, keyboard and mouse, Ethernet,
RS-232C, system configuration) and boots the machine from the mounted disk
image. Xerox's microcode and germ are not part of it; they are loaded from the
user's own disk at start-up.

## Building

In a shell with the RISC-V GNU toolchain (`riscv64-unknown-elf-gcc`):

```
make -C fw/iop
python3 tools/mkbootrom.py
```

The first command builds `fw/iop/iop.hex`. The second packs it with
`tools/seat.txt` (the CPU's starting register state) into
`release/boot0.rom`, the file MiSTer loads from `games/Xerox-6085/`.

## EEPROM data

The system configuration handler (handler 19) answers the 93C46 EEPROM
reads and writes that ViewPoint, the Installer and the Workstation
Diagnostics make. Its contents give the rigid disk parameters (cylinders,
heads, precompensation) used when a disk is partitioned and formatted.

`iop/iop.c` holds two 64-word arrays for this, `eeprom_m1325` and
`eeprom_q540`, derived from dumps of the U128 93C46 EEPROM of two real
6085 IOP boards:

| Array | Drive | Source dump |
|---|---|---|
| `eeprom_m1325` | Micropolis 1325 (80 MB) | `U128_IOP_sn_021688_08CD.bin` |
| `eeprom_q540` | Quantum Q540 (40 MB) | `U128_IOP_sn_091688_094E.bin` |

The handler serves the one that matches the attached disk image. The arrays
are configuration values only (drive geometry, option flags and a checksum);
they hold no serial number or network address.
