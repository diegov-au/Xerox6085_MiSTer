#include "mmio.h"
#include "iop.h"

static uint16_t keys_seen[9];
#ifdef WAIT_RUN
extern int iop_cp_live;
#endif

void iop_input(void) {
	uint32_t xy = IOP_REG(REG_MOUSE_XY);
	iop_mouse_set((uint16_t)(xy & 0xFFFFu), (uint16_t)(xy >> 16));
	for (int w = 0; w < 9; w++) {
		uint16_t k = (uint16_t)IOP_REG(REG_KEYS(w));
		uint16_t changed = (uint16_t)(k ^ keys_seen[w]);
		for (int b = 0; b < 16; b++)
			if (changed & (0x8000u >> b))
				iop_key_set(w, b, (k & (0x8000u >> b)) == 0);
		keys_seen[w] = k;
	}
}

#ifdef WAIT_RUN
void iop_events(uint32_t s) {
	if (s & ST_NOTIFY)  iop_notify(0);
	if (s & ST_LOCKREL) iop_display_service();
	if (s & ST_VSYNC)   { if (s & ST_VSAFE) iop_display_retrace(); else iop_display_cursor(); }
	if (s & ST_INPUT)   { iop_input(); iop_cursor_follow(); }
}
#endif

int main(void) {
	for (int w = 0; w < 9; w++) keys_seen[w] = 0xFFFFu;
	if (IOP_REG(REG_CONFIG) & CFG_BOOT)
		while (!iop_boot()) { }
	iop_reset();
#ifdef WAIT_RUN
	iop_cp_live = 1;
#endif
	IOP_REG(REG_HOLD) = 0;
	for (;;) {
		uint32_t s = IOP_REG(REG_STATUS);
		if (s == 0) continue;
		IOP_REG(REG_ACK) = s;
#ifdef WAIT_RUN
		iop_events(s);
#else
		if (s & ST_NOTIFY)  iop_notify(0);
		if (s & ST_LOCKREL) iop_display_service();
		if (s & ST_VSYNC)   { if (s & ST_VSAFE) iop_display_retrace(); else iop_display_cursor(); }
		if (s & ST_INPUT)   { iop_input(); iop_cursor_follow(); }
#endif
		IOP_REG(REG_HOLD) = 0;
	}
}
