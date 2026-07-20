#!/usr/bin/env python3
"""Exploratory parser for djay's custom 'TSAF' binary archive format.

Format hypothesis, derived empirically from hex inspection (see CLAUDE.md
'Découvertes — Volet 2' for the full writeup):

  header: b"TSAF" + 2 bytes + 2 bytes + 4 bytes (count?) + 4 bytes (0) + 4 bytes (field count?)
  then a flat stream of tokens:
    - class-name marker: 0x2b, then one string token (the archived class name)
    - string token: 0x08, then UTF-8 bytes, then 0x00 terminator
    - numeric token: 4-byte little-endian type code, then a type-specific
      fixed-width payload (no terminator)
  Ordinary fields appear as (VALUE token, KEY string token) pairs, i.e. the
  value is written before the field name that describes it.

This is read-only exploration code against a COPY of the database — never
run against the original ~/Music/djay database.
"""
import struct
import sys


def read_cstring(data, i):
    start = i
    while data[i] != 0:
        i += 1
    return data[start:i].decode("utf-8", errors="replace"), i + 1


def parse(data):
    assert data[0:4] == b"TSAF", "not a TSAF blob"
    tokens = []
    i = 20  # skip header (empirically 20 bytes: TSAF + 2+2+4+4+4)
    n = len(data)
    while i < n:
        tag = data[i]
        if tag == 0x2B:
            i += 1
            if i < n and data[i] == 0x08:
                s, i = read_cstring(data, i + 1)
                tokens.append(("CLASS", s))
            continue
        if tag == 0x08:
            s, i = read_cstring(data, i + 1)
            tokens.append(("STR", s))
            continue
        # Otherwise treat as a 4-byte little-endian type code + fixed payload.
        if i + 4 > n:
            tokens.append(("TRAILING_BYTES", data[i:].hex()))
            break
        type_code = struct.unpack_from("<I", data, i)[0]
        i += 4
        if type_code == 0x13:  # float32, confirmed via 'duration'
            val = struct.unpack_from("<f", data, i)[0]
            i += 4
            tokens.append(("FLOAT32", val))
        elif type_code == 0x0B or type_code == 0x0C:  # guess: 8-byte double
            val = struct.unpack_from("<d", data, i)[0]
            i += 8
            tokens.append((f"DOUBLE(type={type_code})", val))
        else:
            # Unknown numeric type — dump next 8 bytes raw for inspection,
            # and try a few interpretations, but don't advance blindly past
            # the whole blob; bail so we can look at the raw hex by hand.
            remaining = data[i:i + 16]
            tokens.append((f"UNKNOWN_TYPE(0x{type_code:x})", remaining.hex()))
            break
    return tokens


def pair_up(tokens):
    """Turn the flat (VALUE, KEY) token stream into a dict, best-effort."""
    fields = {}
    class_name = None
    j = 0
    if tokens and tokens[0][0] == "CLASS":
        class_name = tokens[0][1]
        j = 1
    while j + 1 < len(tokens):
        value_kind, value = tokens[j]
        key_kind, key = tokens[j + 1]
        if key_kind == "STR":
            fields[key] = value
            j += 2
        else:
            # Doesn't fit the (value, key) pattern — stop pairing, report rest raw.
            fields["_unparsed_from_index_%d" % j] = tokens[j:]
            break
    return class_name, fields


if __name__ == "__main__":
    for path in sys.argv[1:]:
        with open(path, "rb") as f:
            data = f.read()
        print(f"=== {path} ({len(data)} bytes) ===")
        toks = parse(data)
        cls, fields = pair_up(toks)
        print(f"class: {cls}")
        for k, v in fields.items():
            print(f"  {k!r}: {v!r}")
        print()
