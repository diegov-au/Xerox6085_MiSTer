#include <stddef.h>
#include "iop.h"
#ifndef IOP_FIRMWARE
#include <stdlib.h>
#endif

#define SEGMENT_WORDS      8
#define IORTABLE_SEGMENTS  (IOP_IOR_BASE + 2)

#define HANDLER_PROCESSOR  16

static uint16_t bswap(uint16_t v) {
	return (uint16_t)(((v & 0x00FFu) << 8) | ((v & 0xFF00u) >> 8));
}

#define MAILBOX_WAKE  0x050301u

static void post_wake(uint16_t mask) {
	iop_write(MAILBOX_WAKE, (uint16_t)(iop_read(MAILBOX_WAKE) | mask));
	iop_raise_wake(mask);
}

void iop_post_wake(uint16_t mask) { post_wake(mask); }

static uint32_t fcb_of(int handler_id) {
	uint16_t seg = bswap(iop_read(IORTABLE_SEGMENTS + 2u * (uint32_t)handler_id));
	if (seg == 0)
		return 0;
	return (IOP_IOR_BASE & 0xFF0000u) | ((uint32_t)seg * SEGMENT_WORDS);
}

#define PFCB_MESA_CLIENT_MASK  5
#define PFCB_TOD_AND_COMMAND   6
#define PFCB_DATA0             7
#define PFCB_DATA1             8
#define PFCB_DATA2             9

#define CMD_NONE                0
#define CMD_READ_GMT            1
#define CMD_WRITE_GMT           2
#define CMD_READ_HOST_ID        3
#define CMD_READ_VM_MAP_DESC    4
#define CMD_READ_REAL_MEM_DESC  5
#define CMD_READ_DISPLAY_DESC   6
#define CMD_READ_KEYBOARD_TYPE  7
#define CMD_READ_PC_TYPE        8
#define CMD_BOOT_BUTTON         9
#define CMD_READ_NUMB_CS_BANKS 10
#define CMD_READ_MACHINE_TYPE  11

#define PILOT_EPOCH 0xA586B500u

#define UNIX_TO_PILOT 2177452800u

#define LEGACY_EPOCH (882187200u + UNIX_TO_PILOT)

static int32_t gmt_correction;

static int      clock_set;
static uint32_t clock_base;
static int clock_now(uint32_t* now) {
	uint32_t secs, unix_now;
	if (!iop_clock_seconds(&secs)) return 0;
	if (!clock_set) {
		clock_base = iop_clock_legacy()        ? LEGACY_EPOCH - secs
		           : iop_clock_unix(&unix_now) ? unix_now + UNIX_TO_PILOT - secs
		                                       : PILOT_EPOCH;
		clock_set = 1;
	}
	*now = clock_base + secs;
	return 1;
}

static uint32_t gmt_now(void) {
	uint32_t now;
	return clock_now(&now) ? now + (uint32_t)gmt_correction : PILOT_EPOCH;
}

#define REAL_FIRST_MAP_PAGE      7680
#define REAL_COUNT_MAP_PAGES      256
#define REAL_FIRST_VMM_PAGE         0
#define REAL_LAST_VMM_PAGE       7679
#define REAL_COUNT_VMM_PAGES     7680
#define DISPLAY_TYPE                5
#define REAL_FIRST_DISPLAY_PAGE  7936
#define REAL_COUNT_DISPLAY_PAGES  256

static uint16_t cpu_id[3];

void iop_reset(void) {
	cpu_id[0] = 0x1000;
	cpu_id[1] = 0xFE31;
	cpu_id[2] = 0xAB21;
}

static void set_data(uint32_t fcb, int n, uint16_t value) {
	iop_write(fcb + PFCB_DATA0 + (uint32_t)n, bswap(value));
}

static long     st_cmd_count[16];
static uint16_t st_cmd_last[16][3];
static long     st_lock_count[8];
static long     st_lock_bad = 0;
static uint16_t st_lock_last_mask = 0;

static int processor_notify(uint16_t mask) {
	uint32_t fcb = fcb_of(HANDLER_PROCESSOR);
	if (fcb == 0) { return 0; }

	uint16_t client = iop_read(fcb + PFCB_MESA_CLIENT_MASK);
	if (mask != 0 && mask != client) { return 0; }

	uint16_t word = iop_read(fcb + PFCB_TOD_AND_COMMAND);
	uint16_t cmd = (uint16_t)(word & 0x00FFu);

	switch (cmd) {
	case CMD_NONE:
		return 0;

	case CMD_READ_HOST_ID:
		set_data(fcb, 0, bswap(cpu_id[0]));
		set_data(fcb, 1, bswap(cpu_id[1]));
		set_data(fcb, 2, bswap(cpu_id[2]));
		break;

	case CMD_READ_VM_MAP_DESC:
		set_data(fcb, 0, REAL_FIRST_MAP_PAGE);
		set_data(fcb, 1, REAL_COUNT_MAP_PAGES);
		break;

	case CMD_READ_REAL_MEM_DESC:
		set_data(fcb, 0, REAL_FIRST_VMM_PAGE);
		set_data(fcb, 1, REAL_LAST_VMM_PAGE);
		set_data(fcb, 2, REAL_COUNT_VMM_PAGES);
		break;

	case CMD_READ_DISPLAY_DESC:
		set_data(fcb, 0, DISPLAY_TYPE);
		set_data(fcb, 1, REAL_FIRST_DISPLAY_PAGE);
		set_data(fcb, 2, REAL_COUNT_DISPLAY_PAGES);
		break;

	case CMD_READ_KEYBOARD_TYPE:
		set_data(fcb, 0, 2);
		break;

	case CMD_READ_PC_TYPE:
		set_data(fcb, 0, 0);
		break;

	case CMD_READ_NUMB_CS_BANKS:
		set_data(fcb, 0, 1);
		break;

	case CMD_READ_MACHINE_TYPE:
		set_data(fcb, 0, 3);
		break;

	case CMD_READ_GMT: {
		uint32_t t = gmt_now();
#ifndef IOP_FIRMWARE
		static int gmt_traced;
		if (getenv("GMT_TRACE") && !gmt_traced++)
			fprintf(stderr, "GMT first read: unix %u\n", t - UNIX_TO_PILOT);
#endif
		set_data(fcb, 0, (uint16_t)(t & 0xFFFF));
		set_data(fcb, 1, (uint16_t)(t >> 16));
		break;
	}

	case CMD_WRITE_GMT: {
		uint32_t now;
		if (clock_now(&now)) {
			uint32_t w = (uint32_t)bswap(iop_read(fcb + PFCB_DATA0))
			           | ((uint32_t)bswap(iop_read(fcb + PFCB_DATA1)) << 16);
			gmt_correction = (int32_t)(w - now);
		}
		break;
	}

	case CMD_BOOT_BUTTON:
	default:
		break;
	}

	iop_write(fcb + PFCB_TOD_AND_COMMAND, (uint16_t)(word & 0xFF00u));

	if (cmd < 16) {
		st_cmd_count[cmd]++;
		st_cmd_last[cmd][0] = bswap(iop_read(fcb + PFCB_DATA0));
		st_cmd_last[cmd][1] = bswap(iop_read(fcb + PFCB_DATA1));
		st_cmd_last[cmd][2] = bswap(iop_read(fcb + PFCB_DATA2));
	}
	return 1;
}

void iop_proc_stats(long* counts, unsigned* last) {
	for (int i = 0; i < 16; i++) {
		if (counts) { counts[i] = st_cmd_count[i]; }
		if (last) {
			last[i * 3 + 0] = st_cmd_last[i][0];
			last[i * 3 + 1] = st_cmd_last[i][1];
			last[i * 3 + 2] = st_cmd_last[i][2];
		}
	}
}

#define HANDLER_DISK   2
#define MAX_DCB        2

#define DFCB_WORK_MASK              0x15
#define DFCB_MESA_CLEANUP_REQUEST   0x17
#define DFCB_HANDLER_STOPPED_MESA   0x19
#define DFCB_STOPPED_MESA_CLEANUP   0x1B
#define DFCB_START_HANDLER_MESA     0x1D
#define DFCB_HANDLER_STATE          0x1F
#define DFCB_UNEXPECTED_INTR        0x26
#define DFCB_UNEXPECTED_DMA_INTR    0x27
#define DFCB_DCB0                   0x28
#define DFCB_DCB_STRIDE             0x1A

#define DCB_MESA_HEAD                 0x00
#define DCB_MESA_COND_MASK_VALUE      0x0E
#define DCB_FLAGS_AND_DISK_STATE      0x14

#define IOCB_DEV_STATUS_A     0x08
#define IOCB_DEV_STATUS_B     0x09
#define IOCB_MESA_NEXT        0x0D
#define IOCB_USE_BUFFER       0x20
#define IOCB_BUFFER_HIT       0x21
#define IOCB_DATA_PTR_LO      0x23
#define IOCB_DATA_PTR_HI      0x24
#define IOCB_FLAGS1           0x25
#define IOCB_PAGE_COUNT       0x26
#define IOCB_WORD47B          0x27
#define IOCB_WORD50B          0x28
#define IOCB_WORD51B          0x29
#define IOCB_WORD52B          0x2A
#define IOCB_WORD53B          0x2B
#define IOCB_DOB_NEG_SECTORS  0x30
#define IOCB_DOB_HDR_ERROR    0x38
#define IOCB_DOB_LBL_ERROR    0x39
#define IOCB_DOB_DAT_ERROR    0x3A
#define IOCB_DOB_LAST_ERROR   0x3B
#define IOCB_DOB_CUR_CYL      0x3C
#define IOCB_DOB_HDR_CYL      0x3E
#define IOCB_DOB_HDR_SECHEAD  0x3F
#define IOCB_DOB_SECTOR_VALID 0x40
#define IOCB_DOB_DRIVE_STATUS 0x42
#define IOCB_DOB_WORD21       0x43
#define IOCB_DOB_FMT_TRACKS   0x44
#define IOCB_DOB_LABEL        0x45

#define LBL_FILE_ID           0
#define LBL_FILE_PAGE_LO      5
#define LBL_FILE_PAGE_HI      6
#define LBL_ATTRS_ALL_PAGES   7
#define LBL_WORDS             10

#define DEVST_OK_A            0x4100u
#define DEVST_OK_B            0x0000u
#define DEVST_PROTOCOL_A      0x6190u
#define DEVST_PROTOCOL_B      0x0000u
#define DEVST_NOTFOUND_A      0x6110u
#define DEVST_NOTFOUND_B      0x8000u
#define DEVST_LABELVFY_A      0x6110u
#define DEVST_LABELVFY_B      0x0800u
#define DEVST_DATAVFY_A       0x6110u
#define DEVST_DATAVFY_B       0x0080u
#define DEVST_ILLEGALCYL_A    0x6130u
#define DEVST_ILLEGALCYL_B    0x0000u

#define DCS_ADDRESS_MARK_OUT  0x1000u
#define DCS_NOT_TRACK0        0x0400u
#define DCS_NOT_WRITE_FAULT   0x0200u
#define DCS_READ_DATA_FOUND   0x0080u

#define IOCB_FLAG_INCREMENT_DATA_PTR 0x0080

#define OP_RESTORE            0
#define OP_FORMAT_TRACKS      1
#define OP_READ_DATA          2
#define OP_WRITE_DATA         3
#define OP_WRITE_LABEL_DATA   4
#define OP_READ_LABEL         5
#define OP_READ_LABEL_DATA    6
#define OP_VERIFY_DATA        7

#define ERR_NONE               0x0000
#define ERR_LABEL_VERIFY       0x0023
#define ERR_DATA_VERIFY        0x0033
#define ERR_SECTOR_NOT_FOUND   0x0081
#define ERR_ILLEGAL_OP         0x008A
#define ERR_CYLINDER_TOO_BIG   0x0082
#define ERR_PROTOCOL_VIOLATION 0x008C

#define VLO_VERIFY      0
#define VLO_UPDATE_DISK 1
#define VLO_NO_VERIFY   2

#define LABEL_OP_ON_READ    VLO_UPDATE_DISK
#define LABEL_OP_ON_WRITE   VLO_UPDATE_DISK
#define LABEL_OP_ON_VERIFY  VLO_VERIFY

#define DISK_SECTORS_PER_TRACK  16
static uint32_t disk_heads = 8;
#define DISK_HEADS              disk_heads

