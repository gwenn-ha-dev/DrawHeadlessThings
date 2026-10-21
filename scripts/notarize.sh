#!/usr/bin/env bash
# Developer ID signature and notarization of what make-app.sh builds.
#
# make-app.sh assembles DHTServer.app and a DMG, both signed ad hoc: fine on
# the machine that built them, blocked by Gatekeeper anywhere else. This
# script runs it, then hands the app to the charter's signing tools:
#
#   signer.sh  re-signs inside out (Contents/Resources/dht-server, then the
#              app) with the Developer ID found in the keychain, hardened
#              runtime and timestamp, notarizes and staples the app;
#   dmg.sh     rebuilds output/DHTServer-<version>.dmg around the notarized
#              app, signs, notarizes and staples the image too.
#
# Neither process needs an entitlement: no sandbox, and the hardened runtime
# leaves Metal, sockets and spawning dht-server alone.
#
# Usage:  ./scripts/notarize.sh             build, sign, notarize
#         NO_NOTARY=1 ./scripts/notarize.sh  sign only (offline, or to iterate)
# Needs:  a "Developer ID Application" identity in the keychain, a notarytool
#         keychain profile ($NOTARY_PROFILE, default "siliconed"), and the
#         charter's tools ($CHARTE, default ../../Charte).
# Output: output/DHTServer.app, output/DHTServer-<version>.dmg (+ .sha256)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHARTE="${CHARTE:-${ROOT}/../../Charte}"
APP="${ROOT}/output/DHTServer.app"

for tool in signer.sh dmg.sh; do
  [ -x "${CHARTE}/outils/${tool}" ] || { echo "notarize: ${tool} not found under \$CHARTE/outils" >&2; exit 1; }
done

# Source paths are compiled into the binaries (C/C++ __FILE__ in the engine
# and its dependencies): map the checkout to "." so they stay relative.
DHT_SWIFT_BUILD_FLAGS="-Xswiftc -file-prefix-map -Xswiftc ${ROOT}=. -Xcc -ffile-prefix-map=${ROOT}=. -Xcxx -ffile-prefix-map=${ROOT}=." \
  "${ROOT}/scripts/make-app.sh"

echo "==> Developer ID signature…"
"${CHARTE}/outils/signer.sh" "${APP}"

echo "==> Notarized DMG…"
"${CHARTE}/outils/dmg.sh" "${APP}" "${ROOT}/output"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
DMG="DHTServer-${VERSION}.dmg"
(cd "${ROOT}/output" && shasum -a 256 "${DMG}" > "${DMG}.sha256")

echo "==> Gatekeeper:"
spctl -a -vv -t exec "${APP}" 2>&1 | grep -E 'accepted|rejected|source='
spctl -a -vv -t open --context context:primary-signature "${ROOT}/output/${DMG}" 2>&1 | grep -E 'accepted|rejected|source='
