#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""Play a video in the current terminal with the kitty graphics protocol.

    show_video.py VIDEO [--title TEXT] [--loop] [--max-width PX] [--inline]

ffmpeg decodes the video scaled to fit the pane (keeping its aspect ratio) and
each frame replaces the last at the video's frame rate; frames are dropped when
the terminal falls behind. The size follows the pane: a resize restarts the
decoder at the current time at the new size. No audio.

Keys: space / k pause/resume, left/right seek 1 s, j/l seek 5 s, 1-9 speed
1x-9x, r restart, f show in Finder, q / Esc / Ctrl-C quit.

Frames go to the terminal as temporary files (t=t), which the terminal reads and
deletes; that needs the terminal on this machine. --inline sends them as
base64 through the tty instead (t=d), for a terminal on another machine.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import tty
from pathlib import Path

IMAGE_ID = 4343
PLACEMENT_ID = 1
CHUNK = 4096  # base64 bytes per escape sequence (the protocol's limit)
# Seek step in seconds per key: arrows 1 s, j/l 5 s.
SEEK = {
    b"\x1b[C": 1.0, b"\x1bOC": 1.0, b"\x1b[D": -1.0, b"\x1bOD": -1.0,
    b"l": 5.0, b"L": 5.0, b"j": -5.0, b"J": -5.0,
}
HINT = "space/k pause  ←/→ 1s  j/l 5s  1-9 speed  r restart  f finder  q quit"


def probe(path: Path) -> tuple[int, int, float, float]:
    """(width, height, fps, duration_s) of the first video stream."""
    out = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate,r_frame_rate"
            ":format=duration",
            "-of", "json", str(path),
        ],
        check=True, capture_output=True, text=True,
    ).stdout
    info = json.loads(out)
    stream = info["streams"][0]

    def rate(s: str) -> float:
        num, _, den = s.partition("/")
        return float(num) / float(den or 1) if float(den or 1) else 0.0

    fps = rate(stream.get("avg_frame_rate", "0/1")) or rate(
        stream.get("r_frame_rate", "30/1")
    )
    duration = float(info.get("format", {}).get("duration", 0.0) or 0.0)
    return int(stream["width"]), int(stream["height"]), fps or 30.0, duration


def term_size() -> tuple[int, int, int, int]:
    """(cols, rows, width_px, height_px) of the terminal; pixels may be 0."""
    raw = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
    rows, cols, xpx, ypx = struct.unpack("HHHH", raw)
    return cols, rows, xpx, ypx


