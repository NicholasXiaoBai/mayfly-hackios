#!/usr/bin/env bash
# build-win.sh —— 在 Windows（Git Bash + Zig）上构建 mayfly 的 shim 与 boot.img
#
# 与 K60 的 shim/build.sh 等价，但把 NDK/llvm-objcopy/readelf/nm/cpio/mkbootimg
# 这一串 Linux 依赖换成本机就有的东西：
#   clang + ld.lld  -> zig cc（自带 aarch64 后端与 lld）
#   llvm-objcopy    -> zig objcopy，失败则退回 ld 的 --oformat=binary
#   llvm-nm/readelf -> tools/elfinfo.py（纯 Python）
#   cpio            -> tools/mkramdisk.py（纯 Python）
#   mkbootimg       -> tools/mkbootimg.py（AOSP 原版，支持 header v4）
#
# 用法:
#   bash shim/build-win.sh                    # 只出诊断 shim
#   bash shim/build-win.sh path/to/payload.bin  # 带 XNU payload
set -euo pipefail
cd "$(dirname "$0")"

ROOT=$(cd ../.. && pwd)                      # hackios-port/
ZIG=${ZIG:-$ROOT/../toolchain/zig-x86_64-windows-0.17.0/zig.exe}
TARGET=${TARGET:-aarch64-freestanding}      # zig 0.17 里 "none-elf" 写作 freestanding
DTB=${DTB:-$ROOT/facts/mayfly-live.dtb}
HDRVER=${HDRVER:-4}                          # 新 ABL 静默忽略 v2，必须 v4
CMDLINE=${CMDLINE:-console=null}

[ -x "$ZIG" ] || { echo "找不到 zig: $ZIG" >&2; exit 1; }
[ -f "$DTB" ] || { echo "找不到设备树: $DTB" >&2; exit 1; }

CC="$ZIG cc -target $TARGET"
# -fno-jump-tables: 否则 clang 把 panic 的 switch 编成绝对地址跳转表，
#   破坏"镜像内无绝对地址"这个前提。
PAYLOAD_OFF=${PAYLOAD_OFF:-0x80000}
CFLAGS="-DPAYLOAD_OFF=${PAYLOAD_OFF} -DBUILD_STAMP=\"$(date +%m%d-%H%M)\" -O2 -ffreestanding -nostdlib -fno-pic -fno-jump-tables -mgeneral-regs-only \
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
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-gc-sections $LIST -o out/shim.elf

echo "  CHK 绝对重定位"
python "$ROOT/tools/elfinfo.py" out/shim.elf || {
	echo "error: 镜像里存在绝对重定位，ABL 不做重定位，运行必崩" >&2
	exit 1
}

echo "  BIN shim.elf -> Image"
END=$(python "$ROOT/tools/elfinfo.py" out/shim.elf --end)
[ "$END" != "None" ] && [ -n "$END" ] || { echo "拿不到 _end" >&2; exit 1; }
# 自己把 ELF 摊成裸二进制：zig 不带 objcopy，lld 也不收 --oformat
python "$ROOT/tools/elfinfo.py" out/shim.elf --bin out/Image || exit 1
# ABL 只复制文件本身，.bss 和栈要按 _end 补成真实字节
truncate -s "$END" out/Image
echo "  Image = $END 字节"

echo "  RD  ramdisk（空 newc：payload 不再走 ramdisk）"
python "$ROOT/tools/mkramdisk.py" out/ramdisk.bin

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
	python - <<'PYEOF'
import struct
f='out/Image'
d=bytearray(open(f,'rb').read())
struct.pack_into('<Q', d, 16, len(d))     # ARM64 Image header 的 image_size
open(f,'wb').write(d)
print(f'       Image = {len(d)} 字节（shim {len(d)-struct.unpack_from("<Q",d,16)[0]} ... 尾部含 payload）')
PYEOF
fi

echo "  IMG shim-boot.img (header v$HDRVER)"
python "$ROOT/tools/mkbootimg.py" \
	--header_version "$HDRVER" \
	--kernel out/Image --ramdisk out/ramdisk.bin --dtb "$DTB" \
	--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
	--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
	--os_version 17.0.0 --os_patch_level 2035-06 \
	--cmdline "$CMDLINE" -o out/shim-boot.img

ls -l out/Image out/shim-boot.img
echo ""
echo "刷入（不写分区）:"
echo "  adb reboot bootloader"
echo "  fastboot boot hackios-port/mayfly/shim/out/shim-boot.img"
