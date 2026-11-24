---
name: rex-browser
description: Open a web page (a localhost dev server, the hub, any URL or local HTML file) in a native WebKit browser drawn inside a Rex pane with the kitty graphics protocol. Use when the user asks to open, show or preview a web page or site "in Rex", "in a split", "in a pane" or "to the right".
---

# Open web pages in a Rex pane

`rex-browser` loads the page in an offscreen WebKit view (Safari's engine, which
macOS already ships) and draws it into its own pane as one kitty-graphics image.
After the first frame it only sends the rectangle that changed, and nothing at
all while the page is still. The top row is the address bar.

Run it in its own pane, never in yours (it takes over its terminal):

```sh
dir="$HOME/.claude/skills/rex-browser"
rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=right --ratio 50 \
  --label browser --focus=false --shell=none --json -- \
  "$dir/run.sh" http://localhost:8888/
```

- `run.sh` builds the Swift package the first time and whenever its sources
  change (needs Xcode's Swift toolchain), then runs it.
- The argument is a URL, `host:port`, an absolute path, or search words. With
  none, the address bar opens for typing.
- Keys in the pane: ctrl+L address bar, ctrl+R reload, alt+←/→ back/forward,
  alt+= / alt+- / alt+0 zoom, ctrl+C or ctrl+Q quit. The bar's ← → ↻ are
  clickable, and clicking the address edits it.
- Check it's running with `rex block call -s "$REX_SESSION" -b "$block" process`.
  A capture shows only the address bar row; the page never shows in captures.
- To see what the pane shows, start it with `--log FILE` and send it SIGUSR1:
  it writes the last frame to `$TMPDIR/rex-browser-frame.png` and logs the path.
  The log also has snapshot and transfer rates every 2 s.
- To open a different page in the same browser, send ctrl+L, ctrl+U, the
  address and Enter: `rex send -s "$REX_SESSION" -b "$block" $'\x0c\x15localhost:3000\r'`.
- A Rex pane shown from another Mac: pass `--inline` (frames as base64 through
  the tty instead of temp files).

## How it works

- WebKit draws into a borderless, shadowless window that claims to be key (so
  the page acts focused), sits on the main screen below the desktop wallpaper
  (so it composites at Retina scale but is never visible) and is `.transient`
  (out of Mission Control). `_setWindowOcclusionDetectionEnabled:` keeps the
  covered page rendering at full speed; `_setOverrideDeviceScaleFactor:`
  matches the pane's device pixels (Rex reports 2x cells as 14x28 px).
- Capture: ScreenCaptureKit streams the window's GPU-composited frames
  (`getCurrentProcessShareableContent`, so no Screen Recording permission),
  only when something changed. `takeSnapshot` repaints the whole page in
  software (3 ms on Wikipedia, 370 ms on YouTube), so it is only the fallback
  if capture can't start (`REX_BROWSER_SNAPSHOT=1` forces it).
  `shouldBeOpaque` breaks the stream (error -3805); leave it off. A frame that
  arrives while the terminal hasn't read the last file is kept and sent next,
  since capture won't resend it.
- Frames: the captured sRGB pixels are read
  as they are (no redraw), diffed row by row against the last frame sent, and
  each changed band of rows goes out as `a=f,r=1,x,y,s,v,X=1` (RGB packed with
  vImage, sent as temp files `t=t`). A big change is checked for a scroll: row
  hashes vote on the shift, and every run of rows that moved is copied inside
  the terminal (`a=c` to a hidden gapless frame 2 and back, since a frame can't
  be composed onto itself), so only the newly exposed strip is sent.
- Pacing: a snapshot right after input, at most 120 a second; 60 checks a
  second while the page changes, 10 when it's still, 4 after 5 s. No frame is
  sent while the terminal still hasn't read the previous file.
- Measured in a 1400x2128 px pane on Wikipedia: idle 0.3% of a core; hover
  0.5 MB/s; a fast flick scroll 30-50 MB/s (full frames would be 110+); a small
  spinner 60 fps at 2 MB/s and 9% of a core; a full-screen animation 60 fps at
  537 MB/s and 24%.
- Input: SGR mouse in pixels (modes 1003, 1006, 1016) becomes NSEvents
  (clicks, drags, hover; runs of moves collapse to the last); wheel ticks add
  up and scroll the element under the pointer through one JavaScript call at a
  time, after dispatching a cancelable `wheel` event; keys become
  key NSEvents with macOS key codes; bracketed paste inserts with
  `execCommand('insertText')`.
- Nothing persists: the data store is `nonPersistent()`, so cookies, logins,
  storage and cache live only as long as the pane.
- Video: a document-start script hooks `requestVideoFrameCallback` on every
  playing video and messages each presented frame, which triggers a snapshot;
  the timer drops to 15 checks a second meanwhile. A 30 fps video arrives at
  30 updates a second in Rex.
- Resize: no debounce; the old image is re-placed over the new cell area at
  once (`a=p`, the terminal stretches it) and the sharp frame follows in about
  30 ms.
- The hidden window is `.transient` and `.ignoresCycle`, so it stays out of
  Mission Control and window cycling.
- Right clicks aren't forwarded (a context menu would block the offscreen
  window). JS alerts, confirms and prompts are answered automatically and shown
  in the bar.