static void set_word_bool(uint32_t addr, int value) {
	iop_write(addr, (uint16_t)(value ? 0xFFFFu : 0x0000u));
}

static void set_hi_bool(uint32_t addr, int value) {
	uint16_t w = iop_read(addr);
	iop_write(addr, (uint16_t)((w & 0x00FFu) | (value ? 0xFF00u : 0x0000u)));
}

static void set_lo_bool(uint32_t addr, int value) {
	uint16_t w = iop_read(addr);
	iop_write(addr, (uint16_t)((w & 0xFF00u) | (value ? 0x00FFu : 0x0000u)));
}

static uint16_t vread(uint32_t vaddr) {
	uint32_t r = iop_xlat(vaddr);
	return r != IOP_XLAT_VACANT ? iop_read(r) : 0;
}

static void vwrite(uint32_t vaddr, uint16_t v) {
	uint32_t r = iop_xlat(vaddr);
	if (r != IOP_XLAT_VACANT) { iop_write(r, v); }
}

static void vset_hi_bool(uint32_t vaddr, int value) {
	uint16_t w = vread(vaddr);
	vwrite(vaddr, (uint16_t)((w & 0x00FFu) | (value ? 0xFF00u : 0x0000u)));
}

static void vset_lo_bool(uint32_t vaddr, int value) {
	uint16_t w = vread(vaddr);
	vwrite(vaddr, (uint16_t)((w & 0xFF00u) | (value ? 0x00FFu : 0x0000u)));
}

static uint32_t page_base(uint32_t vaddr) {
	uint32_t r = iop_xlat(vaddr & ~0xFFu);
	return r;
}

static void vread_run(uint32_t vaddr, uint16_t* d, int n) {
	uint32_t pb = IOP_XLAT_VACANT;
	for (int i = 0; i < n; i++, vaddr++) {
		if (i == 0 || (vaddr & 0xFFu) == 0) pb = page_base(vaddr);
		d[i] = pb != IOP_XLAT_VACANT ? iop_read(pb | (vaddr & 0xFFu)) : 0;
	}
}

static void vwrite_run(uint32_t vaddr, const uint16_t* d, int n) {
	uint32_t pb = IOP_XLAT_VACANT;
	for (int i = 0; i < n; i++, vaddr++) {
		if (i == 0 || (vaddr & 0xFFu) == 0) pb = page_base(vaddr);
		if (pb != IOP_XLAT_VACANT) iop_write(pb | (vaddr & 0xFFu), d[i]);
	}
}

static void vsector_to_mem(uint32_t vaddr, int n) {
	for (int i = 0; i < n; ) {
		uint32_t va  = vaddr + (uint32_t)i;
		int      run = 256 - (int)(va & 0xFFu);
		if (run > n - i) run = n - i;
		uint32_t pb  = page_base(va);
		if (pb != IOP_XLAT_VACANT)
			iop_sector_to_mem((uint32_t)i, pb | (va & 0xFFu), run);
		i += run;
	}
}

static int vmem_to_sector(uint32_t vaddr, int n) {
	uint32_t real[2], word[2], len[2];
	int pieces = 0;
	for (int i = 0; i < n; ) {
		uint32_t va  = vaddr + (uint32_t)i;
		int      run = 256 - (int)(va & 0xFFu);
		if (run > n - i) run = n - i;
		uint32_t pb  = page_base(va);
		if (pb == IOP_XLAT_VACANT) return 0;
		uint32_t r = pb | (va & 0xFFu);
		if (pieces == 2) return 0;
		real[pieces] = r; word[pieces] = (uint32_t)i; len[pieces] = (uint32_t)run;
		pieces++;
		i += run;
	}
	for (int k = 0; k < pieces; k++) iop_mem_to_sector(word[k], real[k], (int)len[k]);
	return 1;
}

#define OPIE_NIL                   0000
#define OPIE_VIRTUAL_WORD          0340
#define OPIE_VIRTUAL_FIRST64K      0341
#define OPIE_VIRTUAL_PAGE          0360

static long st_opie_unmodelled = 0;

static uint32_t opie_lp(uint16_t w0, uint16_t w1) {
	uint32_t lo   = bswap(w0);
	uint32_t hi   = (uint32_t)(w1 >> 8);
	uint16_t type = (uint16_t)(w1 & 0xFFu);
	switch (type) {
	case OPIE_NIL:              return 0;
	case OPIE_VIRTUAL_FIRST64K: return lo;
	case OPIE_VIRTUAL_WORD:     return lo | (hi << 16);
	case OPIE_VIRTUAL_PAGE:     return lo * 256u;
	default:
		st_opie_unmodelled++;
		return 0;
	}
}

static void opie_store_v(uint32_t at, uint32_t lp) {
	vwrite(at, bswap((uint16_t)(lp & 0xFFFFu)));
	if ((lp & 0xFFFF0000u) == 0) {
		vwrite(at + 1, (uint16_t)OPIE_VIRTUAL_FIRST64K);
	} else {
		vwrite(at + 1, (uint16_t)((((lp >> 16) & 0xFFu) << 8)
		                          | OPIE_VIRTUAL_WORD));
	}
}

static void iocb_finish(uint32_t iocb, int failed) {
	vset_hi_bool(iocb + IOCB_WORD52B, 1);
	vset_hi_bool(iocb + IOCB_WORD50B, failed ? 1 : 0);
}

static void set_device_status(uint32_t iocb, uint16_t a, uint16_t b) {
	vwrite(iocb + IOCB_DEV_STATUS_A, a);
	vwrite(iocb + IOCB_DEV_STATUS_B, b);
}

static long st_notifies = 0, st_claimed = 0, st_iocbs = 0;
static long st_sectors = 0, st_failed = 0, st_written = 0;
static long st_intrs = 0;
static uint16_t st_intr_mask = 0;

void iop_disk_stats(long* notifies, long* claimed, long* iocbs,
                    long* sectors, long* failed, long* written,
                    long* intrs, unsigned* intr_mask) {
	if (notifies)  { *notifies  = st_notifies; }
	if (claimed)   { *claimed   = st_claimed; }
	if (iocbs)     { *iocbs     = st_iocbs; }
	if (sectors)   { *sectors   = st_sectors; }
	if (failed)    { *failed    = st_failed; }
	if (written)   { *written   = st_written; }
	if (intrs)     { *intrs     = st_intrs; }
	if (intr_mask) { *intr_mask = st_intr_mask; }
}

static uint32_t label_get_page(uint32_t iocb) {
	uint32_t lo = bswap(vread(iocb + IOCB_DOB_LABEL + LBL_FILE_PAGE_LO));
	uint32_t hi = (vread(iocb + IOCB_DOB_LABEL + LBL_FILE_PAGE_HI) >> 8) & 0xFF;
	return (hi << 16) | lo;
}

static void label_set_page(uint32_t iocb, uint32_t page) {
	vwrite(iocb + IOCB_DOB_LABEL + LBL_FILE_PAGE_LO, bswap((uint16_t)(page & 0xFFFF)));
	uint16_t w = vread(iocb + IOCB_DOB_LABEL + LBL_FILE_PAGE_HI);
	vwrite(iocb + IOCB_DOB_LABEL + LBL_FILE_PAGE_HI,
	       (uint16_t)((w & 0x00FFu) | (((page >> 16) & 0xFFu) << 8)));
}

static int label_matches(uint32_t iocb, const uint16_t* on_disk) {
	if (on_disk[LBL_FILE_PAGE_HI] == 0
	    && (on_disk[LBL_ATTRS_ALL_PAGES] & 0xFF00u) == 0
	    && (vread(iocb + IOCB_DOB_LABEL + LBL_FILE_PAGE_HI) & 0x00FFu)
	         != (on_disk[LBL_ATTRS_ALL_PAGES] & 0x00FFu)) {
		return 0;
	}
	for (int i = 0; i < 5; i++) {
		if (vread(iocb + IOCB_DOB_LABEL + LBL_FILE_ID + (uint32_t)i) != on_disk[LBL_FILE_ID + i])
			return 0;
	}
	return vread(iocb + IOCB_DOB_LABEL + LBL_ATTRS_ALL_PAGES) == on_disk[LBL_ATTRS_ALL_PAGES];
}

static int ctrl_exact = -1;
static int ctrl_exact_on(void) {
#ifndef IOP_FIRMWARE
	if (ctrl_exact < 0) ctrl_exact = getenv("CTRL_EXACT") != NULL;
#else
	if (ctrl_exact < 0) ctrl_exact = 0;
#endif
	return ctrl_exact;
}

static int label_verify(uint32_t iocb, uint32_t sector, const uint16_t* on_disk, int policy) {
	if (label_matches(iocb, on_disk)) { return 0; }

	if (policy == VLO_VERIFY || sector == 0 || ctrl_exact_on()) {
		vwrite(iocb + IOCB_DOB_LBL_ERROR, bswap(ERR_LABEL_VERIFY));
		vwrite(iocb + IOCB_DOB_LAST_ERROR, bswap(ERR_LABEL_VERIFY));
		vset_lo_bool(iocb + IOCB_WORD50B, 1);
		return 1;
	}
	if (policy == VLO_UPDATE_DISK) {
		uint16_t lbl[LBL_WORDS];
		for (int i = 0; i < LBL_WORDS; i++)
			lbl[i] = vread(iocb + IOCB_DOB_LABEL + (uint32_t)i);
		iop_disk_write(sector, NULL, lbl);
		st_written++;
	}
	return 0;
}

