#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""Show an image in the current terminal with the kitty graphics protocol.

    show_image.py IMAGE [--title TEXT]

Fits the image to the terminal (keeping its aspect ratio), centres it, and
rescales it whenever the pane changes size. Press q, Esc or Ctrl-C to close.

What keeps it fast:

- macOS `sips` decodes the image once, shrunk to at least MASTER_PX on its long
  side, as BMP (cheaper for sips to write than PNG). A new split opens at 80x24
  and then grows, so a rendition sized for the first pane would be converted
  twice; MASTER_PX covers the usual final size. Only a pane that needs more
  pixels than the rendition has converts again.
- The pixels go to Rex as raw RGB (f=24), which Rex takes in ~3x faster than
  the same image as PNG.
- A resize re-places the image already in Rex (a=p) instead of uploading it
  again. The screen is cleared line by line (ESC[2K), because ESC[2J deletes
  placements and Rex then frees the image.
- A camera RAW that embeds a JPEG preview (ARW, NEF, ...) shows the preview at
  once (~20 ms instead of ~0.5 s to develop the RAW) and is developed only when
  the pane needs more pixels than the preview has.

Without sips only PNG works; it is sent as is. The image is transmitted inline
(t=d), so it also works when the terminal runs on another machine than the file.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import io
import os
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import tty
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

IMAGE_ID = 4242
PLACEMENT_ID = 1
CHUNK = 4096  # base64 bytes per escape sequence (the protocol's limit)
POLL_S = 0.1  # how often to check the pane size, in seconds
MASTER_PX = 2048  # smallest long side converted, so a growing pane reuses it
STEP_PX = 256  # larger renditions round their long side up to this
MIN_PREVIEW_PX = 512  # smaller embedded RAW previews (thumbnails) are skipped
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
# TIFF Orientation tag value -> clockwise degrees for `sips -r`. The preview
# JPEG inside a RAW has no orientation of its own; the RAW's IFD0 carries it.
ROTATE_CW = {3: 180, 6: 90, 8: 270}


@dataclass
class Picture:
    """Pixels ready to send: raw RGB/RGBA (fmt 24/32) or PNG bytes (fmt 100)."""

    data: bytes
    fmt: int
    w: int
    h: int
    full: bool  # the source's full resolution: nothing better to convert
    preview: bool = False  # a RAW's embedded preview, not the developed RAW

    @property
    def long(self) -> int:
        return max(self.w, self.h)


def png_size(data: bytes) -> tuple[int, int]:
    """(width, height) in pixels from the PNG IHDR chunk."""
    return struct.unpack(">II", data[16:24])


def jpeg_size(f: BinaryIO) -> tuple[int, int] | None:
    """(width, height) from a JPEG's SOF marker, or None if it is not a JPEG."""
    if f.read(2) != b"\xff\xd8":
        return None
    while True:
        head = f.read(4)
        if len(head) < 4 or head[0] != 0xFF:
            return None
        marker, length = head[1], int.from_bytes(head[2:4], "big")
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            h, w = struct.unpack(">HH", f.read(5)[1:5])
            return w, h
        f.seek(length - 2, 1)


def raw_preview(path: Path) -> tuple[bytes, int] | None:
    """The largest JPEG embedded in a TIFF-based RAW and the clockwise turn it
    needs, or None. Walks IFD0's chain and SubIFDs for JPEGInterchangeFormat
    (0x201) / length (0x202) pairs, where ARW and NEF keep their previews."""
    with path.open("rb") as f:
        head = f.read(8)
        if head[:4] not in (b"II*\0", b"MM\0*"):
            return None
        e = "<" if head[:2] == b"II" else ">"
        best: tuple[int, int] = (0, 0)  # (length, offset)
        orientation = 1
        todo, seen = [struct.unpack(e + "I", head[4:8])[0]], set()
        while todo and len(seen) < 32:
            off = todo.pop()
            if not off or off in seen:
                continue
            seen.add(off)
            f.seek(off)
            raw = f.read(2)
            if len(raw) < 2:
                continue
            (n,) = struct.unpack(e + "H", raw)
            entries = f.read(12 * n + 4)
            tags: dict[int, int] = {}
            for i in range(n):
                tag, typ, count = struct.unpack(e + "HHI", entries[12 * i : 12 * i + 8])
                value = entries[12 * i + 8 : 12 * i + 12]
                if tag == 0x14A:  # SubIFDs: one offset inline, more behind a pointer
                    if count == 1:
                        todo.append(struct.unpack(e + "I", value)[0])
                    else:
                        here = f.tell()
                        f.seek(struct.unpack(e + "I", value)[0])
                        todo += struct.unpack(e + "I" * count, f.read(4 * count))
                        f.seek(here)
                elif count == 1:
                    fmt = e + ("H" if typ == 3 else "I")
                    tags[tag] = struct.unpack(fmt, value[: struct.calcsize(fmt)])[0]
            if len(seen) == 1:
                orientation = tags.get(0x112, 1)
            if 0x201 in tags and 0x202 in tags and tags[0x202] > best[0]:
                best = (tags[0x202], tags[0x201])
            if len(entries) >= 12 * n + 4:
                todo.append(struct.unpack(e + "I", entries[12 * n : 12 * n + 4])[0])
        if not best[0]:
            return None
        f.seek(best[1])
        data = f.read(best[0])
    if data[:2] != b"\xff\xd8":
        return None
    return data, ROTATE_CW.get(orientation, 0)


def read_bmp(data: bytes) -> tuple[bytes, int, int, int]:
    """(pixels, kitty format 24/32, width, height) from a sips BMP."""
    off = int.from_bytes(data[10:14], "little")
    w = int.from_bytes(data[18:22], "little", signed=True)
    h = int.from_bytes(data[22:26], "little", signed=True)
    bpp = int.from_bytes(data[28:30], "little")
    if bpp not in (24, 32):
        raise ValueError(f"unsupported BMP depth {bpp}")
    px = bpp // 8
    row = w * px
    stride = (row + 3) & ~3
    top_down, h = h < 0, abs(h)
    body = data[off : off + stride * h]
    if stride != row or not top_down:
        rows = [body[y * stride : y * stride + row] for y in range(h)]
        body = b"".join(rows if top_down else reversed(rows))
    out = bytearray(len(body))  # BGR(A) -> RGB(A)
    out[0::px], out[1::px], out[2::px] = body[2::px], body[1::px], body[0::px]
    if px == 4:
        out[3::4] = body[3::4]
    return bytes(out), bpp, w, h


def sips_bmp(src: Path, long_px: int | None, rotate: int = 0) -> Picture:
    """Convert with sips to BMP (optionally shrinking and rotating) and load it."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "image.bmp"
        cmd = ["sips", "-s", "format", "bmp"]
        if long_px:
            cmd += ["-Z", str(long_px)]
        if rotate:
            cmd += ["-r", str(rotate)]
        subprocess.run([*cmd, str(src), "--out", str(out)], check=True, capture_output=True)
        data, fmt, w, h = read_bmp(out.read_bytes())
    return Picture(data, fmt, w, h, full=long_px is None)


class Source:
    """The image file and the best picture of it made so far."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.sips = shutil.which("sips") is not None
        with path.open("rb") as f:
            self.is_png = f.read(8) == PNG_MAGIC
        if not self.sips and not self.is_png:
            sys.exit(f"{path}: not a PNG and sips is not available to convert it")
        self.preview = raw_preview(path) if self.sips else None
        with path.open("rb") as f:
            head = f.read(24)
            f.seek(0)
            # From the header, before any EXIF rotation; None for other formats.
            self.header_size = png_size(head) if self.is_png else jpeg_size(f)
        self._long = max(self.header_size) if self.header_size else None
        self.pic: Picture | None = None
        self.uploaded = False  # Rex holds self.pic under IMAGE_ID
        self.need = 0  # long side the current pane needs, set by draw()

    def source_long(self) -> int:
        """Long side of the source in pixels (headers; sips for other formats)."""
        if self._long is None:
            out = subprocess.run(
                ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(self.path)],
                check=True, capture_output=True, text=True,
            ).stdout
            vals = [int(v) for v in out.split() if v.isdigit()]
            if len(vals) < 2:
                sys.exit(f"{self.path}: sips cannot read this image")
            self._long = max(vals[-2:])
        return self._long

    def short(self) -> bool:
        """True when the picture has fewer pixels than the pane needs and a
        better one can be made."""
        return self.pic is not None and not self.pic.full and self.pic.long < self.need

    def update(self, develop: bool) -> bool:
        """Make the picture good enough for self.need; True if it changed.

        A RAW's preview is used first even when it is too small, so something
        shows at once; the caller asks again with develop=True afterwards.
        """
        if self.pic is None and self.preview is not None:
            data, rotate = self.preview
            size = jpeg_size(io.BytesIO(data))
            if size and max(size) >= MIN_PREVIEW_PX:
                with tempfile.NamedTemporaryFile(suffix=".jpg") as tmp:
                    tmp.write(data)
                    tmp.flush()
                    self.pic = sips_bmp(Path(tmp.name), None, rotate)
                self.pic.full, self.pic.preview = False, True
                return True
        if self.pic is not None and (not self.short() or (self.pic.preview and not develop)):
            return False
        if not self.sips:  # a PNG, sent as is
            w, h = png_size(self.path.read_bytes())
            self.pic = Picture(self.path.read_bytes(), 100, w, h, full=True)
            return True
        src = self.source_long()
        target = min(-(-max(self.need, MASTER_PX) // STEP_PX) * STEP_PX, src)
        self.pic = sips_bmp(self.path, target if target < src else None)
        return True


def term_size() -> tuple[int, int, int, int]:
    """(cols, rows, width_px, height_px) of the terminal; pixels may be 0."""
    raw = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
    rows, cols, xpx, ypx = struct.unpack("HHHH", raw)
    return cols, rows, xpx, ypx


def write(data: bytes) -> None:
    os.write(sys.stdout.fileno(), data)


def transmit_and_place(pic: Picture, cols: int, rows: int) -> None:
    """Upload the picture and place it at the cursor over cols x rows (a=T).

    Upload and placement go in one command: Rex frees an image as soon as it
    has no placement, so a stored-then-placed image (a=t then a=p) can be gone
    by the time it is placed. Uploading under the same id replaces the old one.
    """
    b64 = base64.standard_b64encode(pic.data)
    size = f",s={pic.w},v={pic.h}" if pic.fmt != 100 else ""
    first = (
        f"a=T,f={pic.fmt}{size},t=d,i={IMAGE_ID},p={PLACEMENT_ID},"
        f"c={cols},r={rows},C=1,q=2"
    )
    parts = []
    for i in range(0, max(len(b64), 1), CHUNK):
        more = 1 if i + CHUNK < len(b64) else 0
        keys = f"{first},m={more}" if i == 0 else f"m={more},q=2"
        parts.append(b"\x1b_G" + keys.encode() + b";" + b64[i : i + CHUNK] + b"\x1b\\")
    write(b"".join(parts))


def draw(src: Source, title: str, develop: bool = False) -> None:
    """Draw the image fitted and centred, uploading it only when it changed."""
    cols, rows, xpx, ypx = term_size()
    # Cell size: real pixels when the terminal reports them, else a guess.
    cell_w = xpx / cols if xpx and cols else 10.0
    cell_h = ypx / rows if ypx and rows else 20.0
    avail_rows = max(rows - 1, 1)  # last row: title / hint
    box_w, box_h = cols * cell_w, avail_rows * cell_h
    known = (src.pic.w, src.pic.h) if src.pic else src.header_size
    if known:  # long side the fitted image covers
        w, h = known
        src.need = int(max(w, h) * min(box_w / w, box_h / h) + 0.5)
    else:
        src.need = int(max(box_w, box_h))
    changed = src.update(develop) or not src.uploaded
    src.uploaded = True
    pic = src.pic
    assert pic is not None  # update() always leaves a picture
    scale = min(box_w / pic.w, box_h / pic.h)
    c = max(int(pic.w * scale / cell_w), 1)
    r = max(int(pic.h * scale / cell_h), 1)
    top = (avail_rows - r) // 2
    left = (cols - c) // 2
    # Erase line by line: ESC[2J would delete the placement and Rex would free
    # the image, and then it could not be re-placed without uploading it again.
    out = [b"\x1b[%d;1H\x1b[2K" % (y + 1) for y in range(rows)]
    out.append(f"\x1b[{top + 1};{left + 1}H".encode())
    if not changed:
        out.append(
            # q=1: Rex answers only on error; main() re-uploads on ENOENT.
            f"\x1b_Ga=p,i={IMAGE_ID},p={PLACEMENT_ID},c={c},r={r},C=1,q=1\x1b\\".encode()
        )
    write(b"".join(out))
    if changed:
        transmit_and_place(pic, c, r)
    hint = f"{title}  (q to close)"[:cols]
    write(f"\x1b[{rows};1H\x1b[2m{hint}\x1b[0m".encode())


def main() -> None:
    p = argparse.ArgumentParser(description="Show an image in a Rex pane.")
    p.add_argument("image", type=Path)
    p.add_argument("--title", default=None, help="default: the file name")
    args = p.parse_args()
    if not args.image.is_file():
        sys.exit(f"no such file: {args.image}")
    src = Source(args.image)
    title = args.title or args.image.name

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    # SIGWINCH only interrupts the wait below; the size check redraws, so a
    # resize that sends no signal is still picked up within POLL_S.
    signal.signal(signal.SIGWINCH, lambda *_: None)
    # Normal screen, not the alternate one: Rex does not draw kitty images on
    # the alternate screen.
    write(b"\x1b[?25l")  # hide cursor
    try:
        tty.setraw(fd)
        size = None
        while True:
            if term_size() != size:
                size = term_size()
                draw(src, title)
            elif src.short():  # e.g. a RAW preview is up; develop the RAW
                draw(src, title, develop=True)
            try:
                ready, _, _ = select.select([fd], [], [], POLL_S)
            except InterruptedError:
                ready = []
            if ready:
                key = os.read(fd, 256)
                if b";ENOENT" in key:  # Rex dropped the image: upload again
                    src.uploaded, size = False, None
                    continue
                if key[:1] in (b"q", b"Q", b"\x03") or key == b"\x1b":
                    break
    finally:
        write(f"\x1b_Ga=d,d=I,i={IMAGE_ID},q=2\x1b\\".encode())
        write(b"\x1b[2J\x1b[H\x1b[?25h")
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
