#!/usr/bin/env python3
"""Soft telecine on an MPEG-2 elementary stream, as DVD authoring's pulldown tools (DGPulldown) apply it.

The input is 23.976 progressive MPEG-2 coded without B-frames (coded order = display order). The output declares
29.97 carriage and asks the display to repeat fields in the 3:2 pattern, with every bit changed in place
(H.262 / ISO/IEC 13818-2):

  sequence_header (6.2.2.1)               frame_rate_code 1 (24000/1001) -> 4 (30000/1001)
  sequence_extension (6.2.2.3)            progressive_sequence -> 0 (repeat_first_field then means one field)
  picture_coding_extension (6.2.3.1)      top_field_first, repeat_first_field per picture, progressive_frame = 1:
                                          T B T | B T | B T B | T B   (3 + 2 + 3 + 2 fields per 4 pictures)

Usage: mpeg2_pulldown.py in.m2v out.m2v
"""
import sys

PATTERN = [(1, 1), (0, 0), (0, 1), (1, 0)]  # (top_field_first, repeat_first_field), display order

data = bytearray(open(sys.argv[1], "rb").read())
picture = -1
i = 0
seq = ext_seq = ext_pic = 0
while True:
    i = data.find(b"\x00\x00\x01", i)
    if i < 0 or i + 8 > len(data):
        break
    code = data[i + 3]
    p = i + 4
    if code == 0xB3:  # sequence_header: frame_rate_code is the low nibble of byte 3
        assert data[p + 3] & 0x0F == 1, "input must be 24000/1001"
        data[p + 3] = (data[p + 3] & 0xF0) | 4
        seq += 1
    elif code == 0x00:  # picture_header: the next picture
        picture += 1
    elif code == 0xB5:
        ext_id = data[p] >> 4
        if ext_id == 1:  # sequence_extension: progressive_sequence is bit 12
            data[p + 1] &= ~0x08 & 0xFF
            ext_seq += 1
        elif ext_id == 8:  # picture_coding_extension: bit 24 top_field_first, 30 repeat_first_field, 32 progressive_frame
            tff, rff = PATTERN[picture % 4]
            assert data[p + 4] & 0x80, "pictures must be coded progressive"
            data[p + 3] = (data[p + 3] & ~0x82 & 0xFF) | (0x80 if tff else 0) | (0x02 if rff else 0)
            ext_pic += 1
    i += 4

assert seq and ext_seq and ext_pic == picture + 1, (seq, ext_seq, ext_pic, picture)
open(sys.argv[2], "wb").write(data)
print(f"{ext_pic} pictures, {seq} sequence headers")