static int disk_notify(uint16_t mask) {
	st_notifies++;

	uint32_t fcb = fcb_of(HANDLER_DISK);
	if (fcb == 0) { return 0; }

	if (mask != 0 && mask != iop_read(fcb + DFCB_WORK_MASK)) { return 0; }

	if (iop_disk_sectors() == 0) { return 0; }

	st_claimed++;

	if (iop_read(fcb + DFCB_MESA_CLEANUP_REQUEST) != 0) {
		set_word_bool(fcb + DFCB_STOPPED_MESA_CLEANUP, 1);
		return 1;
	}
	set_word_bool(fcb + DFCB_STOPPED_MESA_CLEANUP, 0);

	int force_protocol_violation = 0;
	if (iop_read(fcb + DFCB_START_HANDLER_MESA) != 0) {
		set_word_bool(fcb + DFCB_HANDLER_STOPPED_MESA, 0);
		set_word_bool(fcb + DFCB_START_HANDLER_MESA, 0);
	} else if (iop_read(fcb + DFCB_HANDLER_STOPPED_MESA) != 0) {
		force_protocol_violation = 1;
	}
	iop_write(fcb + DFCB_HANDLER_STATE, 0);
	iop_write(fcb + DFCB_UNEXPECTED_INTR, 0);
	iop_write(fcb + DFCB_UNEXPECTED_DMA_INTR, 0);

	for (int dcbNo = 0; dcbNo < 1; dcbNo++) {
		uint32_t dcb = fcb + DFCB_DCB0 + (uint32_t)dcbNo * DFCB_DCB_STRIDE;

		uint32_t iocb = bswap(iop_read(dcb + DCB_MESA_HEAD));

		int saw_iocb = 0;

		while (iocb != 0) {
			uint16_t data[256], label[LBL_WORDS];
			st_iocbs++;
			saw_iocb = 1;
			int failed = 0;

			vwrite(iocb + IOCB_DOB_HDR_ERROR, ERR_NONE);
			vwrite(iocb + IOCB_DOB_LBL_ERROR, ERR_NONE);
			vwrite(iocb + IOCB_DOB_DAT_ERROR, ERR_NONE);
			vwrite(iocb + IOCB_DOB_LAST_ERROR, ERR_NONE);
			vwrite(iocb + IOCB_DOB_DRIVE_STATUS, 0);
			vset_lo_bool(iocb + IOCB_WORD53B, 0);
			vset_lo_bool(iocb + IOCB_WORD50B, 0);
			set_device_status(iocb, DEVST_OK_A, DEVST_OK_B);

			if (force_protocol_violation) {
				vwrite(iocb + IOCB_DOB_LAST_ERROR, bswap(ERR_PROTOCOL_VIOLATION));
				set_device_status(iocb, DEVST_PROTOCOL_A, DEVST_PROTOCOL_B);
				vset_lo_bool(iocb + IOCB_WORD52B, 0);
				vset_hi_bool(iocb + IOCB_WORD52B, 1);
				vset_hi_bool(iocb + IOCB_WORD50B, 1);
				vset_lo_bool(iocb + IOCB_WORD50B, 0);
				st_failed++;
				iocb = bswap(vread(iocb + IOCB_MESA_NEXT));
				continue;
			}

			int op = (vread(iocb + IOCB_DOB_WORD21) >> 8) & 0xFF;

			if (op == OP_RESTORE) {
				iocb_finish(iocb, 0);
				iocb = bswap(vread(iocb + IOCB_MESA_NEXT));
				continue;
			}

			if (op == OP_FORMAT_TRACKS) {
				static const uint16_t zeros[256] = {0};
				uint32_t fcyl = bswap(vread(iocb + IOCB_DOB_HDR_CYL));
				uint32_t cyls = iop_disk_sectors() / (DISK_HEADS * DISK_SECTORS_PER_TRACK);
				uint32_t left = (uint16_t)(0u - bswap(vread(iocb + IOCB_DOB_FMT_TRACKS)));
				uint32_t s = fcyl * DISK_HEADS * DISK_SECTORS_PER_TRACK;
				int bad = fcyl >= cyls;
				while (!bad && left > 0 && s < cyls * DISK_HEADS * DISK_SECTORS_PER_TRACK) {
					for (int k = 0; k < DISK_SECTORS_PER_TRACK; k++, s++) {
						iop_disk_write(s, zeros, zeros);
						st_written++;
					}
					left--;
				}
				vwrite(iocb + IOCB_DOB_FMT_TRACKS, bswap((uint16_t)(0u - left)));
				if (bad || left > 0) {
					vwrite(iocb + IOCB_DOB_LAST_ERROR, bswap(ERR_CYLINDER_TOO_BIG));
					vset_lo_bool(iocb + IOCB_WORD50B, 1);
					set_device_status(iocb, DEVST_ILLEGALCYL_A, DEVST_ILLEGALCYL_B);
					st_failed++;
				}
				iocb_finish(iocb, bad || left > 0);
				if (bad || left > 0 || (vread(iocb + IOCB_WORD47B) & 0xFF00u) != 0)
					set_word_bool(fcb + DFCB_HANDLER_STOPPED_MESA, 1);
				iocb = bswap(vread(iocb + IOCB_MESA_NEXT));
				continue;
			}

			uint32_t cyl  = bswap(vread(iocb + IOCB_DOB_HDR_CYL));
			uint16_t hs   = vread(iocb + IOCB_DOB_HDR_SECHEAD);
			uint32_t sect = (hs >> 8) & 0xFF;
			uint32_t head = hs & 0xFF;

			uint32_t abs = ((cyl * DISK_HEADS) + head) * DISK_SECTORS_PER_TRACK + sect;
			uint32_t last_cyl_sect =
				((cyl * DISK_HEADS) + (DISK_HEADS - 1)) * DISK_SECTORS_PER_TRACK
				+ (DISK_SECTORS_PER_TRACK - 1);

			if (vread(iocb + IOCB_USE_BUFFER) != 0) {
				vwrite(iocb + IOCB_BUFFER_HIT, 0);
				vwrite(iocb + IOCB_DOB_LAST_ERROR, bswap(ERR_ILLEGAL_OP));
				vset_lo_bool(iocb + IOCB_WORD50B, 1);
				set_device_status(iocb, DEVST_PROTOCOL_A, DEVST_PROTOCOL_B);
				st_failed++;
				iocb_finish(iocb, 1);
				iocb = bswap(vread(iocb + IOCB_MESA_NEXT));
				continue;
			}

			uint32_t vdata = opie_lp(vread(iocb + IOCB_DATA_PTR_LO),
			                         vread(iocb + IOCB_DATA_PTR_HI));
			int increment = (vread(iocb + IOCB_FLAGS1) & IOCB_FLAG_INCREMENT_DATA_PTR) != 0;
			uint32_t pages = bswap(vread(iocb + IOCB_PAGE_COUNT));
			uint16_t neg_sectors = bswap(vread(iocb + IOCB_DOB_NEG_SECTORS));

			uint32_t label_page_base = label_get_page(iocb);
			uint32_t page_idx = 0;
#ifndef IOP_FIRMWARE
			if (getenv("DISK_TRACE") && atoi(getenv("DISK_TRACE")) >= 2) {
				fprintf(stderr, "DISK OP %d abs %u pages %u vdata %06X incr %d label",
				        op, abs, pages, vdata, increment);
				for (int k = 0; k < LBL_WORDS; k++)
					fprintf(stderr, " %04X", vread(iocb + IOCB_DOB_LABEL + (uint32_t)k));
				fprintf(stderr, " data0 %04X %04X\n", vread(vdata), vread(vdata + 1));
			}
#endif

			while (pages > 0) {
				if (abs >= iop_disk_sectors()) {
					vwrite(iocb + IOCB_DOB_LAST_ERROR, bswap(ERR_SECTOR_NOT_FOUND));
					vset_lo_bool(iocb + IOCB_WORD50B, 1);
					set_device_status(iocb, DEVST_NOTFOUND_A, DEVST_NOTFOUND_B);
					failed = 1;
					break;
				}
				if (!iop_disk_read(abs, op == OP_VERIFY_DATA ? data : NULL, label)) {
					failed = 1; break;
				}
				st_sectors++;

				label_set_page(iocb, label_page_base + page_idx);

				switch (op) {
				case OP_READ_DATA:
					failed = label_verify(iocb, abs, label, LABEL_OP_ON_READ);
					vsector_to_mem(vdata, 256);
					break;

				case OP_READ_LABEL:
					vwrite_run(iocb + IOCB_DOB_LABEL, label, LBL_WORDS);
					break;

				case OP_READ_LABEL_DATA:
					vwrite_run(iocb + IOCB_DOB_LABEL, label, LBL_WORDS);
					vsector_to_mem(vdata, 256);
					break;

				case OP_WRITE_DATA: {
					failed = label_verify(iocb, abs, label, LABEL_OP_ON_WRITE);
					if (failed && ctrl_exact_on()) break;
					if (vmem_to_sector(vdata, 256))
						iop_disk_write_sector(abs, NULL);
					else {
						uint16_t out[256];
						vread_run(vdata, out, 256);
						iop_disk_write(abs, out, NULL);
					}
					st_written++;
					break;
				}

				case OP_WRITE_LABEL_DATA: {
					uint16_t lbl[LBL_WORDS];
					vread_run(iocb + IOCB_DOB_LABEL, lbl, LBL_WORDS);
					if (vmem_to_sector(vdata, 256))
						iop_disk_write_sector(abs, lbl);
					else {
						uint16_t out[256];
						vread_run(vdata, out, 256);
						iop_disk_write(abs, out, lbl);
					}
					st_written++;
					break;
				}

				case OP_VERIFY_DATA: {
#ifndef IOP_FIRMWARE
					if (!getenv("VERIFY_NOLABEL"))
#endif
					failed = label_verify(iocb, abs, label, LABEL_OP_ON_VERIFY);
#ifndef IOP_FIRMWARE
					if (getenv("VERIFY_PASS")) { failed = 0; break; }
#endif
					for (int i = 0; i < 256; i++) {
						if (vread(vdata + (uint32_t)i) != data[i]) {
#ifndef IOP_FIRMWARE
							if (getenv("DISK_TRACE")) {
								fprintf(stderr, "DISK VERIFY sector %u: first difference at word %d, memory %04X disk %04X\n  memory:",
								        abs, i, vread(vdata + (uint32_t)i), data[i]);
								for (int k = 0; k < 256; k++)
									fprintf(stderr, "%s%04X", (k % 16) ? " " : "\n  ", vread(vdata + (uint32_t)k));
								fprintf(stderr, "\n  disk:");
								for (int k = 0; k < 256; k++)
									fprintf(stderr, "%s%04X", (k % 16) ? " " : "\n  ", data[k]);
								fprintf(stderr, "\n");
							}
#endif
#ifndef IOP_FIRMWARE
							if (getenv("VERIFY_DATAFIELD") || ctrl_exact_on())
								vwrite(iocb + IOCB_DOB_DAT_ERROR, bswap(ERR_DATA_VERIFY));
							else
#endif
							vwrite(iocb + IOCB_DOB_LBL_ERROR, bswap(ERR_DATA_VERIFY));
							vwrite(iocb + IOCB_DOB_LAST_ERROR, bswap(ERR_DATA_VERIFY));
							vset_lo_bool(iocb + IOCB_WORD50B, 1);
							failed = 1;
							break;
						}
					}
					break;
				}

				default:
					vwrite(iocb + IOCB_DOB_LAST_ERROR, bswap(ERR_ILLEGAL_OP));
					vset_lo_bool(iocb + IOCB_WORD50B, 1);
					set_device_status(iocb, DEVST_PROTOCOL_A, DEVST_PROTOCOL_B);
					failed = 1;
					pages = 1;
					break;
				}

				vwrite(iocb + IOCB_DOB_HDR_CYL,
				       bswap((uint16_t)(abs / (DISK_HEADS * DISK_SECTORS_PER_TRACK))));
				vwrite(iocb + IOCB_DOB_HDR_SECHEAD,
				       (uint16_t)(((abs % DISK_SECTORS_PER_TRACK) << 8)
				                  | ((abs / DISK_SECTORS_PER_TRACK) % DISK_HEADS)));

				page_idx++;
				abs++;
				pages--;
				neg_sectors++;
				if (increment) {
					vdata += 256;
					opie_store_v(iocb + IOCB_DATA_PTR_LO, vdata);
				}
			}

			if (failed) { st_failed++; }
#ifndef IOP_FIRMWARE
			if (failed && getenv("DISK_TRACE")) {
				fprintf(stderr, "DISK FAIL op %d c/h/s %u/%u/%u abs %u left %u err %04X lbl %04X; label:",
				        op, cyl, head, sect, abs, pages,
				        bswap(vread(iocb + IOCB_DOB_LAST_ERROR)),
				        bswap(vread(iocb + IOCB_DOB_LBL_ERROR)));
				for (int i = 0; i < LBL_WORDS; i++)
					fprintf(stderr, " %04X", vread(iocb + IOCB_DOB_LABEL + (uint32_t)i));
				fprintf(stderr, " | disk:");
				for (int i = 0; i < LBL_WORDS; i++) fprintf(stderr, " %04X", label[i]);
				fprintf(stderr, "\n  iocb v%06X:", iocb);
				for (uint32_t i = 0; i < 0x50; i++)
					fprintf(stderr, "%s%04X", (i % 16) ? " " : "\n  ", vread(iocb + i));
				fprintf(stderr, "\n");
			}
#endif
			vwrite(iocb + IOCB_PAGE_COUNT, bswap((uint16_t)pages));
			vwrite(iocb + IOCB_DOB_NEG_SECTORS, bswap(neg_sectors));
			vwrite(iocb + IOCB_DOB_CUR_CYL,
			       bswap((uint16_t)((abs > last_cyl_sect) ? cyl + 1 : cyl)));
			vwrite(iocb + IOCB_DOB_SECTOR_VALID, 0xFFFF);
			vwrite(iocb + IOCB_DOB_DRIVE_STATUS,
			       (uint16_t)(DCS_ADDRESS_MARK_OUT | DCS_NOT_WRITE_FAULT
			                  | DCS_READ_DATA_FOUND
			                  | ((cyl != 0 || head != 0) ? DCS_NOT_TRACK0 : 0)));
			iocb_finish(iocb, failed);

			if (failed || (vread(iocb + IOCB_WORD47B) & 0xFF00u) != 0) {
				set_word_bool(fcb + DFCB_HANDLER_STOPPED_MESA, 1);
			}

			iocb = bswap(vread(iocb + IOCB_MESA_NEXT));
		}

		if (saw_iocb) {
			st_intr_mask = iop_read(dcb + DCB_MESA_COND_MASK_VALUE);
			st_intrs++;
			post_wake(st_intr_mask);
		}
	}
	return 1;
}

#define HANDLER_ETHERNET        4

#define EFCB_OUT_QUEUE_HEAD     0
#define EFCB_IN_QUEUE_HEAD      6
#define EFCB_CLIENT_STATE_REQ  12
#define EFCB_OUT_WORK_MASK     21
#define EFCB_IN_WORK_MASK      22
#define EFCB_IN_CLIENT_STATE   24
#define EFCB_OUT_CLIENT_STATE  25

