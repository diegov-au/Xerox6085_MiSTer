#include "mmio.h"
#include "iop.h"

uint16_t iop_read(uint32_t a) {
	return (uint16_t)IOP_CPMEM(a & 0x1FFFFFu);
}

void iop_write(uint32_t a, uint16_t v) {
	IOP_CPMEM(a & 0x1FFFFFu) = v;
}

void iop_raise_wake(uint16_t mask) {
	IOP_REG(REG_WAKE) = mask;
}

#define MAP_BASE      0x1E0000u
#define VACANT_FLAGS  0x60u

uint32_t iop_xlat(uint32_t va) {
	uint16_t e = iop_read(MAP_BASE + ((va >> 8) & 0xFFFFu));
	if ((e & 0xE0u) == VACANT_FLAGS) return IOP_XLAT_VACANT;
	uint32_t rp = (uint32_t)((e & 0x1Fu) << 8) | (uint32_t)((e >> 8) & 0xFFu);
	return (rp << 8) | (va & 0xFFu);
}

#ifdef SD_GAP_US
static uint32_t last_done_us;
static void disk_gap(void) {
	while ((uint32_t)(IOP_REG(REG_USEC) - last_done_us) < (uint32_t)SD_GAP_US) { }
}
#else
static void disk_gap(void) { }
#endif

#ifdef WAIT_RUN
void iop_events(uint32_t s);
int iop_cp_live;
#endif
static uint32_t mouse_seen;

static int disk_wait(void) {
#ifndef WAIT_RUN
	while (IOP_REG(REG_DISK_STAT) & 1u) {
		uint32_t xy = IOP_REG(REG_MOUSE_XY);
		if (xy != mouse_seen) {
			mouse_seen = xy;
			iop_mouse_set((uint16_t)(xy & 0xFFFFu), (uint16_t)(xy >> 16));
			iop_cursor_follow();
		}
	}
#else
	if (!iop_cp_live) { while (IOP_REG(REG_DISK_STAT) & 1u) { } }
	else while (IOP_REG(REG_DISK_STAT) & 1u) {
		uint32_t s = IOP_REG(REG_STATUS) & ~ST_NOTIFY;
		if (s) { IOP_REG(REG_ACK) = s; iop_events(s); }
		IOP_REG(REG_HOLD) = HOLD_IGNORE(ST_NOTIFY);
	}
	if (iop_cp_live) IOP_REG(REG_HOLD) = HOLD_TAKE;
#endif
#ifdef SD_GAP_US
	last_done_us = IOP_REG(REG_USEC);
#endif
	return (IOP_REG(REG_DISK_STAT) & 2u) ? 1 : 0;
}

int iop_boot_floppy(void) {
	return (IOP_REG(REG_CONFIG) & CFG_BOOT_FLOPPY) != 0;
}

int iop_clock_seconds(uint32_t* seconds) {
	if (!(IOP_REG(REG_CONFIG) & CFG_FREE_CLOCK)) return 0;
	*seconds = IOP_REG(REG_USEC) / 1000000u;
	return 1;
}

int iop_clock_legacy(void) {
	return (IOP_REG(REG_CONFIG) & CFG_LEGACY_CLOCK) != 0;
}

static uint32_t bcd(uint32_t b) { return (b >> 4) * 10 + (b & 15); }
int iop_clock_unix(uint32_t* unix_seconds) {
	uint32_t u = IOP_REG(REG_UNIX_TIME);
	if (u == 0) return 0;
	uint32_t r = IOP_REG(REG_CLOCK_RTC), ts = IOP_REG(REG_CLOCK_TS);
	if ((r & 0x80000000u) && ts) {
		int rtc_min = (int)(bcd((r >> 16) & 0xFF) * 60 + bcd((r >> 8) & 0xFF));
		int ts_min  = (int)((ts % 86400u) / 60u);
		int d = rtc_min - ts_min;
		if (d < -720) d += 1440;
		if (d >= 720) d -= 1440;
		u += (uint32_t)(d * 60);
	}
	*unix_seconds = u;
	return 1;
}

void iop_cs_write(uint32_t addr, uint16_t hi, uint16_t mid, uint16_t lo) {
	IOP_REG(REG_CS_ADDR) = addr;
	IOP_REG(REG_CS_LO)   = lo;
	IOP_REG(REG_CS_MID)  = mid;
	IOP_REG(REG_CS_HI)   = hi;
}

uint32_t iop_disk_sectors(void) {
	return IOP_REG(REG_DISK_SECTORS);
}

int iop_disk_read(uint32_t sector, uint16_t* data256, uint16_t* label10) {
	IOP_REG(REG_DISK_LBA) = sector;
	disk_gap();
	IOP_REG(REG_DISK_CMD) = DISK_READ;
	if (!disk_wait()) return 0;
	if (data256)
		for (int i = 0; i < 256; i++) data256[i] = (uint16_t)IOP_SECBUF(i);
	if (label10)
		for (int i = 0; i < 10; i++) label10[i] = (uint16_t)IOP_SECBUF(256 + i);
	return 1;
}

void iop_beep(uint16_t divisor) {
	IOP_REG(REG_BEEP) = divisor;
}

