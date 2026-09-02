#!/usr/bin/env bash
# SwiftPM 빌드 결과를 OverlayPet.app 으로 감싼다 (Xcode 불필요, CLT 만 있으면 됨).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)/OverlayPet"

# 버전: 태그 기준 (예: v0.2.0, v0.2.0-3-g1a2b3c4 = 태그 뒤 3커밋)
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"

APP="build/OverlayPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/OverlayPet"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OverlayPet</string>
  <key>CFBundleDisplayName</key><string>OverlayPet</string>
  <key>CFBundleIdentifier</key><string>dev.local.overlaypet</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>OverlayPet</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "→ $APP"
echo "설치: cp -R $APP /Applications/   실행: open $APP"