#define EIOCB_NEXT              0
#define EIOCB_COND_MASK_VALUE   4
#define EIOCB_I586_STATUS       5
#define EIOCB_W6                6
#define EIOCB_IO_ADDRESS        7
#define EIOCB_IO_LENGTH         9
#define EIOCB_IO_COUNT         10

#define EW6_DONE            0x8000u
#define EW6_HANDLED         0x4000u
#define EW6_OKAY            0x2000u
#define EW6_FRAME_TOO_LONG  0x1000u
#define EW6_OPTYPE          0x00F0u
#define EW6_DONT_PROCESS    0x0008u

#define EOP_COMMAND   0
#define EOP_OUTPUT    1
#define EOP_RESET     2
#define EOP_STARTRU   3
#define EOP_INPUT    15

#define CLIENT_OFF    0
#define CLIENT_ON     1

#define STATUS_TRANSMIT_NONE    0x8000u
#define STATUS_TRANSMIT_OTHER   0x9010u
#define EIOCB_WALK_LIMIT        64

static long st_eth_notifies = 0, st_eth_iocbs = 0, st_eth_out = 0,
            st_eth_resets = 0, st_eth_inputs = 0;

static uint32_t eth_rx[EIOCB_WALK_LIMIT];
static int      eth_rx_n = 0;

static int eth_rx_known(uint32_t iocb) {
	for (int i = 0; i < eth_rx_n; i++) { if (eth_rx[i] == iocb) { return 1; } }
	return 0;
}

#define TIME_REPLY_WORDS 37
static uint16_t eth_reply[TIME_REPLY_WORDS];
static int      eth_reply_pending = 0;
static long     st_eth_replies = 0;

static void time_service_send(uint32_t buf) {
	if (vread(buf + 0) != 0xFFFF || vread(buf + 1) != 0xFFFF
	    || vread(buf + 2) != 0xFFFF || vread(buf + 6) != 0x0600)
		return;
	if (vread(buf + 15) != 0x0008 || vread(buf + 9) != 0x0004)
		return;
	if (vread(buf + 24) != 0x0001 || vread(buf + 25) != 0x0002
	    || vread(buf + 26) != 0x0001)
		return;

	uint16_t* b = eth_reply;
	b[0] = vread(buf + 3); b[1] = vread(buf + 4); b[2] = vread(buf + 5);
	b[3] = 0x1000; b[4] = 0x1A33; b[5] = 0x3333;
	b[6] = 0x0600;
	b[7] = 0xFFFF;
	b[8] = 60;
	b[9] = 4;
	for (int i = 0; i < 6; i++) { b[10 + i] = vread(buf + 16 + i); }
	b[16] = 0x0004; b[17] = 0x0001;
	b[18] = 0x1000; b[19] = 0x1A33; b[20] = 0x3333;
	b[21] = 8;
	b[22] = vread(buf + 22); b[23] = vread(buf + 23);
	b[24] = 1;
	b[25] = 2;
	b[26] = 2;
	uint32_t t = gmt_now();
	b[27] = (uint16_t)(t >> 16);
	b[28] = (uint16_t)(t & 0xFFFFu);
	b[29] = 1; b[30] = 0; b[31] = 0;
	b[32] = 0; b[33] = 0;
	b[34] = 1;
	b[35] = 0; b[36] = 0;
	eth_reply_pending = 1;
}

static void time_service_deliver(void) {
	if (!eth_reply_pending || eth_rx_n == 0)
		return;
	uint32_t iocb = eth_rx[0];
	for (int i = 1; i < eth_rx_n; i++) { eth_rx[i - 1] = eth_rx[i]; }
	eth_rx_n--;
	eth_reply_pending = 0;

	uint32_t buf = opie_lp(vread(iocb + EIOCB_IO_ADDRESS),
	                       vread(iocb + EIOCB_IO_ADDRESS + 1));
	unsigned cap = bswap(vread(iocb + EIOCB_IO_LENGTH));
	unsigned pkt = 2u * TIME_REPLY_WORDS;
	unsigned trf = pkt < cap ? pkt : cap;
	unsigned wlen = (trf + 1) / 2;
	for (unsigned i = 0; i < wlen; i++) { vwrite(buf + i, eth_reply[i]); }
	vwrite(iocb + EIOCB_IO_COUNT, bswap((uint16_t)(wlen * 2)));

	uint16_t w6 = vread(iocb + EIOCB_W6);
	if (trf == pkt) {
		w6 = (uint16_t)(w6 | EW6_OKAY);
	} else {
		w6 = (uint16_t)((w6 & ~EW6_OKAY) | EW6_FRAME_TOO_LONG);
	}
	vwrite(iocb + EIOCB_W6, (uint16_t)(w6 | EW6_DONE | EW6_HANDLED));
	st_eth_replies++;
#ifndef IOP_FIRMWARE
	if (getenv("ETH_TRACE")) {
		fprintf(stderr, "ETH IN  iocb v%06X buf v%06X cap %u sent %u w6 %04X mask %04X left %d; iocb:",
		        iocb, buf, cap, wlen * 2, vread(iocb + EIOCB_W6),
		        vread(iocb + EIOCB_COND_MASK_VALUE), eth_rx_n);
		for (uint32_t i = 0; i < 12; i++) fprintf(stderr, " %04X", vread(iocb + i));
		fprintf(stderr, "\n");
	}
#endif
	post_wake(vread(iocb + EIOCB_COND_MASK_VALUE));
}

static int eth_has_work(uint32_t fcb) {
	uint16_t req = iop_read(fcb + EFCB_CLIENT_STATE_REQ);
	if (iop_read(fcb + EFCB_IN_CLIENT_STATE) != req
	    || iop_read(fcb + EFCB_OUT_CLIENT_STATE) != req) { return 1; }

	uint32_t iocb = opie_lp(iop_read(fcb + EFCB_OUT_QUEUE_HEAD),
	                        iop_read(fcb + EFCB_OUT_QUEUE_HEAD + 1));
	for (int n = 0; iocb != 0 && n < EIOCB_WALK_LIMIT; n++) {
		uint16_t w6 = vread(iocb + EIOCB_W6);
		if (!(w6 & EW6_DONT_PROCESS) && !(w6 & EW6_HANDLED)) { return 1; }
		iocb = opie_lp(vread(iocb + EIOCB_NEXT), vread(iocb + EIOCB_NEXT + 1));
	}
	iocb = opie_lp(iop_read(fcb + EFCB_IN_QUEUE_HEAD),
	               iop_read(fcb + EFCB_IN_QUEUE_HEAD + 1));
	for (int n = 0; iocb != 0 && n < EIOCB_WALK_LIMIT; n++) {
		uint16_t w6 = vread(iocb + EIOCB_W6);
		if (!(w6 & EW6_DONT_PROCESS)
		    && ((w6 & EW6_OPTYPE) >> 4) == EOP_INPUT
		    && !eth_rx_known(iocb)) { return 1; }
		iocb = opie_lp(vread(iocb + EIOCB_NEXT), vread(iocb + EIOCB_NEXT + 1));
	}
	return 0;
}

static int ethernet_notify(uint16_t mask) {
	uint32_t fcb = fcb_of(HANDLER_ETHERNET);
	if (fcb == 0) { return 0; }

	uint16_t out_mask = iop_read(fcb + EFCB_OUT_WORK_MASK);
	uint16_t in_mask  = iop_read(fcb + EFCB_IN_WORK_MASK);

	if (mask != 0 && mask != out_mask && mask != in_mask) { return 0; }
	if (mask == 0 && !eth_has_work(fcb)) { return 0; }
	st_eth_notifies++;

	if (iop_read(fcb + EFCB_CLIENT_STATE_REQ) == CLIENT_OFF) {
		iop_write(fcb + EFCB_IN_CLIENT_STATE, CLIENT_OFF);
		iop_write(fcb + EFCB_OUT_CLIENT_STATE, CLIENT_OFF);
		eth_rx_n = 0;
		eth_reply_pending = 0;
		return 1;
	}
	iop_write(fcb + EFCB_IN_CLIENT_STATE, CLIENT_ON);
	iop_write(fcb + EFCB_OUT_CLIENT_STATE, CLIENT_ON);

	uint32_t iocb = opie_lp(iop_read(fcb + EFCB_IN_QUEUE_HEAD),
	                        iop_read(fcb + EFCB_IN_QUEUE_HEAD + 1));
	for (int n = 0; iocb != 0 && n < EIOCB_WALK_LIMIT; n++) {
		uint16_t w6 = vread(iocb + EIOCB_W6);
		uint32_t next = opie_lp(vread(iocb + EIOCB_NEXT),
		                        vread(iocb + EIOCB_NEXT + 1));
		if (!(w6 & EW6_DONT_PROCESS)
		    && ((w6 & EW6_OPTYPE) >> 4) == EOP_INPUT
		    && !eth_rx_known(iocb) && eth_rx_n < EIOCB_WALK_LIMIT) {
			eth_rx[eth_rx_n++] = iocb;
			vwrite(iocb + EIOCB_W6,
			       (uint16_t)(w6 & ~(EW6_DONE | EW6_HANDLED)));
			st_eth_inputs++;
		}
		iocb = next;
	}
	time_service_deliver();

	uint16_t wake = 0;
	iocb = opie_lp(iop_read(fcb + EFCB_OUT_QUEUE_HEAD),
	               iop_read(fcb + EFCB_OUT_QUEUE_HEAD + 1));
	for (int n = 0; iocb != 0 && n < EIOCB_WALK_LIMIT; n++) {
		uint16_t w6 = vread(iocb + EIOCB_W6);
		uint32_t next = opie_lp(vread(iocb + EIOCB_NEXT),
		                        vread(iocb + EIOCB_NEXT + 1));
		if (w6 & EW6_DONT_PROCESS) { iocb = next; continue; }

		int okay = 0;
		switch ((w6 & EW6_OPTYPE) >> 4) {
		case EOP_OUTPUT: {
			uint32_t buf = opie_lp(vread(iocb + EIOCB_IO_ADDRESS),
			                       vread(iocb + EIOCB_IO_ADDRESS + 1));
			uint16_t len = bswap(vread(iocb + EIOCB_IO_LENGTH));
			vwrite(iocb + EIOCB_I586_STATUS, (uint16_t)STATUS_TRANSMIT_NONE);
			if (buf == 0 || len == 0) {
				vwrite(iocb + EIOCB_I586_STATUS, (uint16_t)STATUS_TRANSMIT_OTHER);
				okay = 0;
			} else {
				w6 = (uint16_t)(w6 & ~EW6_FRAME_TOO_LONG);
				vwrite(iocb + EIOCB_IO_COUNT, bswap(len));
				wake |= vread(iocb + EIOCB_COND_MASK_VALUE);
				okay = 1;
#ifndef IOP_FIRMWARE
				if (getenv("ETH_TRACE")) {
					fprintf(stderr, "ETH OUT v%06X len %u:", buf, len);
					for (uint32_t i = 0; i < 40 && i < (len + 1u) / 2; i++)
						fprintf(stderr, "%s%04X", (i % 16) ? " " : "\n  ", vread(buf + i));
					fprintf(stderr, "\n");
				}
#endif
				time_service_send(buf);
			}
			st_eth_out++;
			break;
		}
		case EOP_RESET:
			iop_write(fcb + EFCB_IN_CLIENT_STATE, CLIENT_OFF);
			iop_write(fcb + EFCB_OUT_CLIENT_STATE, CLIENT_OFF);
			eth_rx_n = 0;
			eth_reply_pending = 0;
			okay = 1;
			st_eth_resets++;
			break;
		case EOP_COMMAND:
		case EOP_STARTRU:
			okay = 1;
			break;
		default:
			okay = 0;
			break;
		}
		w6 = (uint16_t)((w6 & ~EW6_OKAY) | (okay ? EW6_OKAY : 0)
		                | EW6_DONE | EW6_HANDLED);
		vwrite(iocb + EIOCB_W6, w6);
		st_eth_iocbs++;
		iocb = next;
	}
	if (wake) { post_wake(wake); }
	time_service_deliver();
	return 1;
}

void iop_eth_stats(long* notifies, long* iocbs, long* outputs, long* resets,
                   long* inputs, long* replies, long* bad_ptr) {
	if (replies)  { *replies  = st_eth_replies; }
	if (notifies) { *notifies = st_eth_notifies; }
	if (iocbs)    { *iocbs    = st_eth_iocbs; }
	if (outputs)  { *outputs  = st_eth_out; }
	if (resets)   { *resets   = st_eth_resets; }
	if (inputs)   { *inputs   = st_eth_inputs; }
	if (bad_ptr)  { *bad_ptr  = st_opie_unmodelled; }
}

