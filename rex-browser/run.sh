#!/bin/sh
# Builds rex-browser when its sources are newer than the binary, then runs it.
set -e
cd "$(dirname "$0")"
bin=.build/release/rex-browser
if [ ! -x "$bin" ] || [ -n "$(find Package.swift Sources -newer "$bin" 2>/dev/null | head -1)" ]; then
  swift build -c release -q >&2
fi
cd - >/dev/null
exec "$(dirname "$0")/$bin" "$@"
