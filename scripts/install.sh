#!/bin/bash
# Installs Agent Profiles from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/tamnt1707/agent-profiles/main/scripts/install.sh | bash
#
# Options (after `bash -s --` when piped):
#   --version 0.6.0   install that version instead of the latest
#   --no-open         do not open the app when it is installed
#   --uninstall       remove the app (your profiles, keys and commands stay)
#
# The archive comes from the GitHub release over HTTPS. A file that curl
# downloads has no quarantine flag, so macOS does not ask to open it, and the
# script clears the flag anyway. Your data in ~/.claude-profiles is not touched.
# INSTALL_DIR=/some/folder puts the app there instead of /Applications.

set -euo pipefail

REPO="tamnt1707/agent-profiles"
APP="Agent Profiles.app"
VERSION=""
OPEN=1
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --no-open) OPEN=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Agent Profiles runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Agent Profiles needs a Mac with Apple Silicon."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$MAJOR" -ge 14 ]] || fail "Agent Profiles needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

# Where the app goes: /Applications when it can be written, else ~/Applications.
if [[ -n "${INSTALL_DIR:-}" ]]; then TARGET_DIR="$INSTALL_DIR"
elif [[ -w /Applications ]]; then TARGET_DIR="/Applications"
else TARGET_DIR="$HOME/Applications"; fi

quit_app() {
  if pgrep -x AgentProfiles >/dev/null 2>&1; then
    echo "Closing the running app..."
    osascript -e 'tell application "Agent Profiles" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x AgentProfiles >/dev/null 2>&1 || return 0
      sleep 0.5
    done
    pkill -x AgentProfiles || true
  fi
}

if [[ $UNINSTALL -eq 1 ]]; then
  quit_app
  removed=0
  for dir in /Applications "$HOME/Applications"; do
    if [[ -d "$dir/$APP" ]]; then rm -rf "$dir/$APP"; echo "Removed $dir/$APP"; removed=1; fi
  done
  [[ $removed -eq 1 ]] || echo "Agent Profiles is not installed."
  echo "Your profiles, keys and commands in ~/.claude-profiles stay."
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  echo "Looking for the latest release..."
  TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[^"]*"([^"]+)".*/\1/')"
  [[ -n "$TAG" ]] || fail "could not read the latest release of $REPO."
  VERSION="${TAG#v}"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$VERSION' is not a version like 0.6.0."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="Agent-Profiles-$VERSION-macos.zip"

echo "Downloading Agent Profiles $VERSION..."
curl -fL --progress-bar -o "$WORK/$ARCHIVE" \
  "https://github.com/$REPO/releases/download/v$VERSION/$ARCHIVE" \
  || fail "could not download $ARCHIVE (does v$VERSION exist?)."

ditto -x -k "$WORK/$ARCHIVE" "$WORK/unpacked"
[[ -d "$WORK/unpacked/$APP" ]] || fail "the archive does not hold $APP."

quit_app
mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_DIR/$APP"
ditto "$WORK/unpacked/$APP" "$TARGET_DIR/$APP"
xattr -dr com.apple.quarantine "$TARGET_DIR/$APP" 2>/dev/null || true

echo "Installed $TARGET_DIR/$APP (version $VERSION)."
if [[ -z "${INSTALL_DIR:-}" && "$TARGET_DIR" != "/Applications" ]]; then
  echo "(/Applications is not writable for this user, so the app went into ~/Applications.)"
fi
if [[ $OPEN -eq 1 ]]; then open "$TARGET_DIR/$APP"; fi