#define LOCK_ADD              0
#define LOCK_AND              1
#define LOCK_OR               2
#define LOCK_XCHG             3
#define LOCK_OVERWRITE_IF_NIL 4

uint16_t iop_lockmem(uint16_t operation, uint16_t offset,
                     uint16_t value, uint16_t mask) {
	uint32_t addr = (IOP_IOR_BASE & 0xFF0000u)
	              | ((IOP_IOR_BASE + (uint32_t)offset) & 0xFFFFu);
	uint16_t old  = iop_read(addr);
	uint16_t nw;

	switch (operation) {
	case LOCK_ADD:  nw = (uint16_t)(old + value); break;
	case LOCK_AND:  nw = (uint16_t)(old & value); break;
	case LOCK_OR:   nw = (uint16_t)(old | value); break;
	case LOCK_XCHG: nw = value; break;
	case LOCK_OVERWRITE_IF_NIL: nw = old ? old : value; break;
	default:
		st_lock_bad++;
		return old;
	}

	iop_write(addr, nw);
	st_lock_count[operation & 7]++;
	st_lock_last_mask = mask;

	return old;
}

void iop_lock_stats(long* counts, long* bad, unsigned* last_mask) {
	for (int i = 0; i < 8; i++) { if (counts) { counts[i] = st_lock_count[i]; } }
	if (bad)       { *bad       = st_lock_bad; }
	if (last_mask) { *last_mask = st_lock_last_mask; }
}

#define HANDLER_BEEP        1
#define BFCB_FREQUENCY     11

static uint16_t beep_div;
static long     st_beeps = 0;

static int beep_notify(void) {
	uint32_t fcb = fcb_of(HANDLER_BEEP);
	if (fcb == 0) { return 0; }
	uint16_t d = bswap(iop_read(fcb + BFCB_FREQUENCY));
	if (d == beep_div) { return 0; }
	beep_div = d;
	if (d != 0) st_beeps++;
	iop_beep(d);
	return 1;
}

long iop_beep_count(void) { return st_beeps; }

#define HANDLER_FLOPPY       5
#define FFCB_W18            18
#define FFCB_W19            19
#define FFCB_WORK_MASK      26
#define FFCB_PILOT_QUEUE    37
#define FFCB_PILOT_NEXT     41
#define FFCB_DCB0           49
#define FFCB_QUEUE_SEM     115

#define FDCB_FLAGS           4
#define   FDF_READY          0x8000u
#define   FDF_DISK_CHANGE    0x4000u
#define   FDF_TWO_SIDED      0x2000u
#define FDCB_W5              5
#define FDCB_PILOT_CHANGED   7
#define FDCB_DOOR_OPEN      10
#define FDCB_STATUS3        11
#define   FST3_KEEP          0x03FFu
#define   FST3_NO_FLOPPY     0x5800u
#define   FST3_FLOPPY        0x7800u

#define FIOCB_GEN_OP         8
#define FIOCB_TRIES         10
#define FIOCB_STATE         11
#define FIOCB_NEXT          12
#define FIOCB_DATA          14
#define FIOCB_COND_MASK     18
#define FIOCB_DRIVE         22
#define FIOCB_FIRST         23
#define FIOCB_FINAL_DMA     33
#define FIOCB_NCMDS         35
#define FIOCB_CURCMD        36
#define FIOCB_CMDS          37
#define FIOCB_MIDDLE        78
#define FIOCB_LAST          88
#define FTRK_TOTAL           0
#define FTRK_ACTUAL          1
#define FCMD_WORDS          13
#define FCMD_CODE            0
#define FCMD_NCMD            2
#define FCMD_BYTES           3
#define FCMD_NRES            8
#define FCMD_RESULT          9

#define FDC_NULL             0
#define FDC_READ_DATA        2
#define FOP_INVALID          1
#define FOP_ABORTED          5
#define FOP_COMPLETED        6
#define FOP_FAILED           7

#define FL_DOOR_RETRACES    20
#define FL_TRACKS          168
#define FL_WALK_LIMIT       32
#define FL_NONE              0
#define FL_IMD               1
#define FL_DMK               2

static long st_floppy_notifies = 0, st_floppy_iocbs = 0, st_floppy_sectors = 0;
static long st_floppy_missing = 0, st_floppy_changes = 0;

static uint32_t fl_info;
static int      fl_started;
static int      fl_wait;
static int      fl_kind;
static uint32_t fl_bytes;
static uint32_t imd_trk[FL_TRACKS];
static uint32_t imd_scan;
static uint32_t dmk_tlen, dmk_tracks, dmk_sides, dmk_flags;

static uint32_t fl_cblk = 0xFFFFFFFFu;
static uint8_t  fl_cbuf[512];

static unsigned fl_byte(uint32_t off) {
	uint32_t b = off >> 9;
	if (b != fl_cblk) {
		if (off >= fl_bytes || !iop_floppy_block(b, fl_cbuf)) return 0;
		fl_cblk = b;
	}
	return fl_cbuf[off & 511u];
}

static int floppy_kind(void) {
	fl_bytes = (fl_info & 0x00FFFFFFu) << 9;
	fl_cblk = 0xFFFFFFFFu;
	if (fl_bytes == 0) return FL_NONE;
	if (fl_byte(0) == 'I' && fl_byte(1) == 'M' && fl_byte(2) == 'D') {
		for (uint32_t i = 0; i < 4096 && i < fl_bytes; i++)
			if (fl_byte(i) == 0x1Au) {
				for (int t = 0; t < FL_TRACKS; t++) imd_trk[t] = 0;
				imd_scan = i + 1;
				return FL_IMD;
			}
		return FL_NONE;
	}
	dmk_tracks = fl_byte(1);
	dmk_tlen   = fl_byte(2) | (fl_byte(3) << 8);
	dmk_flags  = fl_byte(4);
	dmk_sides  = (dmk_flags & 0x10u) ? 1 : 2;
	if ((fl_byte(0) == 0x00 || fl_byte(0) == 0xFF) && dmk_tracks >= 35
	    && dmk_tracks <= 96 && dmk_tlen > 0x80 && dmk_tlen <= 0x4000)
		return FL_DMK;
	return FL_NONE;
}

static uint32_t imd_rec_len(unsigned type, uint32_t size) {
	if (type == 0) return 1;
	if (type > 8) return 0;
	return (type & 1u) ? 1 + size : 2;
}

static uint32_t imd_next(uint32_t p) {
	if (p + 5 > fl_bytes) return 0;
	unsigned head = fl_byte(p + 2), nsec = fl_byte(p + 3), sz = fl_byte(p + 4);
	if (nsec == 0 || sz > 6) return 0;
	uint32_t size = 128u << sz;
	uint32_t q = p + 5 + nsec * (1u + ((head & 0x80u) ? 1u : 0u) + ((head & 0x40u) ? 1u : 0u));
	for (unsigned i = 0; i < nsec; i++) {
		uint32_t n = imd_rec_len(fl_byte(q), size);
		if (n == 0) return 0;
		q += n;
	}
	return q < fl_bytes ? q : 0;
}

static uint32_t imd_track(unsigned cyl, unsigned head) {
	uint32_t t = cyl * 2u + head;
	if (t >= FL_TRACKS) return 0;
	while (imd_trk[t] == 0 && imd_scan != 0) {
		uint32_t p = imd_scan;
		imd_scan = imd_next(p);
		if (p + 5 <= fl_bytes && fl_byte(p + 3) != 0) {
			uint32_t u = fl_byte(p + 1) * 2u + (fl_byte(p + 2) & 1u);
			if (u < FL_TRACKS && imd_trk[u] == 0) imd_trk[u] = p + 1;
		}
	}
	return imd_trk[t];
}

struct fl_sector { uint32_t off, step, fill, size, count; };

static int floppy_find(unsigned cyl, unsigned head, unsigned sect, struct fl_sector* s) {
	if (fl_kind == FL_IMD) {
		uint32_t p = imd_track(cyl, head);
		if (p-- == 0) return 0;
		unsigned h = fl_byte(p + 2), nsec = fl_byte(p + 3);
		uint32_t size = 128u << fl_byte(p + 4);
		uint32_t q = p + 5 + nsec * (1u + ((h & 0x80u) ? 1u : 0u) + ((h & 0x40u) ? 1u : 0u));
		for (unsigned i = 0; i < nsec; i++) {
			unsigned type = fl_byte(q);
			if (fl_byte(p + 5 + i) == sect) {
				if (type == 0 || type > 8) return 0;
				s->off = q + 1; s->step = 1; s->fill = !(type & 1u);
				s->size = size; s->count = nsec;
				return 1;
			}
			q += imd_rec_len(type, size);
		}
		return 0;
	}
	if (fl_kind == FL_DMK) {
		if (head >= dmk_sides || cyl >= dmk_tracks) return 0;
		uint32_t base = 16 + (cyl * dmk_sides + head) * dmk_tlen;
		unsigned count = 0, found = 0;
		for (unsigned k = 0; k < 64; k++) {
			unsigned e = fl_byte(base + 2 * k) | (fl_byte(base + 2 * k + 1) << 8);
			if (e == 0) break;
			count++;
			if (found) continue;
			uint32_t step = (dmk_flags & 0xC0u) ? 1 : (e & 0x8000u) ? 1 : 2;
			uint32_t a = base + (e & 0x3FFFu);
			if (fl_byte(a) != 0xFEu || fl_byte(a + 3 * step) != sect) continue;
			uint32_t size = 128u << (fl_byte(a + 4 * step) & 3u);
			for (uint32_t q = a + 7 * step, n = 0; n < 60; n++, q += step) {
				unsigned m = fl_byte(q);
				if (m >= 0xF8u && m <= 0xFBu) {
					s->off = q + step; s->step = step; s->fill = 0; s->size = size;
					found = 1;
					break;
				}
			}
		}
		s->count = count;
		return found;
	}
	return 0;
}

static void floppy_door(uint32_t fcb, int in) {
	uint32_t d = fcb + FFCB_DCB0;
	iop_write(d + FDCB_W5, (uint16_t)(iop_read(d + FDCB_W5) & 0xFF00u));
	set_word_bool(d + FDCB_PILOT_CHANGED, in);
	set_word_bool(d + FDCB_DOOR_OPEN, !in);
	iop_write(d + FDCB_STATUS3, (uint16_t)((iop_read(d + FDCB_STATUS3) & FST3_KEEP)
	                                      | (in ? FST3_FLOPPY : FST3_NO_FLOPPY)));
}

static void floppy_refresh(void) {
	uint32_t fcb = fcb_of(HANDLER_FLOPPY);
	if (fcb == 0) return;
	uint32_t info = iop_floppy_info();
	if (!fl_started) {
		fl_started = 1;
		fl_info = info;
		fl_kind = floppy_kind();
		if (fl_kind != FL_NONE) floppy_door(fcb, 1);
		return;
	}
	if (info != fl_info) {
		fl_info = info;
		st_floppy_changes++;
		if (fl_kind != FL_NONE) floppy_door(fcb, 0);
		fl_kind = FL_NONE;
		fl_wait = FL_DOOR_RETRACES;
		return;
	}
	if (fl_wait != 0 && --fl_wait == 0) {
		fl_kind = floppy_kind();
		if (fl_kind != FL_NONE) floppy_door(fcb, 1);
	}
}

