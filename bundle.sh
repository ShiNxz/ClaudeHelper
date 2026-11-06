#!/bin/bash
# Builds "Claude Helper.app" into ./build and signs it.
#
#   ./bundle.sh               build for this Mac's architecture
#   ./bundle.sh --universal   build arm64 + x86_64 and merge them with lipo
#   ./bundle.sh --dmg         also make build/Claude-Helper-<version>.dmg
#   ./bundle.sh --install     also copy the app to /Applications
#
# Environment:
#   VERSION        version string, default 0.1.0 (a leading "v" is dropped, so tags work)
#   BUILD_NUMBER   CFBundleVersion, default 1
#   SIGN_IDENTITY  "-" (default) for ad-hoc signing, or a "Developer ID Application: ..." identity,
#                  which also turns on the hardened runtime and a secure timestamp
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="io.github.shinxz.ClaudeHelper"
APP="build/Claude Helper.app"

UNIVERSAL=0; DMG=0; INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --dmg) DMG=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p build
if [ "$UNIVERSAL" = 1 ]; then
  BINS=()
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx14.0"
    swift build -c release --triple "$triple"
    BINS+=("$(swift build -c release --triple "$triple" --show-bin-path)/ClaudeHelper")
  done
  lipo -create "${BINS[@]}" -output build/ClaudeHelper
  BIN=build/ClaudeHelper
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/ClaudeHelper"
fi

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeHelper"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ClaudeHelper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Claude Helper</string>
  <key>CFBundleDisplayName</key><string>Claude Helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Unofficial tool, not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
echo "Built $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeHelper"), version $VERSION)"

if [ "$DMG" = 1 ]; then
  DMG_PATH="build/Claude-Helper-$VERSION.dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG_PATH"
  hdiutil create -volname "Claude Helper" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  fi
  echo "DMG $(pwd)/$DMG_PATH"
fi

if [ "$INSTALL" = 1 ]; then
  if pgrep -f "Claude Helper.app/Contents/MacOS/ClaudeHelper" >/dev/null; then
    echo "Quit the running Claude Helper first." >&2
    exit 1
  fi
  rm -rf "/Applications/Claude Helper.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Claude Helper.app"
fi
