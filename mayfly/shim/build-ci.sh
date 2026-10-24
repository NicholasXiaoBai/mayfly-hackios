#!/usr/bin/env bash
# build-ci.sh —— Linux / GitHub Actions 下构建 shim 与 boot.img
#
# 与 build-win.sh 等价，只是工具链换成 aarch64-linux-gnu-*（runner 上直接 apt 装）。
# 本机的 Windows 环境用 build-win.sh。
set -euo pipefail
cd "$(dirname "$0")"

ROOT=$(cd ../.. && pwd)
CROSS=${CROSS:-aarch64-linux-gnu-}
DTB=${DTB:-$ROOT/facts/mayfly-live.dtb}
HDRVER=${HDRVER:-4}
CMDLINE=${CMDLINE:-console=null}

CC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"

CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -fno-jump-tables -mgeneral-regs-only \
-mstrict-align -fno-stack-protector -Wall -Wextra"

mkdir -p out
OBJS="start.S shim.c console.c mmu.c fdt.c loader.c ufs.c"
for f in $OBJS; do
	echo "  CC  $f"
	$CC $CFLAGS -c "$f" -o "out/${f%.*}.o"
done
echo "  CC  klibc.c"
$CC $CFLAGS -fno-builtin -c klibc.c -o out/klibc.o

LIST="out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o out/klibc.o"

echo "  LD  shim.elf"
# --no-gc-sections 必须加：.text.head 只被 ENTRY(_head) 引用，没有任何代码调用它，
# 开了 gc 就会被当作死代码丢掉，镜像开头就不是 ARM64 头了，ABL 会直接拒绝。
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-gc-sections $LIST -o out/shim.elf

echo "  CHK 绝对重定位"
python3 "$ROOT/tools/elfinfo.py" out/shim.elf || {
	echo "error: 镜像里存在绝对重定位，ABL 不做重定位，运行必崩" >&2
	exit 1
}

echo "  BIN shim.elf -> Image"
if command -v "$OBJCOPY" >/dev/null 2>&1; then
	$OBJCOPY -O binary out/shim.elf out/Image
else
	python3 "$ROOT/tools/elfinfo.py" out/shim.elf --bin out/Image
fi
END=$(python3 "$ROOT/tools/elfinfo.py" out/shim.elf --end)
[ -n "$END" ] && [ "$END" != "None" ] || { echo "拿不到 _end" >&2; exit 1; }
# ABL 只复制文件本身，.bss 与栈要按 _end 补成真实字节
truncate -s "$END" out/Image
echo "  Image = $END 字节"

echo "  RD  ramdisk"
if [ -n "${1:-}" ]; then
	# 给了 payload（mkpayload.py 的产物）：它自己就是 ramdisk，里面是内核 + ADT
	cp "$1" out/ramdisk.bin
	echo "       ramdisk = $1 ($(wc -c < "$1") 字节)"
else
	python3 "$ROOT/tools/mkramdisk.py" out/ramdisk.bin
fi

echo "  IMG shim-boot.img (header v$HDRVER)"
ARGS=(--header_version "$HDRVER" --kernel out/Image --ramdisk out/ramdisk.bin
	--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000
	--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096
	--os_version 17.0.0 --os_patch_level 2035-06 --cmdline "$CMDLINE")
[ -f "$DTB" ] && ARGS+=(--dtb "$DTB")
python3 "$ROOT/tools/mkbootimg.py" "${ARGS[@]}" -o out/shim-boot.img

ls -l out/Image out/shim-boot.img
