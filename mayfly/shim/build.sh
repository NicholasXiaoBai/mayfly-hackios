#!/bin/bash
# Build the shim and wrap it in a boot.img.
# Toolchain: Android NDK clang + ld.lld (this port is built on Linux, the
# upstream script assumed aarch64-linux-gnu-* from a distro package).
set -euo pipefail
cd "$(dirname "$0")"

NDK=${NDK:-/home/xtom0706/android-sdk/ndk/25.2.9519653}
CROSS=${CROSS:-$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin}
CC="$CROSS/clang --target=aarch64-linux-gnu -fuse-ld=$CROSS/ld.lld"
OBJCOPY=$CROSS/llvm-objcopy
READELF=$CROSS/llvm-readelf
NM=$CROSS/llvm-nm
DTB=${DTB:-../../dump/live.dtb}
# The K60 (GKI-era) ABL silently ignores header v2 boot images: fastboot
# reports "Booting OKAY" and then just boots the slot. v4 is required.
HDRVER=${HDRVER:-4}

# -fno-jump-tables: clang otherwise emits a table of absolute string pointers
# for the panic switch, breaking the "no absolute relocations" invariant below.
CFLAGS="${CFLAGS_EXTRA:-} -O2 -ffreestanding -nostdlib -fno-pic -fno-jump-tables -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out
OBJS="start.S shim.c console.c mmu.c fdt.c loader.c ufs.c"
for f in $OBJS; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# freestanding string helpers; -fno-builtin so they are not folded into themselves
$CC $CFLAGS -fno-builtin -c klibc.c -o out/klibc.o
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/klibc.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/klibc.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$($NM out/shim.elf | awk '$3=="_end"{print strtonum("0x"$1)}')
truncate -s "$size" out/Image
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
mkbootimg --header_version "$HDRVER" --kernel out/Image --ramdisk out/ramdisk.bin \
	--dtb "$DTB" --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
	--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
	--os_version 17.0.0 --os_patch_level 2035-06 \
	--cmdline "${CMDLINE:-console=null}" -o out/shim-boot.img
# Host render of the console layout.
gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img
