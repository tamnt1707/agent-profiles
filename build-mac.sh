#!/bin/zsh
# Build Claude Profiles.app (SwiftPM) and install it into ~/Applications.
#
#   ./build-mac.sh              build the release and install into ~/Applications
#   ./build-mac.sh --no-install  build the release only, into ./build
#   ./build-mac.sh --dmg         build into ./build and also make a disk image
#                                (build/Claude-Profiles-<version>.dmg)
#
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=1
MAKE_DMG=0
for argument in "$@"; do
  case "$argument" in
    --no-install) INSTALL=0 ;;
    --dmg) INSTALL=0; MAKE_DMG=1 ;;
    -h|--help)
      echo "usage: $0 [--no-install | --dmg]"
      exit 0
      ;;
    *)
      echo "unknown option: $argument" >&2
      exit 2
      ;;
  esac
done

swift build -c release

BINARY=".build/release/ClaudeProfiles"
RESOURCE_BUNDLE=".build/release/ClaudeProfiles_ClaudeProfiles.bundle"
ICON="Sources/ClaudeProfiles/Resources/AppIcon.icns"

# The version of the app: the VERSION file is the one place where it is
# written down. The build number is the number of commits.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo "$VERSION")"

# The repository the app looks at for a new version. The environment variable
# wins, even when it is empty: that is how a build without the updater is
# made.
RELEASE_REPO_FILE="RELEASE_REPO"
if [[ -f "$RELEASE_REPO_FILE" ]]; then
  UPDATE_REPO_DEFAULT="$(tr -d '[:space:]' < "$RELEASE_REPO_FILE")"
else
  UPDATE_REPO_DEFAULT=""
fi
if [[ -n "${UPDATE_REPO+x}" ]]; then
  UPDATE_REPO="$UPDATE_REPO"
else
  UPDATE_REPO="$UPDATE_REPO_DEFAULT"
fi

# The public key that checks the signature of a release.
UPDATE_PUBLIC_KEY=""
if [[ -f "scripts/release-public-key.txt" ]]; then
  UPDATE_PUBLIC_KEY="$(tr -d '[:space:]' < scripts/release-public-key.txt)"
fi

# The values go into the Info.plist, so they are escaped.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}
APP_VERSION="$(xml_escape "$VERSION")"
APP_BUILD="$(xml_escape "$BUILD_NUMBER")"
APP_UPDATE_REPO="$(xml_escape "$UPDATE_REPO")"
APP_UPDATE_KEY="$(xml_escape "$UPDATE_PUBLIC_KEY")"

if [[ $INSTALL -eq 1 ]]; then
  APP="$HOME/Applications/Claude Profiles.app"
else
  APP="$PWD/build/Claude Profiles.app"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/ClaudeProfiles"
# The SwiftPM resource bundle holds the localized strings; the app finds it
# through Bundle.module and through Contents/Resources.
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# The permission dialog for Terminal / iTerm2, in both languages.
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/vi.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSAppleEventsUsageDescription" = "Claude Profiles opens Terminal or iTerm2 to run Claude Code with the selected profile.";
STRINGS
cat > "$APP/Contents/Resources/vi.lproj/InfoPlist.strings" <<'STRINGS'
"NSAppleEventsUsageDescription" = "Claude Profiles mở Terminal hoặc iTerm2 để chạy Claude Code với profile đã chọn.";
STRINGS

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Profiles</string>
  <key>CFBundleDisplayName</key><string>Claude Profiles</string>
  <key>CFBundleIdentifier</key><string>local.claude-profiles</string>
  <key>CFBundleExecutable</key><string>ClaudeProfiles</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>UpdateRepo</key><string>$APP_UPDATE_REPO</string>
  <key>UpdatePublicKey</key><string>$APP_UPDATE_KEY</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>vi</string>
  </array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Claude Profiles opens Terminal or iTerm2 to run Claude Code with the selected profile.</string>
</dict>
</plist>
PLIST

# Sign ad-hoc so macOS runs the self built app.
codesign --force --deep --sign - "$APP"

# Check that the localized strings really load from the assembled app.
echo ""
echo "--- self test of the assembled app ---"
"$APP/Contents/MacOS/ClaudeProfiles" --self-test

if [[ $INSTALL -eq 1 ]]; then
  mkdir -p "$HOME/.claude-profiles/bin"
  echo ""
  echo "Đã cài: $APP"
  echo "Mở bằng Spotlight (gõ: Claude Profiles) hoặc: open \"$APP\""
else
  echo ""
  echo "Đã build (chưa cài): $APP"
  echo "Chạy thử: open \"$APP\""
fi

if [[ $MAKE_DMG -eq 1 ]]; then
  echo ""
  echo "--- disk image ---"
  scripts/make-dmg.sh "$APP" "$PWD/build/Claude-Profiles-$VERSION.dmg"
fi

if [[ ":$PATH:" != *":$HOME/.claude-profiles/bin:"* ]]; then
  echo ""
  echo "Để gọi claude-<tên-profile> từ mọi terminal, chạy một lần:"
  echo "  echo 'export PATH=\"\$HOME/.claude-profiles/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
fi
