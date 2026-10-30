#!/bin/bash
# Makes a release of Agent Profiles.
#
#   scripts/release.sh                 prepare everything and print the gh command
#   scripts/release.sh --create-draft  also publish the release as a draft
#
# The script never publishes without --create-draft. It
#   * reads the version from the VERSION file,
#   * checks that the git tree is clean and that the tag does not exist yet,
#   * runs the tests and builds the app with ./build-mac.sh --no-install,
#   * packs the app into build/Agent-Profiles-<version>-macos.zip,
#   * signs the archive with the private key of $RELEASE_KEY_FILE,
#   * prints the SHA-256 sums and updates Casks/agent-profiles.rb with them,
#   * takes the release notes from the section of this version in CHANGELOG.md,
#   * prints (and with --create-draft runs) the `gh release create` command.
#
# The private key never enters the repository. See RELEASE.md.

set -euo pipefail
cd "$(dirname "$0")/.."

CREATE_DRAFT=0
for argument in "$@"; do
  case "$argument" in
    --create-draft) CREATE_DRAFT=1 ;;
    -h|--help)
      echo "usage: $0 [--create-draft]"
      exit 0
      ;;
    *)
      echo "unknown option: $argument" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f VERSION ]]; then
  echo "VERSION is missing" >&2
  exit 1
fi
if [[ ! -f RELEASE_REPO ]]; then
  echo "RELEASE_REPO is missing" >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
REPO="$(tr -d '[:space:]' < RELEASE_REPO)"
TAG="v$VERSION"

# 1. A clean tree and a tag that does not exist yet.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "the git tree is not clean, commit everything first" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "the tag $TAG already exists" >&2
  exit 1
fi

# 2. The private key of the releases.
if [[ -z "${RELEASE_KEY_FILE:-}" ]]; then
  echo "RELEASE_KEY_FILE is not set, see RELEASE.md" >&2
  exit 1
fi
if [[ ! -f "$RELEASE_KEY_FILE" ]]; then
  echo "the private key $RELEASE_KEY_FILE does not exist" >&2
  exit 1
fi

# 3. The tests and the build.
swift test
./build-mac.sh --no-install

APP="build/Agent Profiles.app"
ARCHIVE="build/Agent-Profiles-$VERSION-macos.zip"
DISK_IMAGE="build/Agent-Profiles-$VERSION.dmg"
if [[ ! -d "$APP" ]]; then
  echo "the app was not built" >&2
  exit 1
fi

# 4. The archive of the app.
rm -f "$ARCHIVE" "$ARCHIVE.sig"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

# 4b. The disk image for the first install by hand. The in-app updater uses the
#     signed archive above, not this image.
scripts/make-dmg.sh "$APP" "$DISK_IMAGE"

# 5. The signature over the exact bytes of the archive.
swift scripts/release-sign.swift "$RELEASE_KEY_FILE" "$ARCHIVE" "$ARCHIVE.sig"

# 6. The sums, so they can be compared with the ones of GitHub.
echo ""
echo "--- SHA-256 ---"
shasum -a 256 "$ARCHIVE" "$ARCHIVE.sig" "$DISK_IMAGE"

# 6b. The Homebrew cask takes the version and the sum of this archive. Commit it
#     after the release is published (see RELEASE.md).
scripts/update-cask.sh "$ARCHIVE"

# 7. The release command. It is only run with --create-draft, and then as a
#    draft: the notes and the assets can be looked at before it is public.
NOTES="build/release-notes-$VERSION.md"
# The notes are the section of this version in CHANGELOG.md: that is the one
# place where they are written, so the release never ships with a thin list of
# commit subjects.
if [[ ! -f CHANGELOG.md ]]; then
  echo "CHANGELOG.md does not exist" >&2
  exit 1
fi
awk -v version="$VERSION" '
  /^## \[/ { if (found) exit; if (index($0, "## [" version "]") == 1) { found = 1; next } }
  found { print }
  END { if (!found) exit 3 }
' CHANGELOG.md > "$NOTES" || {
  echo "CHANGELOG.md has no section '## [$VERSION]'. Write the notes of this version first." >&2
  exit 1
}
if [[ ! -s "$NOTES" ]]; then
  echo "the section of $VERSION in CHANGELOG.md is empty" >&2
  exit 1
fi

COMMAND=(gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sig" "$DISK_IMAGE" --repo "$REPO"
         --title "Agent Profiles $VERSION" --notes-file "$NOTES")

echo ""
if [[ $CREATE_DRAFT -eq 1 ]]; then
  echo "--- creating the draft release $TAG ---"
  "${COMMAND[@]}" --draft
  echo "the draft $TAG is ready, publish it on GitHub when it looks good"
else
  echo "--- the command that publishes the release ---"
  printf '%q ' "${COMMAND[@]}"
  echo ""
  echo ""
  echo "nothing was published. Run it as it is, or use"
  echo "  scripts/release.sh --create-draft"
  echo "to make a draft release on GitHub."
fi
