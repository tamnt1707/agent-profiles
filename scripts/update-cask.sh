#!/bin/bash
# Points Casks/agent-profiles.rb at the version in VERSION and the SHA-256 of
# the archive that scripts/release.sh built.
#
#   scripts/update-cask.sh build/Agent-Profiles-<version>-macos.zip
#
# scripts/release.sh runs it. Commit the cask after the release is published, so
# that `brew install` finds an archive that exists.

set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE="${1:?usage: $0 <archive.zip>}"
[[ -f "$ARCHIVE" ]] || { echo "$ARCHIVE does not exist" >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < VERSION)"
SUM="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"

sed -i '' -E \
  -e "s/^  version \".*\"$/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"$/  sha256 \"$SUM\"/" \
  Casks/agent-profiles.rb
echo "Casks/agent-profiles.rb: version $VERSION, sha256 $SUM"
