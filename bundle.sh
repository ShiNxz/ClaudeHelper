#!/bin/bash
# Builds "Relay.app" into ./build and signs it.
#
#   ./bundle.sh               build for this Mac's architecture
#   ./bundle.sh --universal   build arm64 + x86_64 and merge them with lipo
#   ./bundle.sh --dmg         also make build/Relay-<version>.dmg
#   ./bundle.sh --install     also copy the app to /Applications (replaces an older "Claude Helper.app")
#
# Environment:
#   VERSION        version string, default the latest git tag (a leading "v" is dropped, so tags work)
#   BUILD_NUMBER   CFBundleVersion, default 1
#   SIGN_IDENTITY  "-" (default) for ad-hoc signing, or a "Developer ID Application: ..." identity,
#                  which also turns on the hardened runtime and a secure timestamp
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# The bundle id and the data folder (~/Library/Application Support/ClaudeHelper) keep the old name,
# so saved logins and settings carry over from Claude Helper.
BUNDLE_ID="io.github.shinxz.ClaudeHelper"
NAME="Relay"
APP="build/$NAME.app"

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
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
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
echo "Built $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/$NAME"), version $VERSION)"

if [ "$DMG" = 1 ]; then
  DMG_PATH="build/$NAME-$VERSION.dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG_PATH"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  fi
  echo "DMG $(pwd)/$DMG_PATH"
fi

if [ "$INSTALL" = 1 ]; then
  # This app, or the same app under its old name. Claude's own helper processes run ".../MacOS/Claude Helper"
  # (with a space), so the old-name pattern never matches them.
  PATTERN="($NAME\.app/Contents/MacOS/$NAME|Claude Helper\.app/Contents/MacOS/ClaudeHelper)"
  WAS_RUNNING=0
  if pgrep -f "$PATTERN" >/dev/null; then
    WAS_RUNNING=1
    echo "Quitting the running $NAME"
    pkill -TERM -f "$PATTERN" || true
    for _ in $(seq 1 20); do
      pgrep -f "$PATTERN" >/dev/null || break
      sleep 0.5
    done
    if pgrep -f "$PATTERN" >/dev/null; then
      echo "$NAME did not quit. Quit it from its menu bar icon and run this again." >&2
      exit 1
    fi
  fi
  # The same app under its old name: two copies with one bundle id confuse Launch Services.
  if [ -f "/Applications/Claude Helper.app/Contents/MacOS/ClaudeHelper" ]; then
    rm -rf "/Applications/Claude Helper.app"
    echo "Removed /Applications/Claude Helper.app (the old name of this app)"
  fi
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/$NAME.app"
  if [ "$WAS_RUNNING" = 1 ]; then
    open "/Applications/$NAME.app"
    echo "Reopened $NAME"
  fi
fi
