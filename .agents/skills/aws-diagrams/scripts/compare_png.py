#!/usr/bin/env python3
"""Compare two PNG renders of a figure, both composited onto white.

Use it for the control render: export the UNCHANGED .drawio with your setup
and compare it with the committed PNG before you trust a render of an edit.

    compare_png.py committed.png render.png

Prints whether the files are byte-identical, the two sizes, how many pixels
differ once both are flattened onto white, and the box around them. A
transparent pixel and a white pixel count as the same, which is the point:
comparing the alpha channel alone misses every change drawn in colour.

Exit code: 0 identical on white, 1 different, 2 unreadable.
Uses Pillow when it is installed, otherwise a slower standard-library decoder.
"""
import hashlib
import struct
import sys
import zlib


def _decode_stdlib(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, w = 8, [], None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError("only 8-bit RGB/RGBA, non-interlaced PNGs (what draw.io writes)")
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
        pos += 12 + n
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(b"".join(idat))
    stride = w * bpp
    prev = bytearray(stride)
    rows = []
    i = 0
    for _ in range(h):
        f = raw[i]
        cur = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if f == 1:
            for x in range(bpp, stride):
                cur[x] = (cur[x] + cur[x - bpp]) & 255
        elif f == 2:
            cur = bytearray((a + b) & 255 for a, b in zip(cur, prev))
        elif f == 3:
            for x in range(stride):
                left = cur[x - bpp] if x >= bpp else 0
                cur[x] = (cur[x] + ((left + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = cur[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                cur[x] = (cur[x] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        rows.append(bytes(cur))
        prev = cur
    if bpp == 4:
        flat = []
        for r in rows:
            out = bytearray(w * 3)
            for x in range(w):
                rr, gg, bb, aa = r[4 * x:4 * x + 4]
                out[3 * x] = (rr * aa + 255 * (255 - aa)) // 255
                out[3 * x + 1] = (gg * aa + 255 * (255 - aa)) // 255
                out[3 * x + 2] = (bb * aa + 255 * (255 - aa)) // 255
            flat.append(bytes(out))
        rows = flat
    return (w, h), rows


def _decode(path):
    try:
        from PIL import Image
    except ImportError:
        return _decode_stdlib(path)
    im = Image.open(path).convert("RGBA")
    bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
    rgb = Image.alpha_composite(bg, im).convert("RGB")
    w, h = rgb.size
    raw = rgb.tobytes()
    return (w, h), [raw[y * w * 3:(y + 1) * w * 3] for y in range(h)]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2:
        print(__doc__)
        return 2
    a, b = argv
    try:
        digests = []
        for p in (a, b):
            with open(p, "rb") as f:
                digests.append(hashlib.sha256(f.read()).hexdigest()[:16])
        ha, hb = digests
        if ha == hb:
            print(f"byte-identical ({ha})")
            return 0
        (sa, ra), (sb, rb) = _decode(a), _decode(b)
    except (OSError, ValueError, zlib.error) as exc:
        print(f"cannot read: {exc}")
        return 2
    print(f"sha256 {ha} vs {hb}; size {sa[0]}x{sa[1]} vs {sb[0]}x{sb[1]}")
    if sa != sb:
        print("sizes differ: a different border, scale or content extent")
        return 1
    n, box = 0, None
    for y, (x1, x2) in enumerate(zip(ra, rb)):
        if x1 == x2:
            continue
        for x in range(sa[0]):
            if x1[3 * x:3 * x + 3] != x2[3 * x:3 * x + 3]:
                n += 1
                box = (x, y, x, y) if box is None else (min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y))
    if not n:
        print("identical on white (the files differ only in encoding or transparency)")
        return 0
    print(f"{n} pixels differ on white, inside x {box[0]}..{box[2]}, y {box[1]}..{box[3]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
