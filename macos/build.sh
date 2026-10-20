#!/bin/bash
# Builds the Conflict Watch app (universal, ad-hoc signed) with the engines bundled
# in Contents/Resources/engine.
#   APP_NAME   bundle name           (default "Conflict Watch")
#   APP_DIR    output folder         (default ~/Applications)
#   BUNDLE_ID  bundle identifier, also the launchd label (default local.conflict-watch)
#   VERSION    CFBundleShortVersionString (default 1.0.0)
#   RELEASE=1  standalone build: config in ~/Library/Application Support/<APP_NAME>/,
#              bundled engines. Otherwise the app uses this checkout's engines and
#              CONFIG (default <checkout>/config.json).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP_NAME="${APP_NAME:-Conflict Watch}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
BUNDLE_ID="${BUNDLE_ID:-local.conflict-watch}"
VERSION="${VERSION:-1.0.0}"
APP="$APP_DIR/$APP_NAME.app"
BUILD="$(mktemp -d)"; trap 'rm -rf "$BUILD"' EXIT

if [ "${RELEASE:-0}" = 1 ]; then
  CONFIG_PATH=""; ENGINE_DIR=""
else
  CONFIG="${CONFIG:-$ROOT/config.json}"
  CONFIG_PATH="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
  ENGINE_DIR="$ROOT"
fi

C="$BUILD/app/Contents"
mkdir -p "$C/MacOS" "$C/Resources/engine"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -o "$BUILD/cw-$arch" ConflictWatch.swift
done
lipo -create -output "$C/MacOS/ConflictWatch" "$BUILD/cw-arm64" "$BUILD/cw-x86_64"

cp -R "$ROOT/run.sh" "$ROOT/config.example.json" "$ROOT/python" "$ROOT/typescript" "$C/Resources/engine/"
find "$C/Resources/engine" -name '__pycache__' -prune -exec rm -rf {} +

cat >"$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>ConflictWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CWConfigPath</key><string>$CONFIG_PATH</string>
  <key>CWEngineDir</key><string>$ENGINE_DIR</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUILD/app"
mkdir -p "$APP_DIR"
rm -rf "$APP"
cp -R "$BUILD/app" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "Built $APP"
