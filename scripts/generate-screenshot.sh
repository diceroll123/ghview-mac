#!/usr/bin/env bash
# Launches GHView with built-in fake data (no gh account needed, no network calls except loading the
# avatars themselves) and captures its window to a PNG. Useful for README/store screenshots that need to
# stay up to date with the UI without exposing anyone's real PRs.
#
# Usage: scripts/generate-screenshot.sh [output.png]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-screenshot.png}"
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"

# SwiftUI needs full Xcode (the Command Line Tools lack the SwiftUI macro plugin).
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools ]]; then
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$x/Contents/Developer" ]]; then export DEVELOPER_DIR="$x/Contents/Developer"; break; fi
  done
fi

# A debug build, deliberately: the demo-data bootstrap this relies on is compiled out of release builds
# (see GHViewApp.swift and Tests/GHViewTests/ReleaseHygieneTests.swift).
swift build
BIN="$(swift build --show-bin-path)/GHView"

echo "Launching GHView with demo data..."
GHVIEW_DEMO_FIXTURES=1 "$BIN" &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

# Poll rather than a fixed sleep: a cold first launch (XPC/TCC setup, avatar loads) can take noticeably
# longer than a warm one.
WINDOW_ID=""
for _ in $(seq 1 30); do
  sleep 1
  osascript -e 'tell application "System Events" to tell process "GHView" to set frontmost to true' 2>/dev/null || true
  WINDOW_ID="$(osascript -e '
tell application "System Events"
  tell process "GHView"
    return id of window 1
  end tell
end tell' 2>/dev/null || true)"
  [[ -n "$WINDOW_ID" ]] && break
done

if [[ -z "$WINDOW_ID" ]]; then
  echo "Could not find GHView's window after 30s; is it running in a GUI session?" >&2
  exit 1
fi

sleep 2 # let avatars finish loading before the capture

screencapture -o -l "$WINDOW_ID" "$OUT"
kill "$PID" 2>/dev/null || true
trap - EXIT

echo "Saved $OUT"
