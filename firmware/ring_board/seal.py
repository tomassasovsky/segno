"""Seal the ring XIAO's build into the files that install and update it (#1342).

    python3 -I firmware/ring_board/seal.py <ring_board.ino.bin> <out_dir>

Writes to out_dir:

  ring_board.bin       the over-the-link update: hashed, versioned and flagged
                       try-before-you-buy (TBYB), so the bootrom boots it once
                       on trial and keeps the previous image unless the Pi
                       confirms it. segno-ring-flash sends this one.
  ring_board.uf2       the same build without TBYB, for the one USB install.
                       A TBYB image only boots from a flash-update boot, so a
                       drag-and-drop install of it would be tried once and then
                       never booted again.
  partition_table.uf2  partition_table.json: the A/B pair both images use.
                       Installed over USB, before ring_board.uf2.
  version              "firmware=M.m size=N sha256=HEX" for ring_board.bin,
                       the marker the appliance's flasher reads.

The version is FW_MAJOR/FW_MINOR from ring_board.ino. picotool comes from the
arduino-pico core that compiled the sketch (or $PICOTOOL).
"""

import glob
import hashlib
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FLASH = 0x10000000
BLOCK_START, BLOCK_END = 0xFFFFDED3, 0xAB123579
ITEM_IMAGE_TYPE, ITEM_LAST = 0x42, 0xFF
IMAGE_TYPE_TBYB = 0x8000
SEARCH = 4096  # the bootrom looks for the first block in the first 4 KB


def fail(message):
    sys.exit("seal.py: " + message)


def version():
    with open(os.path.join(HERE, "ring_board.ino")) as f:
        source = f.read()
    found = [re.search(r"static const uint8_t FW_%s = (\d+);" % part, source) for part in ("MAJOR", "MINOR")]
    if not all(found):
        fail("FW_MAJOR/FW_MINOR not found in ring_board.ino")
    return tuple(int(m.group(1)) for m in found)


def picotool():
    if os.environ.get("PICOTOOL"):
        return os.environ["PICOTOOL"]
    home = os.path.expanduser("~")
    for root in (".arduino15", "Library/Arduino15"):
        found = sorted(glob.glob(os.path.join(home, root, "packages/rp2040/tools/pqt-picotool/*/picotool")))
        if found:
            return found[-1]
    fail("no picotool: install the arduino-pico core or set PICOTOOL")


def blocks(image):
    """The block loop that starts in the first 4 KB, as (offset, items)."""
    start = image.find(struct.pack("<I", BLOCK_START), 0, SEARCH)
    if start < 0:
        fail("no metadata block in the first 4 KB: not an RP2350 image")
    loop, at = [], start
    while True:
        items, p = [], at + 4
        while True:
            kind = image[p]
            size = image[p + 1] if not kind & 0x80 else struct.unpack_from("<H", image, p + 1)[0]
            items.append((kind, p))
            if kind == ITEM_LAST:
                link = struct.unpack_from("<i", image, p + 4)[0]
                p += 8
                break
            p += size * 4
        if struct.unpack_from("<I", image, p)[0] != BLOCK_END:
            fail("metadata block at %#x is not terminated" % at)
        loop.append((at, items))
        at += link
        if at == start:
            return loop
        if len(loop) > 16 or not 0 <= at < len(image):
            fail("metadata block loop is broken")


def image_type(image, offset):
    return struct.unpack_from("<H", image, offset + 2)[0]


def with_tbyb(image):
    """Sets TBYB in the first block's IMAGE_DEF. arduino-pico's flash image
    starts with its OTA stage, whose block is the one the bootrom finds;
    picotool seal copies its image type into the final block it appends. This
    is what the SDK's PICO_CRT0_IMAGE_TYPE_TBYB does at compile time."""
    patched = bytearray(image)
    first = blocks(image)[0]
    types = [p for kind, p in first[1] if kind == ITEM_IMAGE_TYPE]
    if len(types) != 1:
        fail("the first metadata block has no single IMAGE_TYPE item")
    struct.pack_into("<H", patched, types[0] + 2, image_type(image, types[0]) | IMAGE_TYPE_TBYB)
    return bytes(patched)


def seal(tool, source, out, major, minor):
    subprocess.run([tool, "seal", "--quiet", "--hash", "--major", str(major), "--minor", str(minor),
                    source, "-t", "bin", "-o", hex(FLASH), out, "-t", "bin"], check=True)
    with open(out, "rb") as f:
        sealed = f.read()
    # The bootrom uses the last IMAGE_DEF in the loop: the one seal appended.
    last = blocks(sealed)[-1][1]
    kinds = [kind for kind, _ in last]
    if ITEM_IMAGE_TYPE not in kinds or 0x47 not in kinds or 0x48 not in kinds:
        fail("%s has no hashed, versioned final IMAGE_DEF" % out)
    return sealed, image_type(sealed, dict(last)[ITEM_IMAGE_TYPE])


def main():
    if len(sys.argv) != 3:
        fail("usage: seal.py <ring_board.ino.bin> <out_dir>")
    built, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    tool = picotool()
    major, minor = version()
    with open(built, "rb") as f:
        plain = f.read()

    staged = os.path.join(out_dir, "ring_board.tbyb-unsealed.bin")
    with open(staged, "wb") as f:
        f.write(with_tbyb(plain))
    update = os.path.join(out_dir, "ring_board.bin")
    sealed, kind = seal(tool, staged, update, major, minor)
    os.remove(staged)
    if not kind & IMAGE_TYPE_TBYB:
        fail("ring_board.bin lost its TBYB flag")

    usb = os.path.join(out_dir, "ring_board.usb.bin")
    _, kind = seal(tool, built, usb, major, minor)
    if kind & IMAGE_TYPE_TBYB:
        fail("the USB image must not be TBYB")
    subprocess.run([tool, "uf2", "convert", "--quiet", usb, "-t", "bin", os.path.join(out_dir, "ring_board.uf2"),
                    "-o", hex(FLASH), "--family", "rp2350-arm-s"], check=True)
    os.remove(usb)

    subprocess.run([tool, "partition", "create", "--quiet", os.path.join(HERE, "partition_table.json"),
                    os.path.join(out_dir, "partition_table.uf2")], check=True)

    if len(sealed) > 512 * 1024:
        fail("the image is larger than one partition")
    with open(os.path.join(out_dir, "version"), "w") as f:
        f.write("firmware=%d.%d size=%d sha256=%s\n" % (major, minor, len(sealed), hashlib.sha256(sealed).hexdigest()))
    print("sealed ring firmware %d.%d: %d bytes" % (major, minor, len(sealed)))


if __name__ == "__main__":
    main()
