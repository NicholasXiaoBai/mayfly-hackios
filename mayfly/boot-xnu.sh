#!/usr/bin/env bash
# boot-xnu.sh —— 把 CI 下来的 XNU 内核打成可 fastboot boot 的镜像
#
#   KERNEL=out/kernel.development.sweet ./mayfly/boot-xnu.sh
#
# 产物：mayfly/shim/out/shim-boot.img
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)

KERNEL=${KERNEL:-$ROOT/out/kernel.development.sweet}
CMDLINE=${CMDLINE:-"debug=0xc serial=3 cpus=1 keepsyms=1 -noprogress"}

[ -f "$KERNEL" ] || { echo "找不到内核: $KERNEL（用 KERNEL=... 指定）" >&2; exit 1; }

mkdir -p "$ROOT/out"
echo "== 1/3 生成 Apple 设备树（mayfly 常量）"
python3 "$ROOT/tools/mkadt.py" "$ROOT/out/mayfly.adt" --highmem

echo "== 2/3 打包 payload"
python3 "$ROOT/tools/mkpayload.py" "$KERNEL" "$ROOT/out/mayfly.adt" "$ROOT/out/payload.bin" \
	--cmdline "$CMDLINE"

echo "== 3/3 构建 boot 镜像"
# 有交叉 gcc 就用它（CI 环境）；否则退回 Zig（Windows 本地）
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
	bash "$ROOT/mayfly/shim/build-ci.sh" "$ROOT/out/payload.bin"
else
	bash "$ROOT/mayfly/shim/build-win.sh" "$ROOT/out/payload.bin"
fi

echo ""
echo "刷入："
echo "  adb reboot bootloader"
echo "  fastboot boot mayfly/shim/out/shim-boot.img"
