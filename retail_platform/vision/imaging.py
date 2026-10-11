"""Image decoding for phone photos: upright, whatever the camera wrote into EXIF."""

from __future__ import annotations

import struct

import cv2
import numpy as np


def exif_orientation(data: bytes) -> int:
    """EXIF orientation tag (1–8) of a JPEG, 1 when absent or unreadable."""
    if data[:2] != b"\xff\xd8":
        return 1
    offset = 2
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            return 1
        marker = data[offset + 1]
        length = struct.unpack(">H", data[offset + 2:offset + 4])[0]
        if marker == 0xE1 and data[offset + 4:offset + 10] == b"Exif\x00\x00":
            tiff = offset + 10
            endian = "<" if data[tiff:tiff + 2] == b"II" else ">"
            ifd = tiff + struct.unpack(endian + "I", data[tiff + 4:tiff + 8])[0]
            if ifd + 2 > len(data):
                return 1
            for i in range(struct.unpack(endian + "H", data[ifd:ifd + 2])[0]):
                entry = ifd + 2 + 12 * i
                if entry + 12 > len(data):
                    return 1
                if struct.unpack(endian + "H", data[entry:entry + 2])[0] == 0x0112:
                    value = struct.unpack(endian + "H", data[entry + 8:entry + 10])[0]
                    return value if 1 <= value <= 8 else 1
            return 1
        if marker in (0xDA, 0xD9):  # image data starts: no EXIF before it
            return 1
        offset += 2 + length
    return 1


def decode_upright(data: bytes) -> np.ndarray | None:
    """BGR image rotated/flipped as its EXIF orientation says (applied exactly once)."""
    image = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
    if image is None:
        return None
    orientation = exif_orientation(data)
    if orientation in (2, 4, 5, 7):
        image = cv2.flip(image, 1)
    rotate = {3: cv2.ROTATE_180, 4: cv2.ROTATE_180, 5: cv2.ROTATE_90_CLOCKWISE, 6: cv2.ROTATE_90_CLOCKWISE,
              7: cv2.ROTATE_90_COUNTERCLOCKWISE, 8: cv2.ROTATE_90_COUNTERCLOCKWISE}.get(orientation)
    return cv2.rotate(image, rotate) if rotate is not None else image