def reveal(path: Path) -> None:
    """Select the file in a Finder window (macOS `open -R`)."""
    try:
        subprocess.Popen(
            ["open", "-R", str(path.resolve())],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def write(data: bytes) -> None:
    os.write(sys.stdout.fileno(), data)


class Layout:
    """Where and how big the video is drawn for the current pane size."""

    def __init__(self, vid_w: int, vid_h: int, max_width: int) -> None:
        cols, rows, xpx, ypx = term_size()
        self.size = (cols, rows, xpx, ypx)
        self.rows = rows
        cell_w = xpx / cols if xpx and cols else 8.0
        cell_h = ypx / rows if ypx and rows else 16.0
        avail_rows = max(rows - 1, 1)  # last row: status line
        scale = min(cols * cell_w / vid_w, avail_rows * cell_h / vid_h)
        # Cells the picture covers on screen.
        self.cols = max(int(vid_w * scale / cell_w), 1)
        self.cell_rows = max(int(vid_h * scale / cell_h), 1)
        self.top = (avail_rows - self.cell_rows) // 2
        self.left = (cols - self.cols) // 2
        # Pixels decoded per frame: the on-screen size, capped, even.
        px_w = min(vid_w * scale, max_width, vid_w)
        px_h = px_w * vid_h / vid_w
        self.px_w = max(int(px_w) // 2 * 2, 2)
        self.px_h = max(int(px_h) // 2 * 2, 2)


class Decoder:
    """ffmpeg emitting raw RGB frames of layout.px_w x px_h from `start_s`."""

    def __init__(self, path: Path, layout: Layout, start_s: float) -> None:
        self.frame_bytes = layout.px_w * layout.px_h * 3
        self.proc = subprocess.Popen(
            [
                "ffmpeg", "-v", "error", "-nostdin",
                "-ss", f"{max(start_s, 0.0):.3f}", "-i", str(path),
                "-an", "-sn",
                "-vf", f"scale={layout.px_w}:{layout.px_h}:flags=bilinear",
                "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
            ],
            stdout=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
        )

    def read(self) -> bytes | None:
        """The next frame, or None at the end of the video."""
        buf = bytearray()
        out = self.proc.stdout
        while len(buf) < self.frame_bytes:
            chunk = out.read(self.frame_bytes - len(buf))
            if not chunk:
                return None
            buf += chunk
        return bytes(buf)

    def close(self) -> None:
        self.proc.kill()
        self.proc.wait()


class Screen:
    """Sends frames to the terminal at the layout's position.

    The first frame for a layout creates the image and its placement (a=T);
    later frames overwrite the image's pixels in place (a=f,r=1,X=1). Replacing
    the whole image each frame instead deletes and re-adds the placement, which
    flashes.
    """

    def __init__(self, inline: bool) -> None:
        self.inline = inline
        self.tmp_dir = Path(tempfile.gettempdir())
        self.sent: list[Path] = []  # temp files, removed at exit if unread
        self.placed: Layout | None = None  # layout the image was created for

    def frame(self, layout: Layout, rgb: bytes) -> None:
        size = f"f=24,s={layout.px_w},v={layout.px_h},i={IMAGE_ID}"
        if self.placed is layout:
            keys = f"a=f,r=1,X=1,{size},q=2"
        else:
            keys = (
                f"a=T,{size},p={PLACEMENT_ID},c={layout.cols},"
                f"r={layout.cell_rows},C=1,q=2"
            )
            write(f"\x1b[{layout.top + 1};{layout.left + 1}H".encode())
            self.placed = layout
        if self.inline:
            b64 = base64.standard_b64encode(rgb)
            chunks = [b64[i : i + CHUNK] for i in range(0, len(b64), CHUNK)]
            for i, chunk in enumerate(chunks):
                more = 1 if i < len(chunks) - 1 else 0
                head = f"{keys},t=d,m={more}" if i == 0 else f"m={more},q=2"
                write(b"\x1b_G" + head.encode() + b";" + chunk + b"\x1b\\")
            return
        # The terminal deletes a t=t file once read; its name must contain
        # "tty-graphics-protocol" and live in a temp directory.
        fd, name = tempfile.mkstemp(
            prefix="tty-graphics-protocol-", suffix=".rgb", dir=self.tmp_dir
        )
        with os.fdopen(fd, "wb") as f:
            f.write(rgb)
        self.sent.append(Path(name))
        if len(self.sent) > 256:
            self.sent = [p for p in self.sent if p.exists()]
        path_b64 = base64.standard_b64encode(name.encode())
        write(b"\x1b_G" + f"{keys},t=t".encode() + b";" + path_b64 + b"\x1b\\")

    def cleanup(self) -> None:
        for p in self.sent:
            p.unlink(missing_ok=True)


def clock(s: float) -> str:
    s = max(int(s), 0)
    return f"{s // 60}:{s % 60:02d}"


def status(
    layout: Layout, title: str, pos: float, dur: float, note: str, speed: float
) -> None:
    rate = f"  {speed:g}x" if speed != 1 else ""
    text = f"{title}  {clock(pos)} / {clock(dur)}{rate}{note}   {HINT}"
    cols = layout.size[0]
    write(f"\x1b[{layout.rows};1H\x1b[2K\x1b[2m{text[:cols]}\x1b[0m".encode())


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("video", type=Path)
    p.add_argument("--title", default=None, help="default: the file name")
    p.add_argument("--loop", action="store_true", help="restart at the end")
    p.add_argument(
        "--max-width", type=int, default=1280,
        help="cap on decoded frame width in pixels (default 1280)",
    )
    p.add_argument(
        "--inline", action="store_true",
        help="send frames as base64 (t=d), for a terminal on another machine",
    )
    args = p.parse_args()
    if not args.video.is_file():
        sys.exit(f"no such file: {args.video}")
    vid_w, vid_h, fps, duration = probe(args.video)
    title = args.title or args.video.name
    frame_s = 1.0 / fps

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    signal.signal(signal.SIGWINCH, lambda *_: None)  # just wakes select()
    screen = Screen(args.inline)
    write(b"\x1b[?25l\x1b[2J")
    decoder = None
    try:
        tty.setraw(fd)
        pos = 0.0  # playback time of the next frame, in seconds
        speed = 1.0  # playback rate; frame at pos is due at t0 + pos / speed
        t0 = 0.0  # wall time (monotonic) at which pos 0 plays
        paused = ended = synced = False
        layout = None
        last_status = -1.0
        while True:
            if layout is None or term_size() != layout.size:
                layout = Layout(vid_w, vid_h, args.max_width)
                write(b"\x1b[2J")
                if decoder:
                    decoder.close()
                decoder = Decoder(args.video, layout, pos)
                synced = False  # start the clock at the first frame
                ended = False
                last_status = -1.0
                if paused:  # show a still at the new size
                    still = decoder.read()
                    if still is not None:
                        screen.frame(layout, still)
                    status(layout, title, pos, duration, "  [paused]", speed)
            if not paused and not ended:
                rgb = decoder.read()
                if rgb is None:
                    if args.loop:
                        pos, layout = 0.0, None
                        continue
                    ended = True
                    status(layout, title, duration, duration, "  [end]", speed)
                else:
                    if not synced:  # ffmpeg start-up is not playback lag
                        t0 = time.monotonic() - pos / speed
                        synced = True
                    lag = time.monotonic() - (t0 + pos / speed)
                    if lag < frame_s / speed:  # on time: show it (else drop it)
                        screen.frame(layout, rgb)
                    pos += frame_s
                    if pos - last_status >= 0.5:
                        status(layout, title, pos, duration, "", speed)
                        last_status = pos
            # Wait for the next frame's due time, or for a key / resize.
            due = t0 + pos / speed
            wait = 0.1 if paused or ended else max(due - time.monotonic(), 0)
            try:
                ready, _, _ = select.select([fd], [], [], wait)
            except InterruptedError:
                ready = []
            if not ready:
                continue
            key = os.read(fd, 64)
            if key[:1] in (b"q", b"Q", b"\x03") or key == b"\x1b":
                break
            if key in (b" ", b"k", b"K"):
                if ended:
                    pos, paused, layout = 0.0, False, None
                    continue
                paused = not paused
                if not paused:
                    t0 = time.monotonic() - pos / speed
                    synced = True
                status(layout, title, pos, duration, "  [paused]" * paused, speed)
            elif key in (b"f", b"F"):
                reveal(args.video)
            elif key in (b"r", b"R"):
                pos, paused, layout = 0.0, False, None
            elif len(key) == 1 and key in b"123456789":
                speed = float(key)
                t0 = time.monotonic() - pos / speed  # keep pos, change rate
                status(layout, title, pos, duration, "  [paused]" * paused, speed)
            elif key in SEEK:
                pos = min(max(pos + SEEK[key], 0.0), max(duration - frame_s, 0.0))
                layout = None  # restart the decoder at the new time
    finally:
        if decoder:
            decoder.close()
        write(f"\x1b_Ga=d,d=I,i={IMAGE_ID},q=2\x1b\\".encode())
        write(b"\x1b[2J\x1b[H\x1b[?25h")
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        screen.cleanup()


if __name__ == "__main__":
    main()
