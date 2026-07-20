#!/usr/bin/env python3
"""Pragmatic field extractor for djay's 'TSAF' binary format.

Rather than fully reverse-engineer the grammar (nested objects / sets make
that slow going), this looks up each field NAME as a raw string token
(tag 0x08 + name + 0x00 terminator) and inspects the bytes immediately
before it, trying a few fixed-width numeric interpretations. Empirically
confirmed against known-good values (bpm=127.0 for a track we could verify
live) that this works reliably for scalar numeric fields.

Read-only exploration against a COPY of the database.
"""
import struct
import sys


def find_key_positions(data, name):
    """Find all occurrences of tag(0x08) + name + 0x00 (a field-name token)."""
    needle = b"\x08" + name.encode() + b"\x00"
    positions = []
    start = 0
    while True:
        idx = data.find(needle, start)
        if idx == -1:
            break
        positions.append(idx)
        start = idx + 1
    return positions


def guess_value_before(data, key_tag_offset):
    """Try a few fixed-width numeric interpretations of the bytes right
    before a field-name token, returning all candidates for inspection."""
    candidates = {}
    if key_tag_offset >= 4:
        b4 = data[key_tag_offset - 4:key_tag_offset]
        candidates["f32"] = struct.unpack("<f", b4)[0]
        candidates["u32"] = struct.unpack("<I", b4)[0]
        candidates["i32"] = struct.unpack("<i", b4)[0]
    if key_tag_offset >= 8:
        b8 = data[key_tag_offset - 8:key_tag_offset]
        candidates["f64"] = struct.unpack("<d", b8)[0]
    if key_tag_offset >= 1:
        candidates["u8"] = data[key_tag_offset - 1]
    return candidates


FIELDS_OF_INTEREST = [
    "bpm", "manualBPM", "manualBeatTime", "keySignatureIndex",
    "manualKeySignatureIndex", "energy", "playCount", "rating",
    "isStraightGrid", "highEQ", "midEQ", "lowEQ",
]


if __name__ == "__main__":
    for path in sys.argv[1:]:
        with open(path, "rb") as f:
            data = f.read()
        print(f"=== {path} ({len(data)} bytes) ===")
        for field in FIELDS_OF_INTEREST:
            for pos in find_key_positions(data, field):
                cands = guess_value_before(data, pos)
                print(f"  {field} @ {pos}: {cands}")
        print()
