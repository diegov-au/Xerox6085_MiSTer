#ifndef XEROX_IOP_H
#define XEROX_IOP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IOP_IOR_BASE 0x052000u

uint16_t iop_read(uint32_t real_word_addr);
void     iop_write(uint32_t real_word_addr, uint16_t value);

void iop_raise_wake(uint16_t mask);

void iop_post_wake(uint16_t mask);

#define IOP_XLAT_VACANT 0xFFFFFFFFu
uint32_t iop_xlat(uint32_t virtual_word_addr);

int iop_disk_read(uint32_t sector, uint16_t* data256, uint16_t* label10);

int iop_disk_write(uint32_t sector, const uint16_t* data256,
                   const uint16_t* label10);

uint32_t iop_disk_sectors(void);

void iop_sector_to_mem(uint32_t word, uint32_t real, int n);
void iop_mem_to_sector(uint32_t word, uint32_t real, int n);
int iop_disk_write_sector(uint32_t sector, const uint16_t* label10);

void iop_beep(uint16_t divisor);
long iop_beep_count(void);

uint32_t iop_floppy_info(void);
int      iop_floppy_block(uint32_t block, uint8_t* out512);

void iop_floppy_stats(long* notifies, long* iocbs, long* sectors,
                      long* missing, long* changes, long* sem, int* kind);

void iop_cursor(int visible, uint16_t x, uint16_t y, const uint16_t* rows16);

void iop_picture_blank(int on);

int iop_clock_seconds(uint32_t* seconds);

int iop_boot_floppy(void);

int iop_clock_unix(uint32_t* unix_seconds);

int iop_clock_legacy(void);

void iop_cs_write(uint32_t addr, uint16_t hi, uint16_t mid, uint16_t lo);

void iop_disk_stats(long* notifies, long* claimed, long* iocbs,
                    long* sectors, long* failed, long* written,
                    long* intrs, unsigned* intr_mask);

void iop_eth_stats(long* notifies, long* iocbs, long* outputs, long* resets,
                   long* inputs, long* replies, long* bad_ptr);

void iop_proc_stats(long* counts, unsigned* last);

uint16_t iop_lockmem(uint16_t operation, uint16_t offset,
                     uint16_t value, uint16_t mask);

void iop_lock_stats(long* counts, long* bad, unsigned* last_mask);

void iop_display_service(void);
void iop_display_stats(long* changes, int* on);

void iop_display_retrace(void);

void iop_cursor_follow(void);

void iop_display_cursor(void);

void iop_mouse_set(uint16_t x, uint16_t y);
void iop_key_set(int word, int bit, int pressed);
long iop_mouse_moves(void);

size_t iop_state_size(void);
void   iop_state_get(void* buf);
void   iop_state_set(const void* buf);

int iop_notify(uint16_t mask);

void iop_reset(void);

int iop_boot(void);

#ifndef IOP_FIRMWARE
#include <stdio.h>

uint32_t disk_open(const char* path);
void     disk_close(void);

void disk_stats(long* reads, long* writes, long* overlay_hits);

int disk_state_save(FILE* f);
int disk_state_load(FILE* f);

int  floppy_open(const char* path);
long floppy_blocks_read(void);

int  disk_export(const char* path);
#endif

#ifdef __cplusplus
}
#endif

#endif
