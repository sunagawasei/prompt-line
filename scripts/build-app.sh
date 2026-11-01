#!/bin/bash
# release ビルドを build/PromptLine.app にまとめて署名する。
# 署名は login keychain の自己署名証明書 "Prompt Line" を使い、無ければ ad-hoc にする
# (証明書で署名しないと、再ビルドのたびに Accessibility の許可が外れる)。
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE_ID="com.sunagawasei.prompt-line"
APP="build/PromptLine.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PromptLine"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PromptLine"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PromptLine</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Prompt Line</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAccessibilityUsageDescription</key><string>入力した文字を直前のアプリへ貼り付けるために使います。</string>
</dict>
</plist>
PLIST

if security find-certificate -c "Prompt Line" >/dev/null 2>&1; then
  IDENTITY="Prompt Line"
else
  IDENTITY="-"
  echo "warning: 証明書 'Prompt Line' が無いので ad-hoc 署名にします" >&2
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
echo "built: $APP (signed with: $IDENTITY)"