static void floppy_iocb(uint32_t iocb) {
	uint32_t n = bswap(vread(iocb + FIOCB_NCMDS));
	uint32_t ci = n == 0 ? 0 : n - 1 > 2 ? 2 : n - 1;
	uint32_t cmd = iocb + FIOCB_CMDS + FCMD_WORDS * ci;
	unsigned gen_op = vread(iocb + FIOCB_GEN_OP) >> 8;
	uint16_t b23 = vread(cmd + FCMD_BYTES + 1), b45 = vread(cmd + FCMD_BYTES + 2);
	unsigned cyl = b23 >> 8, head = b23 & 0xFFu, sect = b45 >> 8;
	unsigned words = (b45 & 0xFFu) == 0 ? 64 : (b45 & 0xFFu) == 1 ? 128 : 256;
	st_floppy_iocbs++;
#ifndef IOP_FIRMWARE
	if (getenv("FLOPPY_TRACE")) {
		fprintf(stderr, "FLOPPY IOCB v%06X op %u cmds %u c/h/s %u/%u/%u words %u:", iocb,
		        gen_op, n, cyl, head, sect, words);
		for (uint32_t i = 0; i < 97; i++)
			fprintf(stderr, "%s%04X", (i % 16) ? " " : "\n  ", vread(iocb + i));
		fprintf(stderr, "\n");
	}
#endif

	vwrite(iocb + FIOCB_CURCMD, bswap((uint16_t)(ci + 1)));
	uint16_t nc = vread(cmd + FCMD_NCMD);
	vwrite(cmd + FCMD_NCMD, (uint16_t)((nc & 0xFF00u) | (nc >> 8)));

	uint32_t want[3] = {
		bswap(vread(iocb + FIOCB_FIRST + FTRK_TOTAL)),
		bswap(vread(iocb + FIOCB_MIDDLE + FTRK_TOTAL)),
		bswap(vread(iocb + FIOCB_LAST + FTRK_TOTAL)) };
	uint32_t sectors = (want[0] + want[1] + want[2]) / (words * 2);

	unsigned state = FOP_INVALID;
	uint16_t w21 = vread(iocb + FIOCB_DRIVE);
	if ((w21 >> 8) == 0 && gen_op == FDC_NULL) {
		state = FOP_COMPLETED;
	} else if ((w21 >> 8) == 0 && gen_op == FDC_READ_DATA) {
		uint32_t lp = opie_lp(vread(iocb + FIOCB_DATA), vread(iocb + FIOCB_DATA + 1));
		uint32_t got = 0;
		unsigned st0 = 0, st1 = 0;
		while (sectors-- > 0) {
			struct fl_sector s;
			if (!floppy_find(cyl, head, sect, &s)) {
				st_floppy_missing++;
				st0 = 0x40; st1 = 0x04;
				break;
			}
			uint16_t buf[256];
			uint32_t m = s.size / 2 < words ? s.size / 2 : words;
			for (uint32_t i = 0; i < m; i++) {
				uint32_t o = s.fill ? s.off : s.off + 2 * i * s.step;
				unsigned hi = fl_byte(o), lo = s.fill ? hi : fl_byte(o + s.step);
				buf[i] = (uint16_t)((hi << 8) | lo);
			}
			vwrite_run(lp, buf, (int)m);
			got += 2 * m;
			lp += words;
			st_floppy_sectors++;
			sect++;
			if (cyl != 0 && sect > s.count) {
				sect = 1;
				if (head == 0) head = 1; else { head = 0; cyl++; }
			}
		}
		for (int k = 0; k < 3; k++) {
			uint32_t c = got < want[k] ? got : want[k];
			static const uint32_t at[3] = { FIOCB_FIRST, FIOCB_MIDDLE, FIOCB_LAST };
			vwrite(iocb + at[k] + FTRK_ACTUAL, bswap((uint16_t)c));
			got -= c;
			if (k == 0)
				vwrite(iocb + FIOCB_FINAL_DMA, bswap((uint16_t)(0x10000u - c)));
		}
		vwrite(cmd + FCMD_RESULT,     (uint16_t)((st0 << 8) | st1));
		vwrite(cmd + FCMD_RESULT + 1, (uint16_t)(cyl & 0xFFu));
		vwrite(cmd + FCMD_RESULT + 2, (uint16_t)((head << 8) | (sect & 0xFFu)));
		uint16_t nr = vread(cmd + FCMD_NRES);
		vwrite(cmd + FCMD_NRES, (uint16_t)((nr & 0xFF00u) | (nr >> 8)));
		state = FOP_COMPLETED;
	}
	uint16_t w11 = vread(iocb + FIOCB_STATE);
	vwrite(iocb + FIOCB_STATE, (uint16_t)((w11 & 0xFF00u) | state));
	uint16_t w10 = vread(iocb + FIOCB_TRIES);
	vwrite(iocb + FIOCB_TRIES, (uint16_t)((w10 & 0xFF00u) | 1u));
	vwrite(iocb + FIOCB_DRIVE, (uint16_t)(vread(iocb + FIOCB_DRIVE) & 0xFF00u));
	uint16_t mask = vread(iocb + FIOCB_COND_MASK);
	if (mask != 0) post_wake(mask);
}

static int floppy_pending(uint32_t iocb) {
	unsigned s = vread(iocb + FIOCB_STATE) & 0xFFu;
	return s != FOP_INVALID && s != FOP_ABORTED && s != FOP_COMPLETED && s != FOP_FAILED;
}

static int floppy_notify(uint16_t mask) {
	uint32_t fcb = fcb_of(HANDLER_FLOPPY);
	if (fcb == 0) { return 0; }
	if (mask != 0 && mask != iop_read(fcb + FFCB_WORK_MASK)) { return 0; }
	floppy_refresh();
	int stop    = (iop_read(fcb + FFCB_W18) & 0xFF00u) != 0;
	int stopped = (iop_read(fcb + FFCB_W19) & 0xFF00u) != 0;
	uint32_t head = opie_lp(iop_read(fcb + FFCB_PILOT_QUEUE), iop_read(fcb + FFCB_PILOT_QUEUE + 1));
	int work = 0;
	for (uint32_t p = head, n = 0; p != 0 && n < FL_WALK_LIMIT; n++) {
		if (floppy_pending(p)) { work = 1; break; }
		p = opie_lp(vread(p + FIOCB_NEXT), vread(p + FIOCB_NEXT + 1));
	}
	if (mask == 0 && stop == stopped && (stop || !work)) { return 0; }
	st_floppy_notifies++;

	uint16_t w19 = iop_read(fcb + FFCB_W19);
	if (stop) {
		iop_write(fcb + FFCB_W19, (uint16_t)(w19 | 0xFF00u));
		return 1;
	}
	if (stopped) {
		uint32_t f = fcb + FFCB_DCB0 + FDCB_FLAGS;
		uint16_t v = (uint16_t)(iop_read(f) & ~(FDF_READY | FDF_DISK_CHANGE | FDF_TWO_SIDED));
		if (fl_kind != FL_NONE) v |= FDF_READY | FDF_DISK_CHANGE | FDF_TWO_SIDED;
		iop_write(f, v);
	}
	iop_write(fcb + FFCB_W19, (uint16_t)(w19 & 0x00FFu));

	for (uint32_t p = head, n = 0; p != 0 && n < FL_WALK_LIMIT; n++) {
		if (mask != 0 || floppy_pending(p)) floppy_iocb(p);
		p = opie_lp(vread(p + FIOCB_NEXT), vread(p + FIOCB_NEXT + 1));
	}
	iop_write(fcb + FFCB_QUEUE_SEM, 0);
	return 1;
}

static uint16_t fl_qnext_seen;
static long     st_floppy_sem = 0;

static void floppy_lockrel(void) {
	uint32_t fcb = fcb_of(HANDLER_FLOPPY);
	if (fcb == 0) return;
	uint16_t qn = iop_read(fcb + FFCB_PILOT_NEXT);
	if (iop_read(fcb + FFCB_QUEUE_SEM) != 0 && qn != fl_qnext_seen) {
		iop_write(fcb + FFCB_QUEUE_SEM, 0);
		st_floppy_sem++;
	}
	fl_qnext_seen = qn;
}

void iop_floppy_stats(long* notifies, long* iocbs, long* sectors,
                      long* missing, long* changes, long* sem, int* kind) {
	if (notifies) { *notifies = st_floppy_notifies; }
	if (iocbs)    { *iocbs    = st_floppy_iocbs; }
	if (sectors)  { *sectors  = st_floppy_sectors; }
	if (missing)  { *missing  = st_floppy_missing; }
	if (changes)  { *changes  = st_floppy_changes; }
	if (sem)      { *sem      = st_floppy_sem; }
	if (kind)     { *kind     = fl_kind; }
}

#define HANDLER_DISPLAY          3
#define DSPFCB_CHNGD_INFO     0x0A
#define DSPFCB_CURSOR_PAT     0x11
#define MP_RUNNING          8000
#define DSP_TURN_ON         0x00F8u
#define DSP_DISPL_INFO      0x0008u
#define DSP_CURSOR_MAP      0x0040u
#define MP_REAL             0x050000u
#define MP_GERM_HANDED_OVER 919
#define MP_DEBUGGER_SWAP    935

static int  display_on = 0;
static int  mp_cursor_mode = 0;
static int  picture_blanked = 0;
static long st_display_changes = 0;

void iop_display_service(void) {
	floppy_lockrel();
	uint32_t fcb = fcb_of(HANDLER_DISPLAY);
	if (fcb == 0) { return; }
	uint16_t chg = iop_read(fcb + DSPFCB_CHNGD_INFO);
	if (chg == 0) { return; }
	st_display_changes++;
#ifndef IOP_FIRMWARE
	if (getenv("DISP_TRACE")) fprintf(stderr, "DISPLAY CHANGE %04X (on %d)\n", chg, display_on);
#endif
	if (chg == DSP_TURN_ON) {
		display_on = 1;
		picture_blanked = 0;
	} else if (chg & DSP_DISPL_INFO) {
		display_on = 0;
		mp_cursor_mode = 1;
		picture_blanked = 1;
	}
	if (chg & DSP_CURSOR_MAP) {
		for (uint32_t i = 0; i < 16; i++)
			if (iop_read(fcb + DSPFCB_CURSOR_PAT + i)) { mp_cursor_mode = 0; break; }
	}
	iop_write(fcb + DSPFCB_CHNGD_INFO, 0);
}

#define DISPLAY_QUIET_RETRACES 20
static long     dsp_io_seen;
static unsigned dsp_quiet;

static void display_resume_check(void) {
	uint16_t mp = bswap(iop_read(MP_REAL));
	long io = st_iocbs + st_floppy_iocbs;
	if (mp != MP_GERM_HANDED_OVER && mp != MP_DEBUGGER_SWAP) { dsp_quiet = 0; dsp_io_seen = io; return; }
	if (io != dsp_io_seen) { dsp_io_seen = io; dsp_quiet = 0; return; }
	if (++dsp_quiet >= DISPLAY_QUIET_RETRACES) { display_on = 1; mp_cursor_mode = 0; picture_blanked = 0; dsp_quiet = 0; }
}

#define DSPFCB_RETRACE_MASK   0x0D

#define DSPFCB_CURSOR_X       0x0E
#define DSPFCB_CURSOR_Y       0x0F

#define CURSOR_STALE_RETRACES 8

static uint16_t ms_x = 568, ms_y = 422;
static uint16_t cur_seen_x, cur_seen_y;
static uint16_t ms_seen_x, ms_seen_y;
static uint16_t cur_stale;
static int      cur_held;

