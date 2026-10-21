#!/bin/zsh
# Pack an app into a compressed disk image with an Applications shortcut, so it
# can be installed by dragging it.
#
#   scripts/make-dmg.sh "build/Claude Profiles.app" build/Claude-Profiles-0.1.0.dmg
#
# It only uses hdiutil, which is part of macOS. The image is not signed or
# notarized: the app inside carries the same ad-hoc signature as everywhere else.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <path-to-app> <output.dmg>" >&2
  exit 2
fi

APP="$1"
OUTPUT="$2"
if [[ ! -d "$APP" ]]; then
  echo "the app does not exist: $APP" >&2
  exit 1
fi

NAME="$(basename "$APP" .app)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# ditto keeps the extended attributes, the symlinks and the signature intact.
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
hdiutil create \
  -volname "$NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$OUTPUT" >/dev/null

# The image must mount and hold the app; the check is cheap and catches a bad pack.
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/dmg-check.XXXXXX")"
hdiutil attach "$OUTPUT" -mountpoint "$MOUNT" -nobrowse -readonly -quiet
trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$MOUNT" "$STAGE"' EXIT
if [[ ! -d "$MOUNT/$NAME.app" || ! -L "$MOUNT/Applications" ]]; then
  echo "the disk image does not hold the app and the Applications shortcut" >&2
  exit 1
fi

echo "disk image: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
