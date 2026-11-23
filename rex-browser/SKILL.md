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

- WebKit draws into a borderless window at (-30000, -30000) that claims to be
  key, so the page acts focused. Two private WebKit setters, called only if
  present: `_setWindowOcclusionDetectionEnabled:` (keep the offscreen page
  rendering at full speed) and `_setOverrideDeviceScaleFactor:` (render at the
  pane's device pixels; Rex reports 2x cells as 14x28 px).
- Frames: `takeSnapshot` (2-7 ms) into an RGBA buffer, a row/edge diff against
  the last frame sent, then `a=T` once and `a=f,r=1,x,y,s,v,X=1` for the
  changed rectangle (temp files, `t=t`). 60 checks/s while active, 10/s idle.
- Input: SGR mouse in pixels (modes 1003, 1006, 1016) becomes NSEvents
  (clicks, drags, hover); wheel ticks scroll the element under the pointer
  through JavaScript after dispatching a cancelable `wheel` event; keys become
  key NSEvents with macOS key codes; bracketed paste inserts with
  `execCommand('insertText')`.
- Right clicks aren't forwarded (a context menu would block the offscreen
  window). JS alerts, confirms and prompts are answered automatically and shown
  in the bar.
