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

PAYLOAD_OFF=${PAYLOAD_OFF:-0x80000}
CFLAGS="-DPAYLOAD_OFF=${PAYLOAD_OFF} -O2 -ffreestanding -nostdlib -fno-pic -fno-jump-tables -mgeneral-regs-only \
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

echo "  RD  ramdisk（空 newc：payload 不再走 ramdisk）"
python3 "$ROOT/tools/mkramdisk.py" out/ramdisk.bin

# payload 追加在镜像尾部：ABL 不更新 /chosen 的 initrd 字段，所以不能靠它定位。
# 镜像补齐到 PAYLOAD_OFF，loader 用 adr 取基址 + 这个常量找到 payload。
if [ -n "${1:-}" ]; then
	shim_end=$(wc -c < out/Image)
	if [ "$shim_end" -gt "$((PAYLOAD_OFF))" ]; then
		echo "error: shim 已 ${shim_end} 字节，超过 PAYLOAD_OFF=${PAYLOAD_OFF}" >&2
		exit 1
	fi
	truncate -s "$((PAYLOAD_OFF))" out/Image
	cat "$1" >> out/Image
	python3 - <<'PYEOF'
import struct
f='out/Image'
d=bytearray(open(f,'rb').read())
struct.pack_into('<Q', d, 16, len(d))     # ARM64 Image header 的 image_size
open(f,'wb').write(d)
print(f'       Image = {len(d)} 字节（shim {len(d)-struct.unpack_from("<Q",d,16)[0]} ... 尾部含 payload）')
PYEOF
fi

echo "  IMG shim-boot.img (header v$HDRVER)"
ARGS=(--header_version "$HDRVER" --kernel out/Image --ramdisk out/ramdisk.bin
	--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000
	--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096
	--os_version 17.0.0 --os_patch_level 2035-06 --cmdline "$CMDLINE")
[ -f "$DTB" ] && ARGS+=(--dtb "$DTB")
python3 "$ROOT/tools/mkbootimg.py" "${ARGS[@]}" -o out/shim-boot.img

ls -l out/Image out/shim-boot.img
