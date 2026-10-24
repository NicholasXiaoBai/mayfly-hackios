#pragma once
#include <stdint.h>

void test_ufs(void);

/* Persistent log into the tail of an unused partition (see ufs.c). */
int klog_init(const char *part);
void klog(const char *tag, const char *msg);
void klog_hex(const char *tag, uint64_t v);
int klog_sync(void);
int ufs_probe_write(uint32_t lba, const void *buf, int upiu_flag, int utrd_dd);
int ufs_probe_read(uint32_t lba, void *buf);
int ufs_part_first(const char *name, uint32_t *first);
