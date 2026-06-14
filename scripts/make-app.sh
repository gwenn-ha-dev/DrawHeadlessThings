#!/usr/bin/env bash
# Assembles DHTServer.app — a menu-bar agent that wraps the dht-server
# process — and packages it into a DMG.
#
# Ad-hoc signed (`codesign --sign -`): fine for your own machines. It is
# NOT notarized, so a DMG opened on someone else's Mac would be blocked by
# Gatekeeper. Distributing externally would need a Developer ID certificate
# and a notarytool pass added after the signing step below.
#
# Usage:  ./scripts/make-app.sh
# Output: output/DHTServer.app  and  output/DHTServer-<version>.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="DHTServer"
BUNDLE_ID="ai.drawheadlessthings.menubar"
CONFIG="release"
BUILD_DIR=".build/${CONFIG}"
RESOURCE_BUNDLE="DrawHeadlessThings_dht-server.bundle"

# Final artifacts land in output/ (gitignored). DMG staging uses a
# throwaway dir under .build/ — output/ is never wiped, only the .app
# inside it is replaced, so existing files there are left untouched.
OUT="${ROOT}/output"
APP="${OUT}/${APP_NAME}.app"
DMG_STAGE="${ROOT}/.build/dmg-stage"

VERSION="$(sed -nE 's/.*let dhtAPIVersion = "([0-9.]+)".*/\1/p' Sources/dht-server/DHTServer.swift)"
[ -n "$VERSION" ] || { echo "could not read dhtAPIVersion"; exit 1; }

echo "==> Building dht-server + dht-menubar (${CONFIG})…"
swift build -c "${CONFIG}" --product dht-server
swift build -c "${CONFIG}" --product dht-menubar

echo "==> Assembling ${APP_NAME}.app (v${VERSION})…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

# GUI executable -> Contents/MacOS
cp "${BUILD_DIR}/dht-menubar" "${APP}/Contents/MacOS/${APP_NAME}"

# Server binary + its SwiftPM resource bundle (Swagger UI + openapi.yaml).
# Both must sit side by side so dht-server's Bundle.module resolves /docs.
cp "${BUILD_DIR}/dht-server" "${APP}/Contents/Resources/dht-server"
cp -R "${BUILD_DIR}/${RESOURCE_BUNDLE}" "${APP}/Contents/Resources/"

# App icon. The .icns lives in Resources/ at the repo root (committed),
# regenerated from Resources/icon-source.png via scripts/make-icon.sh.
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>Draw Things Server</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing…"
# Sign the embedded server first, then the app (inside-out).
codesign --force --sign - "${APP}/Contents/Resources/dht-server"
codesign --force --deep --sign - "${APP}"

echo "==> Building DMG…"
rm -rf "${DMG_STAGE}"
mkdir -p "${DMG_STAGE}"
cp -R "${APP}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"
DMG="${OUT}/${APP_NAME}-${VERSION}.dmg"
rm -f "${DMG}"
# Size the staging image explicitly (content + 100 MB margin). hdiutil's
# auto-size for -srcfolder occasionally rounds a hair under the content near
# a sector boundary and fails mid-copy with a misleading "no space left on
# device" even with hundreds of GB free; the margin makes it deterministic.
STAGE_MB="$(du -sm "${DMG_STAGE}" | cut -f1)"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGE}" -ov \
  -format UDZO -size "$((STAGE_MB + 100))m" "${DMG}"
rm -rf "${DMG_STAGE}"

echo "==> Done:"
echo "    ${APP}"
echo "    ${DMG}"
