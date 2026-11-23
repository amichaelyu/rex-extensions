#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""Show an image in the current terminal with the kitty graphics protocol.

    show_image.py IMAGE [--title TEXT]

Fits the image to the terminal (keeping its aspect ratio), centres it, and
rescales it whenever the pane changes size. Press q, Esc or Ctrl-C to close. PNG is sent
as is; other formats (JPEG, GIF, TIFF, PDF, ...) are converted to PNG with
macOS `sips` first. The image is transmitted inline (t=d), so it also works
when the terminal runs on another machine than the file.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
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
from pathlib import Path

IMAGE_ID = 4242
CHUNK = 4096  # base64 bytes per escape sequence (the protocol's limit)
POLL_S = 0.1  # how often to check the pane size, in seconds


def png_bytes(path: Path) -> bytes:
    """The image as PNG bytes, converting with sips when it is not a PNG."""
    data = path.read_bytes()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return data
    if shutil.which("sips") is None:
        sys.exit(f"{path}: not a PNG and sips is not available to convert it")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "image.png"
        subprocess.run(
            ["sips", "-s", "format", "png", str(path), "--out", str(out)],
            check=True,
            capture_output=True,
        )
        return out.read_bytes()


def png_size(data: bytes) -> tuple[int, int]:
    """(width, height) in pixels from the PNG IHDR chunk."""
    return struct.unpack(">II", data[16:24])


def term_size() -> tuple[int, int, int, int]:
    """(cols, rows, width_px, height_px) of the terminal; pixels may be 0."""
    raw = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
    rows, cols, xpx, ypx = struct.unpack("HHHH", raw)
    return cols, rows, xpx, ypx


def write(data: bytes) -> None:
    os.write(sys.stdout.fileno(), data)


def transmit_and_place(b64: bytes, cols: int, rows: int) -> None:
    """Upload the PNG and place it at the cursor over cols x rows cells (a=T).

    Upload and placement go in one command: Rex frees an image as soon as it
    has no placement (e.g. after ESC[2J), so a stored-then-placed image (a=t
    then a=p) is gone by the next redraw.
    """
    chunks = [b64[i : i + CHUNK] for i in range(0, len(b64), CHUNK)] or [b""]
    for i, chunk in enumerate(chunks):
        more = 1 if i < len(chunks) - 1 else 0
        keys = (
            f"a=T,f=100,t=d,i={IMAGE_ID},c={cols},r={rows},C=1,q=2,m={more}"
            if i == 0
            else f"m={more},q=2"
        )
        write(b"\x1b_G" + keys.encode() + b";" + chunk + b"\x1b\\")


def draw(b64: bytes, img_w: int, img_h: int, title: str) -> None:
    """Clear the screen and draw the image fitted and centred."""
    cols, rows, xpx, ypx = term_size()
    # Cell aspect: real pixels when the terminal reports them, else ~1:2.
    cell_w = xpx / cols if xpx and cols else 1.0
    cell_h = ypx / rows if ypx and rows else 2.0
    avail_rows = max(rows - 1, 1)  # last row: title / hint
    scale = min(cols * cell_w / img_w, avail_rows * cell_h / img_h)
    c = max(int(img_w * scale / cell_w), 1)
    r = max(int(img_h * scale / cell_h), 1)
    top = (avail_rows - r) // 2
    left = (cols - c) // 2
    write(b"\x1b[2J")  # clears text and the old placement
    write(f"\x1b[{top + 1};{left + 1}H".encode())
    transmit_and_place(b64, c, r)
    hint = f"{title}  (q to close)"[:cols]
    write(f"\x1b[{rows};1H\x1b[2m{hint}\x1b[0m".encode())


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("image", type=Path)
    p.add_argument("--title", default=None, help="default: the file name")
    args = p.parse_args()
    if not args.image.is_file():
        sys.exit(f"no such file: {args.image}")
    data = png_bytes(args.image)
    img_w, img_h = png_size(data)
    b64 = base64.standard_b64encode(data)
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
                draw(b64, img_w, img_h, title)
            try:
                ready, _, _ = select.select([fd], [], [], POLL_S)
            except InterruptedError:
                ready = []
            if ready:
                key = os.read(fd, 64)
                if key[:1] in (b"q", b"Q", b"\x03") or key == b"\x1b":
                    break
    finally:
        write(f"\x1b_Ga=d,d=I,i={IMAGE_ID},q=2\x1b\\".encode())
        write(b"\x1b[2J\x1b[H\x1b[?25h")
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
