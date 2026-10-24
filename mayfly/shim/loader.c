/*
 * Milestone 4: act as iBoot for xnu.
 *
 * mkpayload.py already resolved the kernel's chained fixups and built the
 * ADT, so this only has to: find the payload in the ABL ramdisk, copy the
 * segments to phys_base + (vmaddr - virt_base), place the ADT and
 * boot_args behind the kernel, and jump to the entry point with the MMU
 * and caches off, x0 = boot_args (physical).
 */
#include <stdint.h>
#include "console.h"
#include "fdt.h"
#include "loader.h"

/* 编译期用 -DPAYLOAD_OFF= 传入，等于把 Image 补齐到的偏移 */
#ifndef PAYLOAD_OFF
#define PAYLOAD_OFF 0x80000UL
#endif

extern char _head[];

#define BOOT_LINE_LENGTH	608
#define PAGE_16K		0x4000UL

struct payload_seg {
	uint64_t vmaddr, vmsize, file_off, file_size;
};

struct payload {
	char magic[8];
	uint32_t version, nsegs;
	uint64_t virt_base, entry_va, adt_off, adt_size, kernel_end;
	uint64_t phys_base, mem_size;
	char cmdline[BOOT_LINE_LENGTH];
	struct payload_seg segs[];
};

/* pexpert/pexpert/arm64/boot.h, Revision/Version 2 */
struct boot_video {
	uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};

struct boot_args {
	uint16_t Revision, Version;
	uint64_t virtBase, physBase, memSize, topOfKernelData;
	struct boot_video Video;
	uint32_t machineType;
	uint64_t deviceTreeP;
	uint32_t deviceTreeLength;
	char CommandLine[BOOT_LINE_LENGTH];
	uint64_t bootFlags, memSizeActual;
};

_Static_assert(__builtin_offsetof(struct payload, segs) == 0x2a8, "payload header layout");
_Static_assert(__builtin_offsetof(struct boot_args, Video) == 40, "boot_args layout");
_Static_assert(__builtin_offsetof(struct boot_args, CommandLine) == 108, "boot_args layout");
_Static_assert(sizeof(struct boot_args) == 736, "boot_args layout");

/* MMU off: everything is Device memory, so copy in aligned 8-byte words. */
static void copy64(uintptr_t dst, uintptr_t src, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	volatile const uint64_t *s = (volatile const uint64_t *)src;
	for (uint64_t i = 0; i < (n + 7) / 8; i++)
		d[i] = s[i];
}

static void zero64(uintptr_t dst, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	for (uint64_t i = 0; i < n / 8; i++)
		d[i] = 0;
}

static int magic_ok(const char *m)
{
	static const char want[] = "SWEETXNU";
	for (int i = 0; i < 8; i++)
		if (m[i] != want[i])
			return 0;
	return 1;
}

typedef void (*xnu_entry_t)(uint64_t boot_args_pa);

uint64_t g_rd_start, g_rd_end, g_magic;   /* 给 shim.c 在屏上回报用 */

