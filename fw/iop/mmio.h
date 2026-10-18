#ifndef XEROX_IOP_MMIO_H
#define XEROX_IOP_MMIO_H

#include <stdint.h>

#define IOP_REG(off)      (*(volatile uint32_t*)(0x10000000u + (off)))
#define IOP_SECBUF(i)     (*(volatile uint32_t*)(0x10010000u + 4u * (uint32_t)(i)))
#define IOP_CPMEM(w)      (*(volatile uint32_t*)(0x20000000u + 4u * (uint32_t)(w)))

#define REG_STATUS        0x00
#define REG_ACK           0x04
#define   ST_NOTIFY       (1u << 0)
#define   ST_LOCKREL      (1u << 1)
#define   ST_VSYNC        (1u << 2)
#define   ST_INPUT        (1u << 3)
#define   ST_VSAFE        (1u << 4)

#define REG_WAKE          0x08

#define REG_HOLD          0x0C
#define   HOLD_TAKE       1u
#define   HOLD_IGNORE(st) ((uint32_t)(st) << 4)

#define REG_DISK_LBA      0x10
#define REG_DISK_CMD      0x14
#define   DISK_READ       1u
#define   DISK_WRITE      2u
#define   DISK_WDATA      4u
#define   DISK_WLABEL     8u
#define   DISK_FLOPPY     16u
#define REG_DISK_STAT     0x18
#define REG_DISK_SECTORS  0x1C

#define REG_MOUSE_XY      0x20
#define REG_KEYS(n)       (0x40 + 4u * (uint32_t)(n))

#define REG_USEC          0x80

#define REG_CONFIG        0x84
#define   CFG_BOOT        1u
#define   CFG_FREE_CLOCK  2u
#define   CFG_BOOT_FLOPPY 4u
#define   CFG_LEGACY_CLOCK 8u

#define REG_CS_ADDR       0x88
#define REG_CS_LO         0x8C
#define REG_CS_MID        0x90
#define REG_CS_HI         0x94

#define REG_DMA_REAL      0x98
#define REG_DMA_WORD      0x9C
#define REG_DMA_GO        0xA0
#define   DMA_TO_SECTOR   (1u << 16)

#define REG_CURSOR_XY     0xA4

#define REG_UNIX_TIME     0xA8
#define REG_CLOCK_RTC     0xAC
#define REG_CLOCK_TS      0xB0
#define REG_FDD_INFO      0xB4
#define REG_BEEP          0xB8
#define   CURSOR_SHOWN    (1u << 31)
#define   CURSOR_BLANK    (1u << 30)
#define REG_CURSOR_ROW(n) (0xC0 + 4u * (uint32_t)(n))

#endif
