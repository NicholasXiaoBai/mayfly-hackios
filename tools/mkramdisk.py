#!/usr/bin/env python3
"""
mkramdisk.py —— 生成一个最小但合法的 newc cpio 归档。

K60 的记录里提到有些 ABL 会拒绝 0 字节 ramdisk，所以即使不需要 payload，
也塞一个只有 "." 目录项的归档进去。

用法: python tools/mkramdisk.py out/ramdisk.bin
"""
import os
import struct
import sys

MAGIC = b"070701"


def entry(name, data=b"", mode=0o040755, ino=1):
    namez = name.encode() + b"\0"
    hdr = MAGIC + b"".join(
        b"%08X" % v
        for v in (
            ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(namez), 0
        )
    )
    out = hdr + namez
    out += b"\0" * ((-len(out)) % 4)
    out += data
    out += b"\0" * ((-len(data)) % 4)
    return out


def build():
    buf = entry(".", b"", 0o040755, 1)
    # 结束项：名字为空、size 0
    trailer = MAGIC + b"".join(b"%08X" % v for v in (0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0))
    buf += trailer
    buf += b"\0" * ((-len(buf)) % 512)
    return buf


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "out/ramdisk.bin"
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    data = build()
    with open(out, "wb") as f:
        f.write(data)
    print(f"{out}: {len(data)} bytes")


if __name__ == "__main__":
    main()
