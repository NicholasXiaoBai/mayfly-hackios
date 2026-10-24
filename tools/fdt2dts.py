#!/usr/bin/env python3
"""
fdt2dts.py —— 把 FDT(dtb) 转成可读的 DTS 文本。

只依赖标准库，Windows/Linux 都能跑。本机没有 dtc 时用它替代
`dtc -I dtb -O dts`。

用法:
    python tools/fdt2dts.py facts/mayfly-live.dtb > facts/mayfly-live.dts
    python tools/fdt2dts.py facts/mayfly-live.dtb --node /reserved-memory
"""
import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def be32(buf, off):
    return struct.unpack_from(">I", buf, off)[0]


def parse(path):
    with open(path, "rb") as f:
        buf = f.read()

    magic, totalsize, off_struct, off_strings = struct.unpack_from(">IIII", buf, 0)
    if magic != FDT_MAGIC:
        raise SystemExit(f"not an FDT: magic={magic:#x}")

    strings = buf[off_strings:]
    pos = off_struct
    stack = []
    nodes = []          # (depth, kind, payload)
    depth = 0

    def cstr(blob, start):
        end = blob.index(b"\x00", start)
        return blob[start:end].decode("utf-8", "replace"), end + 1

    while pos < len(buf):
        tok = be32(buf, pos)
        pos += 4
        if tok == FDT_BEGIN_NODE:
            name, pos = cstr(buf, pos)
            pos = (pos + 3) & ~3
            nodes.append((depth, "node", name or "/"))
            depth += 1
        elif tok == FDT_END_NODE:
            depth -= 1
            nodes.append((depth, "end", None))
        elif tok == FDT_PROP:
            length = be32(buf, pos)
            nameoff = be32(buf, pos + 4)
            pos += 8
            value = buf[pos:pos + length]
            pos = (pos + length + 3) & ~3
            pname, _ = cstr(strings, nameoff)
            nodes.append((depth, "prop", (pname, value)))
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise SystemExit(f"bad token {tok:#x} at {pos - 4}")
    return nodes


def fmt_value(v):
    if not v:
        return ""
    # 全可打印、以 NUL 结尾 -> 当一个或多个字符串
    if v.endswith(b"\x00") and all(32 <= c < 127 or c == 0 for c in v):
        parts = v.split(b"\x00")[:-1]
        if len(parts) == 1:
            return '"%s"' % parts[0].decode()
        return ", ".join('"%s"' % p.decode() for p in parts)
    # 4 字节对齐且不太长 -> cell 列表
    if len(v) % 4 == 0 and len(v) <= 256:
        cells = struct.unpack(">%dI" % (len(v) // 4), v)
        return "<" + " ".join(f"0x{c:x}" for c in cells) + ">"
    return "[" + " ".join(f"{b:02x}" for b in v) + "]"


def emit(nodes, only=None):
    out = ["/dts-v1/;", ""]
    depth = 0
    path = []
    skip_depth = None
    for d, kind, payload in nodes:
        if skip_depth is not None:
            if d < skip_depth:
                skip_depth = None
            else:
                if kind == "node":
                    pass
                continue
        if kind == "node":
            name = payload
            if only:
                candidate = "/" + "/".join(path + ([] if name == "/" else [name]))
                if d == 0 and name == "/":
                    out.append("/ {")
                else:
                    out.append("\t" * d + f"{name} {{")
                if only and only != candidate and not only.startswith(candidate) and not candidate.startswith(only):
                    skip_depth = d
                    out.pop()
                    continue
            else:
                out.append("/ {" if name == "/" else "\t" * d + f"{name} {{")
            path.append(name)
            depth = d + 1
        elif kind == "end":
            if path:
                path.pop()
            depth = max(0, depth - 1)
            out.append("\t" * depth + "};")
        else:
            pname, value = payload
            out.append("\t" * d + f"{pname} = {fmt_value(value)};")
    out.append("")
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    path = args[0]
    only = None
    if "--node" in args:
        only = args[args.index("--node") + 1]
    nodes = parse(path)
    print(emit(nodes, only))


if __name__ == "__main__":
    main()
