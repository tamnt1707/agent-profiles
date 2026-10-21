#!/bin/bash
# Makes a release of Claude Profiles.
#
#   scripts/release.sh                 prepare everything and print the gh command
#   scripts/release.sh --create-draft  also publish the release as a draft
#
# The script never publishes without --create-draft. It
#   * reads the version from the VERSION file,
#   * checks that the git tree is clean and that the tag does not exist yet,
#   * runs the tests and builds the app with ./build-mac.sh --no-install,
#   * packs the app into build/Claude-Profiles-<version>-macos.zip,
#   * signs the archive with the private key of $RELEASE_KEY_FILE,
#   * prints the SHA-256 sums,
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

APP="build/Claude Profiles.app"
ARCHIVE="build/Claude-Profiles-$VERSION-macos.zip"
if [[ ! -d "$APP" ]]; then
  echo "the app was not built" >&2
  exit 1
fi

# 4. The archive of the app.
rm -f "$ARCHIVE" "$ARCHIVE.sig"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

# 5. The signature over the exact bytes of the archive.
swift scripts/release-sign.swift "$RELEASE_KEY_FILE" "$ARCHIVE" "$ARCHIVE.sig"

# 6. The sums, so they can be compared with the ones of GitHub.
echo ""
echo "--- SHA-256 ---"
shasum -a 256 "$ARCHIVE" "$ARCHIVE.sig"

# 7. The release command. It is only run with --create-draft, and then as a
#    draft: the notes and the assets can be looked at before it is public.
NOTES="build/release-notes-$VERSION.md"
{
  echo "## Claude Profiles $VERSION"
  echo ""
  git log --pretty=format:'- %s' "$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)"..HEAD
} > "$NOTES"

COMMAND=(gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sig" --repo "$REPO"
         --title "$TAG" --notes-file "$NOTES" --generate-notes)

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
