# rex-extensions

Agent skills for the [Rex](https://www.superlogical.com/rex) terminal on macOS. Each one draws into a Rex pane with
the kitty graphics protocol.

- **rex-media**: shows an image (PNG, JPEG, PDF page, plot) or plays a video in a Rex pane, sized to the pane.
- **rex-browser**: a web browser in a Rex pane, using Safari's WebKit engine. It has an address bar, mouse and keyboard
  input, video, and keeps nothing (cookies, logins, cache) after the pane closes.

## Install

```sh
git clone git@github.com:amichaelyu/rex-extensions.git ~/Developer/rex-extensions
mkdir -p ~/.claude/skills
ln -s ~/Developer/rex-extensions/rex-media ~/.claude/skills/rex-media
ln -s ~/Developer/rex-extensions/rex-browser ~/.claude/skills/rex-browser
```

Then ask Claude Code to show an image or open a page "in a Rex split". To run them yourself:

```sh
uv run --script ~/.claude/skills/rex-media/show_image.py photo.png
uv run --script ~/.claude/skills/rex-media/show_video.py clip.mp4
~/.claude/skills/rex-browser/run.sh https://example.com
```

Requirements:

- rex-media: [uv](https://docs.astral.sh/uv/), and `ffmpeg` for video (`brew install ffmpeg`).
- rex-browser: macOS 14.4 or later and Xcode's Swift toolchain. `run.sh` builds it the first time it runs.

Each skill's `SKILL.md` has the details.
