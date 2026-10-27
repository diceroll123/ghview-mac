#!/usr/bin/env bash
# Assemble GHView.app from the SwiftPM release build (works with Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftUI needs full Xcode (the Command Line Tools lack the SwiftUI macro plugin).
# If xcode-select still points at the CLT, use Xcode.app for this build without sudo.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools ]]; then
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$x/Contents/Developer" ]]; then export DEVELOPER_DIR="$x/Contents/Developer"; break; fi
  done
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)/GHView"
APP="GHView.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GHView"

# SwiftPM resource bundles (e.g. Highlightr's highlight.js and themes). The generated accessor looks in
# Contents/Resources, and aborts at launch if the bundle is missing.
mkdir -p "$APP/Contents/Resources"
for b in "$(dirname "$BIN")"/*.bundle; do
  [[ -d "$b" && "$b" != *Tests.bundle ]] && cp -R "$b" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GHView</string>
  <key>CFBundleIdentifier</key><string>com.diceroll123.ghview-mac</string>
  <key>CFBundleExecutable</key><string>GHView</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