uint32_t iop_floppy_info(void) {
	return IOP_REG(REG_FDD_INFO);
}

int iop_floppy_block(uint32_t block, uint8_t* out512) {
	IOP_REG(REG_DISK_LBA) = block;
	disk_gap();
	IOP_REG(REG_DISK_CMD) = DISK_READ | DISK_FLOPPY;
	if (!disk_wait()) return 0;
	for (int i = 0; i < 256; i++) {
		uint32_t w = IOP_SECBUF(i);
		out512[2 * i]     = (uint8_t)(w >> 8);
		out512[2 * i + 1] = (uint8_t)w;
	}
	return 1;
}

#if defined(DMA_VERIFY) && defined(USE_DMA)
static uint32_t dma_bad, dma_first_bad, dma_exp, dma_got;
#endif

static uint32_t picture_blank;
void iop_picture_blank(int on) { picture_blank = on ? CURSOR_BLANK : 0u; }

void iop_cursor(int visible, uint16_t x, uint16_t y, const uint16_t* rows16) {
	if (visible)
		for (int i = 0; i < 16; i++) IOP_REG(REG_CURSOR_ROW(i)) = rows16[i];
#if defined(DMA_VERIFY) && defined(USE_DMA)
	if (visible && dma_bad) {
		IOP_REG(REG_CURSOR_ROW(12)) = dma_got;
		IOP_REG(REG_CURSOR_ROW(13)) = dma_exp;
		IOP_REG(REG_CURSOR_ROW(14)) = dma_first_bad;
		IOP_REG(REG_CURSOR_ROW(15)) = dma_bad > 0xFFFFu ? 0xFFFFu : dma_bad;
	}
#endif
	IOP_REG(REG_CURSOR_XY) = (visible ? CURSOR_SHOWN : 0u) | picture_blank
	                       | ((uint32_t)(y & 0x3FFFu) << 16) | x;
}

#ifndef USE_DMA
void iop_sector_to_mem(uint32_t word, uint32_t real, int n) {
	for (int i = 0; i < n; i++) IOP_CPMEM(real + (uint32_t)i) = IOP_SECBUF(word + (uint32_t)i);
}

void iop_mem_to_sector(uint32_t word, uint32_t real, int n) {
	for (int i = 0; i < n; i++) IOP_SECBUF(word + (uint32_t)i) = IOP_CPMEM(real + (uint32_t)i);
}
#else
#ifdef DMA_VERIFY
static void dma_check(uint32_t word, uint32_t real, int n, int to_sector) {
	for (int i = 0; i < n; i++) {
		uint16_t m = (uint16_t)IOP_CPMEM(real + (uint32_t)i);
		uint16_t s = (uint16_t)IOP_SECBUF(word + (uint32_t)i);
		if (m != s) {
			if (dma_bad++ == 0) {
				dma_first_bad = (word + (uint32_t)i) | (to_sector ? 0x8000u : 0u);
				dma_exp = to_sector ? m : s;
				dma_got = to_sector ? s : m;
			}
			if (to_sector) IOP_SECBUF(word + (uint32_t)i) = m;
			else           IOP_CPMEM(real + (uint32_t)i) = s;
		}
	}
}
#endif

void iop_sector_to_mem(uint32_t word, uint32_t real, int n) {
	IOP_REG(REG_DMA_REAL) = real;
	IOP_REG(REG_DMA_WORD) = word;
	IOP_REG(REG_DMA_GO)   = (uint32_t)n;
#ifdef DMA_VERIFY
	dma_check(word, real, n, 0);
#endif
}

void iop_mem_to_sector(uint32_t word, uint32_t real, int n) {
	IOP_REG(REG_DMA_REAL) = real;
	IOP_REG(REG_DMA_WORD) = word;
	IOP_REG(REG_DMA_GO)   = (uint32_t)n | DMA_TO_SECTOR;
#ifdef DMA_VERIFY
	dma_check(word, real, n, 1);
#endif
}
#endif

int iop_disk_write_sector(uint32_t sector, const uint16_t* label10) {
	uint32_t cmd = DISK_WRITE | DISK_WDATA;
	if (label10) {
		for (int i = 0; i < 10; i++) IOP_SECBUF(256 + i) = label10[i];
		cmd |= DISK_WLABEL;
	}
	IOP_REG(REG_DISK_LBA) = sector;
	disk_gap();
	IOP_REG(REG_DISK_CMD) = cmd;
	return disk_wait();
}

int iop_disk_write(uint32_t sector, const uint16_t* data256,
                   const uint16_t* label10) {
	uint32_t cmd = DISK_WRITE;
	if (data256) {
		for (int i = 0; i < 256; i++) IOP_SECBUF(i) = data256[i];
		cmd |= DISK_WDATA;
	}
	if (label10) {
		for (int i = 0; i < 10; i++) IOP_SECBUF(256 + i) = label10[i];
		cmd |= DISK_WLABEL;
	}
	IOP_REG(REG_DISK_LBA) = sector;
	disk_gap();
	IOP_REG(REG_DISK_CMD) = cmd;
	return disk_wait();
}
