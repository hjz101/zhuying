#!/usr/bin/env python3
"""Generate an original, deterministic TrueType fixture using only the stdlib.

Each glyph is drawn from rectangles in an original 5 x 7 grid. No installed
font, third-party outline, compiler, or Python package is read by this script.
"""
from pathlib import Path
import struct


def pack(fmt, *values):
    return struct.pack(">" + fmt, *values)


def padded(data):
    return data + b"\0" * (-len(data) % 4)


def checksum(data):
    words = padded(data)
    return sum(struct.unpack(">" + "I" * (len(words) // 4), words)) & 0xFFFFFFFF


PATTERNS = {
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "5": ("11111", "10000", "10000", "11110", "00001", "00001", "11110"),
    "6": ("01110", "10000", "10000", "11110", "10001", "10001", "01110"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    "9": ("01110", "10001", "10001", "01111", "00001", "00001", "01110"),
}


def rectangles(pattern):
    contours = []
    for row, pixels in enumerate(pattern):
        start = None
        for col, filled in enumerate(pixels + "0"):
            if filled == "1" and start is None:
                start = col
            elif filled == "0" and start is not None:
                x0, x1 = 50 + start * 100, 50 + col * 100 - 10
                y0, y1 = (6 - row) * 100, (7 - row) * 100 - 10
                contours.append([(x0, y0), (x0, y1), (x1, y1), (x1, y0)])
                start = None
    return contours


def glyph(contours):
    if not contours:
        return b""
    points = [point for contour in contours for point in contour]
    xs, ys = zip(*points)
    data = pack("hhhhh", len(contours), min(xs), min(ys), max(xs), max(ys))
    endpoint = -1
    for contour in contours:
        endpoint += len(contour)
        data += pack("H", endpoint)
    data += pack("H", 0)  # No bytecode instructions.
    data += b"\x01" * len(points)  # Every point is on the outline.
    for coordinates in (xs, ys):
        previous = 0
        for coordinate in coordinates:
            data += pack("h", coordinate - previous)
            previous = coordinate
    return padded(data)


def names():
    strings = {
        0: "Original synthetic outlines for Zhuying automated tests; CC0.",
        1: "Zhuying Reader Test", 2: "Regular",
        3: "ZhuyingReaderTest-Regular-1.000", 4: "Zhuying Reader Test Regular",
        5: "Version 1.000", 6: "ZhuyingReaderTest-Regular",
        13: "Original test outlines dedicated to the public domain under CC0 1.0.",
        14: "https://creativecommons.org/publicdomain/zero/1.0/",
    }
    records, storage = b"", b""
    for name_id, text in sorted(strings.items()):
        encoded = text.encode("utf-16-be")
        records += pack("HHHHHH", 3, 1, 0x0409, name_id, len(encoded), len(storage))
        storage += encoded
    return pack("HHH", 0, len(strings), 6 + len(records)) + records + storage


def font():
    missing = rectangles(("11111", "10001", "10001", "10001", "10001", "10001", "11111"))
    outlines = [missing, []] + [rectangles(PATTERNS[ch]) for ch in "A0123456789"]
    count = len(outlines)
    glyf, offsets = b"", [0]
    for contours in outlines:
        glyf += glyph(contours)
        offsets.append(len(glyf))
    # Format 4 cmap: space -> glyph 1; digits -> 3...12; A -> 2.
    segments = [(32, 32, -31), (48, 57, -45), (65, 65, -63), (0xFFFF, 0xFFFF, 1)]
    cmap = pack("HHHHHHH", 4, 16 + 8 * len(segments), 0, 2 * len(segments), 8, 2, 0)
    cmap += b"".join(pack("H", end) for _, end, _ in segments) + pack("H", 0)
    cmap += b"".join(pack("H", start) for start, _, _ in segments)
    cmap += b"".join(pack("h", delta) for _, _, delta in segments) + b"\0\0" * len(segments)
    tables = {
        "head": pack("IIIIHHqqhhhhHHhhh", 0x00010000, 0x00010000, 0, 0x5F0F3CF5,
                     3, 1000, 0, 0, 50, 0, 540, 690, 0, 8, 2, 1, 0),
        "hhea": pack("IhhhH", 0x00010000, 800, -200, 0, 650)
                + pack("11hH", 0, 110, 540, 1, 0, 0, 0, 0, 0, 0, 0, count),
        "maxp": pack("I14H", 0x00010000, count, max(4 * len(c) for c in outlines),
                     max(len(c) for c in outlines), 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0),
        "OS/2": pack("HhHHH", 0, 620, 400, 5, 0)
                + pack("11h", 650, 600, 0, 75, 650, 600, 0, 350, 50, 250, 0)
                + bytes(10) + pack("4I", 1, 0, 0, 0) + b"YUES"
                + pack("HHHhhhHH", 0x0040, 32, 65, 800, -200, 0, 800, 200),
        "hmtx": b"".join(pack("Hh", 300 if i == 1 else 650, 0 if i == 1 else 50) for i in range(count)),
        "cmap": pack("HHHHI", 0, 1, 3, 1, 12) + cmap,
        "loca": b"".join(pack("I", offset) for offset in offsets),
        "glyf": glyf,
        "name": names(),
        "post": pack("IihhIIIII", 0x00030000, 0, -100, 50, 0, 0, 0, 0, 0),
    }
    assert len(tables["head"]) == 54 and len(tables["hhea"]) == 36
    assert len(tables["maxp"]) == 32 and len(tables["OS/2"]) == 78
    table_count = len(tables)
    power = 1 << (table_count.bit_length() - 1)
    directory = pack("IHHHH", 0x00010000, table_count, power * 16, power.bit_length() - 1, (table_count - power) * 16)
    offset = 12 + 16 * table_count
    records, body, head_offset = b"", b"", None
    for tag, data in sorted(tables.items()):
        records += tag.encode("ascii") + pack("III", checksum(data), offset, len(data))
        if tag == "head":
            head_offset = offset
        body += padded(data)
        offset += len(padded(data))
    result = bytearray(directory + records + body)
    adjustment = (0xB1B0AFBA - checksum(result)) & 0xFFFFFFFF
    result[head_offset + 8:head_offset + 12] = pack("I", adjustment)
    assert checksum(result) == 0xB1B0AFBA
    return bytes(result)


if __name__ == "__main__":
    output = Path(__file__).resolve().parent.parent / "ZhuyingTests" / "Fixtures" / "ReaderTestFont.ttf"
    output.parent.mkdir(parents=True, exist_ok=True)
    data = font()
    output.write_bytes(data)
    print(f"Generated {output.name}: {len(data)} bytes; PostScript name ZhuyingReaderTest-Regular")
