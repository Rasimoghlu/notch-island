#!/bin/bash
# Builds "build/Notch Island.app" with SwiftPM (no Xcode needed).
#   scripts/build-app.sh            release build into ./build
#   scripts/build-app.sh --install  also copy to ~/Applications and (re)launch it
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="Notch Island"
BUNDLE_ID="local.notchisland.NotchIsland"
VERSION="0.1.0"

# Newer Command Line Tools ship SDKs whose SwiftUI needs a macro plugin that only Xcode has
# ("plugin for module 'SwiftUIMacros' not found"). Without Xcode, fall back to the newest
# installed 26.x SDK, which still builds SwiftUI with Command Line Tools alone.
if [[ -z "${SDKROOT:-}" ]] && ! xcode-select -p 2>/dev/null | grep -q Xcode.app; then
  if [[ ! -d "$(xcrun --show-sdk-path)/../../usr/lib/swift/host/plugins/SwiftUIMacros" ]] \
     && ! ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins 2>/dev/null | grep -qi swiftui; then
    FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)"
    if [[ -n "$FALLBACK" ]]; then
      export SDKROOT="$FALLBACK"
      echo "Using $SDKROOT (the default SDK's SwiftUI needs Xcode's macro plugin)"
    fi
  fi
fi

swift build -c "$CONFIG" --product NotchIsland
swift build -c "$CONFIG" --product notch-hook
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NotchIsland" "$APP/Contents/MacOS/NotchIsland"
cp "$BIN/notch-hook" "$APP/Contents/MacOS/notch-hook"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>NotchIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. Not sandboxed (needs lsof, ~/.claude, kill).
codesign --force --sign - "$APP/Contents/MacOS/notch-hook"
codesign --force --sign - "$APP"
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x NotchIsland 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST/$APP_NAME.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/$APP_NAME.app"
  echo "Installed and launched: $DEST/$APP_NAME.app"
fi
