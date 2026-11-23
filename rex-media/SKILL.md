---
name: rex-media
description: Show an image (PNG, JPEG, PDF page, plot) or play a video (MP4, MOV, WebM, GIF, ...) in a Rex pane or tab using the kitty graphics protocol. Use when the user asks to show, open, view, play or display an image, plot, chart, video or recording "in Rex", "in a split", "to the right", "in a pane" or "in a tab", instead of the macOS `open` command.
---

# Show images and video in a Rex pane

Rex terminals support the kitty graphics protocol. Two viewers live in this
skill's directory; both fit the media to their pane, keep its aspect ratio,
follow the pane when it is resized (they check its size every 0.1 s), and quit
on `q`, Esc or Ctrl-C.

- `show_image.py IMAGE [--title TEXT]`: PNGs are sent as is; other formats are
  converted with `sips` first.
- `show_video.py VIDEO [--title TEXT] [--loop] [--max-width PX] [--inline]`:
  ffmpeg decodes frames scaled to the pane and each one overwrites the image's
  pixels in place at the video's frame rate (no flashing), dropping frames when
  the terminal falls behind. No audio.
  Keys: space pause/resume, left/right seek 5 s, r restart. Needs `ffmpeg` and
  `ffprobe` on the machine running the pane.

Run them in their own pane with Rex, never in your own pane (they take over the
terminal until they exit):

```sh
skill_dir="$HOME/.claude/skills/rex-media"
media=/absolute/path/to/file          # image or video

# Split to the right of your pane (the usual request). Keep focus on yours.
rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=right --ratio 50 \
  --label "$(basename "$media")" --focus=false --shell=none --json -- \
  uv run --script "$skill_dir/show_image.py" "$media"   # or show_video.py

# Or a new tab:
rex window new -s "$REX_SESSION" "$(basename "$media")" --shell=none --json -- \
  uv run --script "$skill_dir/show_video.py" "$media"
```

- Pass absolute paths: the pane's working directory may differ from yours.
- The pane closes itself when the viewer exits. Don't pass `--keep-open`.
- Choose the direction (`--split=right|left|above|below`) and `--ratio` from the
  request; tall images read better in a wider split (`--ratio 60`).
- To show something new in the same place, close the old viewer first
  (`rex send-key -s "$REX_SESSION" -b "$viewer_block" q`) and split again from
  `$REX_BLOCK`, so viewers don't pile up.
- Check it worked: `rex block call -s "$REX_SESSION" -b "$viewer_block" process`
  should show the viewer running, and a capture shows its status line on the
  last row. If it exited at once, capture the pane (`rex capture ... --trim`)
  for the error. Images and video frames never show up in a capture.
- Remote Rex servers (`rex -S HOST`): images are always sent inline. For video
  pass `--inline`: frames otherwise go as temp files (t=t), which only works when
  the terminal runs on the same machine.

## Protocol notes (Rex)

- Rex frees an image as soon as it has no placement, and clearing the screen
  (`ESC[2J`) removes placements. So upload and place in one command (`a=T`),
  not a separate upload (`a=t`) and placement (`a=p`), or the placement fails
  with `ENOENT`. Both viewers re-send on every draw.
- For video (or any image that changes), create the image and placement once
  (`a=T`) and then overwrite its pixels in place with an animation-frame edit
  (`a=f,r=1,X=1` with the same `i`, `s`, `v`; ~9000 edits/s). Re-sending the
  whole image under the same id each frame deletes and re-adds the placement,
  and the pane visibly flashes. Create a new image only when the pane size
  (and so `c`/`r`/`s`/`v`) changes.
- Supported: direct base64 (`t=d`, ~200 fps of 640x360 RGB), files (`t=f`),
  temp files (`t=t`, ~970 fps of 640x360; Rex deletes them after reading),
  PNG (`f=100`), RGB/RGBA (`f=24/32`), animation frames (`a=f`). Not supported:
  shared memory (`t=s`, `EINVAL: unsupported medium`).
- When debugging, drop `q=2` so Rex replies `OK` or an error per command, and
  read the replies in raw mode (follow the command with `ESC[c`; the device
  attributes reply marks the end).