const char *loader_boot(uintptr_t dtb)
{
	uint64_t rd_start = 0, rd_end = 0;

	/* /chosen 的 initrd 字段在 mayfly 的 ABL 上不可信（实测报的是一个 6.8MB 的
	 * 区间，而我们的 payload 有 16.6MB，MAGIC 也对不上）。所以 payload 改成
	 * 追加在本镜像尾部、由链接期常量 PAYLOAD_OFF 定位：镜像基址用 adr 取，
	 * 不依赖 ABL 传任何东西。 */
	(void)fdt_chosen_u64(dtb, "linux,initrd-start", &rd_start);
	(void)fdt_chosen_u64(dtb, "linux,initrd-end", &rd_end);
	g_rd_start = rd_start; g_rd_end = rd_end;

	uintptr_t img_base;
	__asm__ volatile("adr %0, _head" : "=r"(img_base));
	const struct payload *p = (const struct payload *)(img_base + PAYLOAD_OFF);
	con_hex2("IMAGE+", "base=", (uint32_t)img_base, "off=", (uint32_t)PAYLOAD_OFF);

	{ uint64_t m = 0; for (int i = 0; i < 8; i++) m |= (uint64_t)(unsigned char)p->magic[i] << (8 * i); g_magic = m; }
	if (!magic_ok(p->magic))
		return "no payload at IMAGE+off";
	if (p->version != 1 || (p->adt_off & 7))
		return "bad payload header";

	uint64_t pa_of_va_base = p->phys_base - p->virt_base;	/* pa = va + this */
	con_hex2("PHYS", "base=", p->phys_base, "size=", p->mem_size);
	con_hex("VIRT", p->virt_base);
	con_hex("ENTRY", p->entry_va);

	/* The payload must not overlap where the kernel goes. */
	if (rd_end > p->phys_base && rd_start < p->phys_base + p->mem_size)
		return "ramdisk overlaps kernel memory";

	for (uint32_t i = 0; i < p->nsegs; i++) {
		const struct payload_seg *s = &p->segs[i];
		uintptr_t dst = s->vmaddr + pa_of_va_base;
		copy64(dst, (uintptr_t)p + s->file_off, s->file_size);
		if (s->vmsize > s->file_size)
			zero64(dst + ((s->file_size + 7) & ~7UL), s->vmsize - ((s->file_size + 7) & ~7UL));
	}
	con_hex2("SEGS", "n=", p->nsegs, "end=", p->kernel_end + pa_of_va_base);

	/* ADT, then boot_args, behind the kernel; everything below topOfKernelData is ours. */
	uintptr_t adt_pa = p->kernel_end + pa_of_va_base;
	copy64(adt_pa, (uintptr_t)p + p->adt_off, p->adt_size);
	uintptr_t ba_pa = (adt_pa + p->adt_size + PAGE_16K - 1) & ~(PAGE_16K - 1);
	uintptr_t top = ba_pa + PAGE_16K;

	zero64(ba_pa, PAGE_16K);
	volatile struct boot_args *ba = (volatile struct boot_args *)ba_pa;
	ba->Revision = 2;
	ba->Version = 2;
	ba->virtBase = p->virt_base;
	ba->physBase = p->phys_base;
	ba->memSize = p->mem_size;
	ba->topOfKernelData = top;
	ba->Video.v_baseAddr = FB_BASE;
	ba->Video.v_display = 1;
	ba->Video.v_rowBytes = FB_STRIDE;
	ba->Video.v_width = FB_W;
	ba->Video.v_height = FB_H;
	ba->Video.v_depth = 32;
	ba->deviceTreeP = adt_pa - pa_of_va_base;	/* xnu reads it with the MMU on: a VA */
	ba->deviceTreeLength = (uint32_t)p->adt_size;
	for (int i = 0; i < BOOT_LINE_LENGTH; i++)
		ba->CommandLine[i] = p->cmdline[i];
	ba->memSizeActual = p->mem_size;
	con_hex2("BOOTARG", "pa=", ba_pa, "top=", top);

	uintptr_t entry_pa = p->entry_va + pa_of_va_base;
	con_hex("JUMP", entry_pa);

	/* 诊断：内核在 fiq_context_init+0xc 报 Undefined instruction，那条本该是
	 * 0xd51be328 (MSR CNTV_CTL_EL0)。这里把内存里实际的字读回来比对，
	 * 同时报当前异常级别——若 CEL 不是 0x4(EL1)，就能解释为什么这条 MSR 非法。 */
	uint64_t cel;
	__asm__ volatile("mrs %0, CurrentEL" : "=r"(cel));
	con_hex("CEL", cel);
	{
		uint64_t va = 0xfffffe0007491340ULL;
		uint32_t got = *(volatile uint32_t *)(uintptr_t)(va + pa_of_va_base);
		con_hex2("KPROBE", "got=", got, "want=", 0xd51be328U);
	}
	con_str("HOLD", "25s before jump - photograph");
	{
		uint64_t t0, fr, t;
		__asm__ volatile("mrs %0, cntpct_el0" : "=r"(t0));
		__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(fr));
		uint64_t stop = t0 + fr * 25;
		do { __asm__ volatile("mrs %0, cntpct_el0" : "=r"(t)); } while (t < stop);
	}
	con_str("XNU", "jumping now");

	/* Everything was written with the MMU and caches off; drop any stale I-cache lines too. */
	__asm__ volatile("dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((xnu_entry_t)entry_pa)(ba_pa);
	return "xnu returned";
}
