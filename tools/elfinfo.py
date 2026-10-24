#!/usr/bin/env python3
"""
elfinfo.py —— 读 aarch64 ELF 的两个关键值，替代 llvm-nm / llvm-readelf。

1. `_end` 的地址：shim.ld 把 image_size 定义成 _end，且 ABL 只复制文件本身，
   .bss 和栈必须由我们补齐成真实字节，否则运行到 .bss 就踩空。
2. 绝对重定位（R_AARCH64_ABS64，type 257）的数量：shim 被 ABL 放在任意地址
   且不做重定位，只要有一个绝对重定位，镜像就会在错误地址读写。
   K60 的 build.sh 用 readelf -r 数这个，这里用纯 Python 做。

用法:
    python tools/elfinfo.py out/shim.elf            # 打印 _end 与重定位统计
    python tools/elfinfo.py out/shim.elf --end      # 只打印 _end（十进制）
    python tools/elfinfo.py out/shim.elf --bin OUT  # 导出裸二进制（替代 objcopy -O binary）
"""
import struct
import sys

SHT_PROGBITS = 1
SHT_SYMTAB = 2
SHT_RELA = 4
SHF_ALLOC = 0x2
R_AARCH64_ABS64 = 257


def elf2bin(buf, secs, out, end=None):
    """把 SHF_ALLOC 的 PROGBITS 段按 sh_addr 摆好写成裸映像。

    shim.ld 里 `. = 0`，所以 sh_addr 就是文件内偏移。.bss 是 NOBITS，不占文件，
    但 ABL 只复制文件本身，所以最后要按 _end 补零。
    """
    alloc = [s for s in secs if s["type"] == SHT_PROGBITS and s["flags"] & SHF_ALLOC and s["size"]]
    alloc.sort(key=lambda s: s["addr"])
    top = max((s["addr"] + s["size"] for s in alloc), default=0)
    if end and end > top:
        top = end
    img = bytearray(top)
    for s in alloc:
        img[s["addr"]:s["addr"] + s["size"]] = buf[s["offset"]:s["offset"] + s["size"]]
    with open(out, "wb") as f:
        f.write(img)
    print(f"{out}: {len(img)} bytes ({len(alloc)} sections)")


def load(path):
    with open(path, "rb") as f:
        return f.read()


def sections(buf):
    (e_shoff,) = struct.unpack_from("<Q", buf, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", buf, 0x3A)
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from(
            "<IIQQQQIIQQ", buf, off
        )
        secs.append(dict(name=name, type=typ, flags=flags, addr=addr,
                         offset=offset, size=size, link=link, entsize=entsize))
    # 段名表
    strtab_off = secs[e_shstrndx]["offset"]
    for s in secs:
        end = buf.index(b"\0", strtab_off + s["name"])
        s["sname"] = buf[strtab_off + s["name"]:end].decode("ascii", "replace")
    return secs


def find_end(buf, secs):
    for s in secs:
        if s["type"] != SHT_SYMTAB:
            continue
        strtab = next(x for x in secs if x["offset"] == secs[s["link"]]["offset"])
        n = s["size"] // 24
        for i in range(n):
            off = s["offset"] + i * 24
            st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from(
                "<IBBHQQ", buf, off
            )
            end = buf.index(b"\0", strtab["offset"] + st_name)
            nm = buf[strtab["offset"] + st_name:end].decode("ascii", "replace")
            if nm == "_end":
                return st_value
    return None


def count_abs64(buf, secs):
    total = 0
    detail = []
    for s in secs:
        if s["type"] != SHT_RELA:
            continue
        n = s["size"] // 24
        c = 0
        for i in range(n):
            off = s["offset"] + i * 24
            r_offset, r_info, r_addend = struct.unpack_from("<QQq", buf, off)
            if (r_info & 0xFFFFFFFF) == R_AARCH64_ABS64:
                c += 1
        if c:
            detail.append((s["sname"], c))
        total += c
    return total, detail


def main():
    path = sys.argv[1]
    buf = load(path)
    secs = sections(buf)
    end = find_end(buf, secs)
    abs64, detail = count_abs64(buf, secs)
    if "--end" in sys.argv:
        print(end if end is not None else 0)
        return
    if "--bin" in sys.argv:
        out = sys.argv[sys.argv.index("--bin") + 1]
        elf2bin(buf, secs, out, end)
        return
    print(f"_end          = 0x{end:x} ({end})" if end is not None else "_end: not found")
    print(f"ABS64 relocs  = {abs64}")
    for name, c in detail:
        print(f"  {name}: {c}")
    sys.exit(1 if abs64 else 0)


if __name__ == "__main__":
    main()
