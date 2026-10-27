#!/usr/bin/env bash
# Regenerates Sources/GHCore/LanguageIconData.swift: colorless language logos from Simple Icons (CC0-1.0),
# optimized with SVGO and embedded as strings, so the app needs no icon files at runtime.
#
#   scripts/language-icons.sh
#
# Edit scripts/language-icons.json (GitHub language name -> Simple Icons slug) to add or drop a language.
set -euo pipefail
SIMPLE_ICONS_TAG=16.36.0
SVGO_VERSION=4.1.0

cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/raw" "$work/min"

python3 scripts/language-icons.py download "$work/raw" "$SIMPLE_ICONS_TAG"
npx --yes "svgo@$SVGO_VERSION" --config scripts/svgo.config.mjs -q -f "$work/raw" -o "$work/min"
python3 scripts/language-icons.py generate "$work/raw" "$work/min" "$SIMPLE_ICONS_TAG" "$SVGO_VERSION"