static const uint8_t MP_FONT[10][7] = {
	{0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}, {0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
	{0x0E,0x11,0x01,0x02,0x04,0x08,0x1F}, {0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
	{0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}, {0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
	{0x06,0x08,0x10,0x1E,0x11,0x11,0x0E}, {0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
	{0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E}, {0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C},
};

static void mp_pattern(uint16_t* rows) {
	static const int X0[4] = { 0, 6, 2, 8 }, Y0[4] = { 0, 0, 8, 8 };
	uint16_t mp = bswap(iop_read(MP_REAL));
	for (int i = 0; i < 16; i++) rows[i] = 0;
	for (int d = 0, div = 1000; d < 4; d++, div /= 10) {
		unsigned digit = (unsigned)(mp / div) % 10u;
		for (int r = 0; r < 7; r++)
			rows[Y0[d] + r] |= (uint16_t)(MP_FONT[digit][r] << (11 - X0[d]));
	}
}

static void cursor_pattern(uint32_t fcb, uint16_t* rows) {
	if (mp_cursor_mode) { mp_pattern(rows); return; }
	for (uint32_t i = 0; i < 16; i++) rows[i] = iop_read(fcb + DSPFCB_CURSOR_PAT + i);
}

#define INPUTS_PER_RETRACE 3
static unsigned inputs_since_retrace;

void iop_cursor_follow(void) {
	uint32_t fcb = fcb_of(HANDLER_DISPLAY);
	if (fcb == 0) return;
	if (inputs_since_retrace < 0xFFFFu) inputs_since_retrace++;
	if (display_on && !mp_cursor_mode && !cur_held
	    && inputs_since_retrace <= INPUTS_PER_RETRACE) return;
	uint16_t rows[16];
	cursor_pattern(fcb, rows);
	iop_cursor(1, ms_x, ms_y, rows);
	cur_held = 1;
}

void iop_display_retrace(void) {
	floppy_refresh();
	uint32_t fcb = fcb_of(HANDLER_DISPLAY);
	inputs_since_retrace = 0;
	if (fcb == 0) { iop_cursor(0, 0, 0, NULL); return; }
	if (mp_cursor_mode && bswap(iop_read(MP_REAL)) == MP_RUNNING) mp_cursor_mode = 0;
	uint16_t rows[16];
	cursor_pattern(fcb, rows);
	uint16_t x = bswap(iop_read(fcb + DSPFCB_CURSOR_X));
	uint16_t y = bswap(iop_read(fcb + DSPFCB_CURSOR_Y));
	if (x != cur_seen_x || y != cur_seen_y) {
		cur_seen_x = x; cur_seen_y = y; cur_stale = 0; cur_held = 0;
		ms_seen_x = ms_x; ms_seen_y = ms_y;
	} else if ((ms_x != ms_seen_x || ms_y != ms_seen_y) && cur_stale < 0xFFFFu) {
		cur_stale++;
	}
	if (mp_cursor_mode || !display_on || cur_held || cur_stale > CURSOR_STALE_RETRACES) {
		x = ms_x; y = ms_y;
	}
	iop_picture_blank(picture_blanked);
	iop_cursor(1, x, y, rows);
	if (!display_on) display_resume_check();
	if (!display_on) return;
	uint16_t mask = iop_read(fcb + DSPFCB_RETRACE_MASK);
	if (mask != 0) { post_wake(mask); }
}

void iop_display_cursor(void) {
	uint32_t fcb = fcb_of(HANDLER_DISPLAY);
	if (fcb == 0) return;
	uint16_t rows[16];
	cursor_pattern(fcb, rows);
	uint16_t x = bswap(iop_read(fcb + DSPFCB_CURSOR_X));
	uint16_t y = bswap(iop_read(fcb + DSPFCB_CURSOR_Y));
	if (mp_cursor_mode || !display_on || cur_held || cur_stale > CURSOR_STALE_RETRACES) {
		x = ms_x; y = ms_y;
	}
	iop_picture_blank(picture_blanked);
	iop_cursor(1, x, y, rows);
}

void iop_display_stats(long* changes, int* on) {
	if (changes) { *changes = st_display_changes; }
	if (on)      { *on = display_on; }
}

#define HANDLER_KEYMOUSE  6
#define KMFCB_MOUSE_X     16
#define KMFCB_MOUSE_Y     17
#define KMFCB_KB_BASE     18
#define KMFCB_KB_WORDS    9

static long st_mouse_moves;

void iop_mouse_set(uint16_t x, uint16_t y) {
	ms_x = x; ms_y = y;
	uint32_t fcb = fcb_of(HANDLER_KEYMOUSE);
	if (fcb == 0) { return; }
	iop_write(fcb + KMFCB_MOUSE_X, x);
	iop_write(fcb + KMFCB_MOUSE_Y, y);
	st_mouse_moves++;
}

void iop_key_set(int word, int bit, int pressed) {
	uint32_t fcb = fcb_of(HANDLER_KEYMOUSE);
	if (fcb == 0 || word < 0 || word >= KMFCB_KB_WORDS || bit < 0 || bit > 15) {
		return;
	}
	uint16_t m = (uint16_t)(0x8000u >> bit);
	uint16_t v = iop_read(fcb + KMFCB_KB_BASE + (uint32_t)word);
	iop_write(fcb + KMFCB_KB_BASE + (uint32_t)word,
	          pressed ? (uint16_t)(v & ~m) : (uint16_t)(v | m));
}

long iop_mouse_moves(void) { return st_mouse_moves; }

#define HANDLER_SYSCONF   19
#define SFCB_COMMAND      0x0B
#define SFCB_RESULT       0x0C
#define SFCB_BUSY         0x10
#define SFCB_DATA         0x11
#define SYSCONF_CMD_READ  1
#define SYSCONF_CMD_WRITE 4
#define SYSCONF_RESULT_OK 3

static const uint16_t eeprom_m1325[64] = {
	0x0001, 0x0001, 0x0001, 0x00E1, 0x0105, 0x0110, 0x0810, 0x03C0,
	0xFFFF, 0x7FFF, 0x0008, 0xFF03, 0x230C, 0x0002, 0x0000, 0x0000,
	0x0101, 0x0000, 0x0000, 0x0000, 0x0000, 0x4000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x619C, 0x9E63,
};
static const uint16_t eeprom_q540[64] = {
	0x0001, 0x0001, 0x0001, 0x00E1, 0x0105, 0x0110, 0x0810, 0x01E0,
	0xFFFF, 0x0100, 0x0005, 0xFF03, 0x1204, 0x0002, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x4000, 0x0000, 0xFFFF,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
	0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0D1B, 0xF2E4,
};
static uint16_t eeprom[64];
static int      eeprom_loaded = 0;
static long     st_sysconf_cmds = 0;

static void eeprom_load(void) {
	const uint16_t* src = iop_disk_sectors() == 61440u ? eeprom_q540 : eeprom_m1325;
	for (int i = 0; i < 64; i++) eeprom[i] = src[i];
	eeprom_loaded = 1;
}

static int sysconf_notify(uint16_t mask) {
	(void)mask;
	uint32_t fcb = fcb_of(HANDLER_SYSCONF);
	if (fcb == 0) { return 0; }
	uint16_t w = iop_read(fcb + SFCB_COMMAND);
	unsigned cmd = w >> 8, addr = w & 0xFFu;
	if (cmd != SYSCONF_CMD_READ && cmd != SYSCONF_CMD_WRITE) { return 0; }
	if (!eeprom_loaded) eeprom_load();
#ifndef IOP_FIRMWARE
	if (getenv("SYSCONF_TRACE")) {
		fprintf(stderr, "SYSCONF cmd %u addr %02X fcb %06X:", cmd, addr, fcb);
		for (uint32_t i = 0; i < 0x14; i++) fprintf(stderr, " %04X", iop_read(fcb + i));
		fprintf(stderr, "\n");
	}
#endif
	if (cmd == SYSCONF_CMD_READ) {
		for (uint32_t i = 0; i < 64; i++) iop_write(fcb + SFCB_DATA + i, bswap(eeprom[i]));
	} else if (addr < 64) {
		eeprom[addr] = bswap(iop_read(fcb + SFCB_DATA + addr));
	}
	iop_write(fcb + SFCB_RESULT, bswap(SYSCONF_RESULT_OK));
	iop_write(fcb + SFCB_COMMAND, 0);
	iop_write(fcb + SFCB_BUSY, 0);
	st_sysconf_cmds++;
	return 1;
}

#define HANDLER_RS232C   18
#define RFCB_CONTROL     0x3C
#define RFCB_COMMAND     0x3D
#define RFCB_CLIENT_MASK 0x4C
#define RCMD_REQUEST     0x0008u
#define RCMD_IOP_CLEARS  0x00F9u
#define RCTL_IOP_OWNS    0x0080u
#define RFCB_MODEM       0x3B
#define RMODEM_IDLE      0x0006u
static long st_rs232_cmds = 0;

static int rs232_notify(uint16_t mask) {
	(void)mask;
	uint32_t fcb = fcb_of(HANDLER_RS232C);
	if (fcb == 0) { return 0; }
	uint16_t ctl = iop_read(fcb + RFCB_CONTROL);
	uint16_t cmd = iop_read(fcb + RFCB_COMMAND);
	if (!(ctl & RCTL_IOP_OWNS) && !(cmd & RCMD_REQUEST)) { return 0; }
	iop_write(fcb + RFCB_MODEM, RMODEM_IDLE);
	iop_write(fcb + RFCB_CONTROL, 0);
#ifndef IOP_FIRMWARE
	if (getenv("RS232_TRACE")) {
		fprintf(stderr, "RS232 control %04X command %04X client %04X %04X %04X\n",
		        iop_read(fcb + RFCB_CONTROL), cmd, iop_read(fcb + 0x4A),
		        iop_read(fcb + 0x4B), iop_read(fcb + RFCB_CLIENT_MASK));
		static long dumped;
		if (atoi(getenv("RS232_TRACE")) >= 2 && dumped++ < 400) {
			for (uint32_t i = 0; i < 0x60; i++)
				fprintf(stderr, "%s%04X", (i & 15) ? " " : (i ? "\n  " : "  "),
				        i == RFCB_CONTROL ? ctl : i == RFCB_COMMAND ? cmd : iop_read(fcb + i));
			fprintf(stderr, "\n");
		}
	}
#endif
	iop_write(fcb + RFCB_COMMAND, (uint16_t)(cmd & ~RCMD_IOP_CLEARS));
	uint16_t client = iop_read(fcb + RFCB_CLIENT_MASK);
	if (client != 0) { post_wake(client); }
	st_rs232_cmds++;
	return 1;
}

int iop_notify(uint16_t mask) {
	int claimed = 0;
	sysconf_notify(mask);
	rs232_notify(mask);
	if (mask == 0) {
		claimed += beep_notify() ? 1 : 0;
		claimed += disk_notify(0) ? 1 : 0;
		claimed += floppy_notify(0) ? 1 : 0;
		claimed += ethernet_notify(0) ? 1 : 0;
		claimed += processor_notify(0) ? 1 : 0;
		return claimed;
	}
	if (beep_notify())          { return 1; }
	if (disk_notify(mask))      { return 1; }
	if (floppy_notify(mask))    { return 1; }
	if (ethernet_notify(mask))  { return 1; }
	if (processor_notify(mask)) { claimed++; }
	return claimed;
}

#define IOP_STATE_FIELDS(X) \
	X(cpu_id) X(st_cmd_count) X(st_cmd_last) X(st_lock_count) \
	X(st_lock_bad) X(st_lock_last_mask) X(st_opie_unmodelled) \
	X(st_notifies) X(st_claimed) X(st_iocbs) X(st_sectors) X(st_failed) \
	X(st_written) X(st_intrs) X(st_intr_mask) \
	X(st_eth_notifies) X(st_eth_iocbs) X(st_eth_out) X(st_eth_resets) \
	X(st_eth_inputs) X(eth_rx) X(eth_rx_n) X(eth_reply) X(eth_reply_pending) \
	X(st_eth_replies) X(st_floppy_notifies) X(display_on) \
	X(st_display_changes) X(st_mouse_moves) X(gmt_correction) \
	X(st_floppy_iocbs) X(st_floppy_sectors) X(st_floppy_missing) \
	X(st_floppy_changes) X(st_floppy_sem) X(fl_info) X(fl_started) X(fl_wait) \
	X(fl_kind) X(fl_bytes) X(imd_trk) X(imd_scan) X(dmk_tlen) X(dmk_tracks) \
	X(dmk_sides) X(dmk_flags) X(fl_qnext_seen) \
	X(beep_div) X(st_beeps) X(disk_heads)

size_t iop_state_size(void) {
	size_t n = 0;
#define IOP_SZ(v) n += sizeof(v);
	IOP_STATE_FIELDS(IOP_SZ)
#undef IOP_SZ
	return n;
}

void iop_state_get(void* buf) {
	unsigned char* p = (unsigned char*)buf;
#define IOP_GET(v) { const unsigned char* s = (const unsigned char*)&v; \
	for (size_t i = 0; i < sizeof(v); i++) *p++ = s[i]; }
	IOP_STATE_FIELDS(IOP_GET)
#undef IOP_GET
}

void iop_state_set(const void* buf) {
	const unsigned char* p = (const unsigned char*)buf;
#define IOP_SET(v) { unsigned char* d = (unsigned char*)&v; \
	for (size_t i = 0; i < sizeof(v); i++) d[i] = *p++; }
	IOP_STATE_FIELDS(IOP_SET)
#undef IOP_SET
}

#define PV_SEAL            0xA28Au
#define BOOTINFO_BASE      0x0D
#define BOOTINFO_STRIDE    9
#define BOOT_SOFT_MICROCODE 1
#define BOOT_GERM          2
#define DISK_SECTORS       16
#define DISK_DEVINFO_GEOM  0x05224Eu
#define DISK_DEVINFO_CYLS  0x05224Fu
#define DISK_DEVINFO_TYPE  0x05224Du

#define SDD_PAGE        14
#define SDD_SEAL         0
#define SDD_SEAL_VALUE  0x6596u
#define SDD_CODE         2
#define SDD_SPT          3
#define SDD_HEADS        4
#define SDD_CYLS         5
#define SDD_CKS        254

static uint16_t sdd_checksum(const uint16_t* w) {
	uint32_t c = 0;
	for (int i = 0; i < SDD_CKS; i++) {
		c += w[i];
		c = (c & 0xFFFFu) + (c >> 16);
		c = ((c << 1) | (c >> 15)) & 0xFFFFu;
	}
	return (uint16_t)c;
}

static int      sdd_ok;
static uint16_t sdd_info[6];
static void sdd_probe(void) {
	uint16_t sdd[256], lbl[LBL_WORDS];
	disk_heads = 8;
	sdd_ok = iop_disk_sectors() > SDD_PAGE && iop_disk_read(SDD_PAGE, sdd, lbl)
	      && sdd[SDD_SEAL] == SDD_SEAL_VALUE && sdd[SDD_SPT] == DISK_SECTORS
	      && sdd[SDD_HEADS] >= 1 && sdd[SDD_HEADS] <= 16
	      && sdd_checksum(sdd) == sdd[SDD_CKS]
	      && (uint16_t)~sdd[SDD_CKS] == sdd[SDD_CKS + 1];
	if (!sdd_ok) return;
	for (int i = 0; i < 6; i++) sdd_info[i] = sdd[SDD_CODE + i];
	disk_heads = sdd[SDD_HEADS];
}

#define BOOT_MAP_BASE      0x1E0000u
#define MAP_VACANT         0x0060u
#define MAP_REFERENCED     0x0080u

static int32_t boot_map_rp(uint32_t vp) {
	if (vp < 0x00C0u) return (int32_t)(vp + 0x060u);
	if (vp < 0x0100u) return (int32_t)(vp + 0x460u);
	if (vp < 0x04E0u) return (int32_t)(vp + 0x020u);
	if (vp < 0x0540u) return (int32_t)(vp - 0x4E0u);
	if (vp < 0x1DE0u) return (int32_t)(vp + 0x020u);
	return -1;
}

static const uint32_t BOOT_WORDS[][2] = {
	{0x0063A0, 0x072E}, {0x0063A1, 0x0002}, {0x0063A2, 0x0040}, {0x0063AD, 0x0FAC},
	{0x0063B2, 0x0001}, {0x0063B4, 0x0800}, {0x0063B5, 0x005C}, {0x0063BC, 0x0080},
	{0x052004, 0x2104}, {0x052006, 0x4204}, {0x052008, 0x3704}, {0x05200A, 0x5D04},
	{0x05200C, 0x4E04}, {0x05200E, 0x2304}, {0x052022, 0x3E04}, {0x052024, 0x7504},
	{0x052112, 0x0101}, {0x05212A, 0xFFFF}, {0x05212B, 0xFFFF}, {0x05212C, 0xFFFF},
	{0x05212D, 0xFFFF}, {0x05212E, 0xFFFF}, {0x05212F, 0xFFFF}, {0x052130, 0xFFFF},
	{0x052131, 0xFFFF}, {0x052132, 0xFFFF}, {0x0521C1, 0x0102}, {0x0521DA, 0x8004},
	{0x0521DB, 0x5D03}, {0x0521E0, 0x503C}, {0x0521F5, 0x0104}, {0x0521F6, 0x0100},
	{0x052225, 0x0108}, {0x052226, 0x0110}, {0x05224C, 0x4230}, {0x05224D, 0x0040},
	{0x05224E, 0x1008}, {0x05224F, 0xC003}, {0x052250, 0xC003}, {0x052251, 0xC003},
	{0x052289, 0x4000}, {0x05228A, 0x0120}, {0x05228C, 0x0140}, {0x0522A1, 0x0013},
	{0x0522A2, 0x0028}, {0x0522A3, 0x0010}, {0x0522A4, 0x3000}, {0x0522AB, 0xFFFF},
	{0x0522AC, 0x5800}, {0x0522FD, 0x0180}, {0x0522FE, 0x0201}, {0x0522FF, 0x0202},
	{0x0523C4, 0x0204},
	{0x052026, 0x8004},
	{0x052028, 0xA004},
	{0x0520C6, 0xC004},
};

static uint32_t boot_first(const uint16_t* root, int type) {
	const uint16_t* r = root + BOOTINFO_BASE + BOOTINFO_STRIDE * type;
	if (r[2] == 0 && r[3] == 0) return 0xFFFFFFFFu;
	return (uint32_t)r[2] * DISK_HEADS * DISK_SECTORS
	     + (uint32_t)(r[3] >> 8) * DISK_SECTORS + (r[3] & 0xFFu);
}

static uint32_t bf_first, bf_page = 0xFFFFFFFFu;
static uint16_t bf_buf[256];
static int      bf_floppy;

static int fl_page(uint32_t page, uint16_t* d256) {
	struct fl_sector s;
	if (page == 0) return 0;
	uint32_t p = page - 1;
	if (!floppy_find(p / 18, (p / 9) % 2, p % 9 + 1, &s)) return 0;
	for (uint32_t i = 0; i < 256; i++) {
		if (i >= s.size / 2) { d256[i] = 0; continue; }
		uint32_t o = s.fill ? s.off : s.off + 2 * i * s.step;
		unsigned hi = fl_byte(o), lo = s.fill ? hi : fl_byte(o + s.step);
		d256[i] = (uint16_t)((hi << 8) | lo);
	}
	return 1;
}

static int bf_word(uint32_t off, uint16_t* w) {
	uint32_t p = off >> 9;
	if (p >= 128) return 0;
	if (p != bf_page) {
		uint16_t lbl[10];
		if (bf_floppy ? !fl_page(bf_first + p, bf_buf)
		              : !iop_disk_read(bf_first + p, bf_buf, lbl)) return 0;
		bf_page = p;
	}
	*w = bf_buf[(off & 511u) >> 1];
	return 1;
}

static int mc_walk(uint32_t off, int load) {
	for (int n = 0; n < 64; n++) {
		uint16_t tag, bank, start, count;
		if (!bf_word(off, &tag)) return 0;
		if (tag == 0x4000u) return 1;
		if (tag == 0x9000u) { off += 6; continue; }
		if (tag != 0xD000u) return 0;
		if (!bf_word(off + 2, &bank) || !bf_word(off + 4, &start)
		    || !bf_word(off + 6, &count)) return 0;
		if (bank != 0 || count == 0 || (uint32_t)start + count > 4096u) return 0;
		if (load) {
			for (uint32_t k = 0; k < count; k++) {
				uint16_t hi, mid, lo;
				uint32_t o = off + 8 + 6 * k;
				if (!bf_word(o, &hi) || !bf_word(o + 2, &mid) || !bf_word(o + 4, &lo))
					return 0;
				iop_cs_write(start + k, hi, mid, lo);
			}
		}
		off += 8 + 6u * count;
	}
	return 0;
}

#define FL_ROOT_SEAL       0xC30Cu
#define FL_LIST_SEAL       0xB2CBu
#define FL9_FILE_LIST      5
#define FL9_MICROCODE      12
#define FL9_GERM           14
#define FL9_PILOT          15

static uint32_t fl_file_pages(const uint16_t* nine, uint32_t page, uint32_t* id) {
	uint16_t list[256];
	if (!fl_page(nine[FL9_FILE_LIST], list) || list[0] != FL_LIST_SEAL) return 0;
	for (uint32_t i = 0; i < list[2] && 4 + 5 * i + 4 < 256; i++)
		if (list[4 + 5 * i + 3] == page) {
			if (id) *id = list[4 + 5 * i] | ((uint32_t)list[4 + 5 * i + 1] << 16);
			return list[4 + 5 * i + 4];
		}
	return 0;
}

#define BOOT_REQUEST       0x0063A0u
#define BOOT_ACTION_INLOAD 0
#define DEVICE_ANY_FLOPPY  17

int iop_boot(void) {
	uint16_t root[256], lbl[10];
	uint32_t soft, germ, germ_pages = 96, pilot_id = 0, pilot_page = 0;
	sdd_probe();
	bf_floppy = 0;
	fl_info = iop_floppy_info();
	fl_kind = floppy_kind();
	if (iop_boot_floppy() && fl_kind != FL_NONE && fl_page(9, root) && root[0] == FL_ROOT_SEAL
	    && root[FL9_MICROCODE] != 0 && root[FL9_GERM] != 0 && root[FL9_PILOT] != 0
	    && (germ_pages = fl_file_pages(root, root[FL9_GERM], NULL)) != 0
	    && fl_file_pages(root, root[FL9_PILOT], &pilot_id) != 0) {
		pilot_page = root[FL9_PILOT];
		bf_floppy = 1;
		soft = root[FL9_MICROCODE];
		germ = root[FL9_GERM];
		if (germ_pages > 96) germ_pages = 96;
	}
	else {
		germ_pages = 96;
		if (!iop_disk_read(0, root, lbl) || root[0] != PV_SEAL) return 0;
		soft = boot_first(root, BOOT_SOFT_MICROCODE);
		germ = boot_first(root, BOOT_GERM);
		if (soft == 0xFFFFFFFFu || germ == 0xFFFFFFFFu) return 0;
	}

	for (uint32_t vp = 0; vp < 0x10000u; vp++) {
		int32_t rp = boot_map_rp(vp);
		uint16_t e = rp < 0 ? MAP_VACANT
		           : (uint16_t)(((rp & 0xFF) << 8) | ((rp >> 8) & 0x1F)
		                        | (vp == 0x200u ? MAP_REFERENCED : 0));
		iop_write(BOOT_MAP_BASE + vp, e);
	}

	for (uint32_t k = 0; k < germ_pages; k++) {
		uint16_t data[256];
		if (bf_floppy ? !fl_page(germ + k, data) : !iop_disk_read(germ + k, data, lbl))
			return 0;
		uint32_t base = (uint32_t)boot_map_rp(k == 0 ? 0x200u : k) << 8;
		for (int i = 0; i < 256; i++) iop_write(base + (uint32_t)i, data[i]);
		if (!bf_floppy && (lbl[8] == 0xFFFFu || lbl[9] == 0xFFFFu)) break;
	}

	for (uint32_t a = 0x052400u; a < 0x052700u; a++) iop_write(a, 0);
	for (uint32_t i = 0; i < sizeof BOOT_WORDS / sizeof BOOT_WORDS[0]; i++)
		iop_write(BOOT_WORDS[i][0], (uint16_t)BOOT_WORDS[i][1]);
	{
		uint32_t cyls = iop_disk_sectors() / (DISK_HEADS * DISK_SECTORS);
		if (cyls > 0xFFFFu) cyls = 0xFFFFu;
		for (uint32_t w = 0; cyls != 0 && w < 3; w++)
			iop_write(DISK_DEVINFO_CYLS + w, bswap((uint16_t)cyls));
	}
	if (sdd_ok) {
		iop_write(DISK_DEVINFO_TYPE, sdd_info[0]);
		iop_write(DISK_DEVINFO_GEOM, (uint16_t)((DISK_SECTORS << 8) | disk_heads));
		for (uint32_t w = 0; w < 3; w++)
			iop_write(DISK_DEVINFO_CYLS + w, bswap(sdd_info[3 + w]));
	}
	if (bf_floppy) {
		uint32_t p = pilot_page - 1;
		iop_write(BOOT_REQUEST + 1, BOOT_ACTION_INLOAD);
		iop_write(BOOT_REQUEST + 2, DEVICE_ANY_FLOPPY);
		iop_write(BOOT_REQUEST + 4, (uint16_t)pilot_id);
		iop_write(BOOT_REQUEST + 5, (uint16_t)(pilot_id >> 16));
		iop_write(BOOT_REQUEST + 11, (uint16_t)(p / 18));
		iop_write(BOOT_REQUEST + 12, (uint16_t)((((p / 9) % 2) << 8) | (p % 9 + 1)));
	}
	fl_started = 0;
	floppy_refresh();

	display_on = 1;
	mp_cursor_mode = 1;
	picture_blanked = 1;

	bf_first = soft;
	bf_page = 0xFFFFFFFFu;
	for (uint32_t off = 0; off < 128u * 512u; off += 2) {
		uint16_t w;
		if (!bf_word(off, &w)) return 0;
		if (w == 0xD000u && mc_walk(off, 0)) return mc_walk(off, 1);
	}
	return 0;
}
