#!/bin/zsh
# Build Claude Profiles.app và cài vào ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

cargo build --release

APP="$HOME/Applications/Claude Profiles.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp target/release/claude-profiles "$APP/Contents/MacOS/claude-profiles"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Profiles</string>
  <key>CFBundleDisplayName</key><string>Claude Profiles</string>
  <key>CFBundleIdentifier</key><string>local.claude-profiles</string>
  <key>CFBundleExecutable</key><string>claude-profiles</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Mở Terminal hoặc iTerm2 để chạy Claude Code với profile đã chọn.</string>
</dict>
</plist>
PLIST

# Ký ad-hoc để macOS chạy được app tự build
codesign --force --deep --sign - "$APP"

mkdir -p "$HOME/.claude-profiles/bin"
echo ""
echo "Đã cài: $APP"
echo "Mở bằng Spotlight (gõ: Claude Profiles) hoặc: open \"$APP\""
if [[ ":$PATH:" != *":$HOME/.claude-profiles/bin:"* ]]; then
  echo ""
  echo "Để gọi claude-<tên-profile> từ mọi terminal, chạy một lần:"
  echo "  echo 'export PATH=\"\$HOME/.claude-profiles/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
fi
