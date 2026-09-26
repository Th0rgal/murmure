#!/bin/bash
# Build Murmure.app (release) and sign it.
#
#   scripts/build-app.sh             # → build/Murmure.app
#   scripts/build-app.sh --install   # ...and copy to /Applications, then launch
#
# Signing: $MURMURE_SIGN_IDENTITY, else the first "Developer ID Application"
# identity, else "Apple Development", else ad-hoc. A stable identity matters:
# macOS ties the Accessibility / Microphone grants to it, so ad-hoc builds
# lose them on every rebuild.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

swift build -c release --arch arm64 --product Murmure
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Murmure"

APP="$ROOT/build/Murmure.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmure"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ID="${MURMURE_SIGN_IDENTITY:-}"
if [ -z "$ID" ]; then
  ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$ID" ]; then
  ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "$ID" ]; then
  codesign --force --options runtime --timestamp=none --entitlements Resources/Murmure.entitlements --sign "$ID" "$APP"
  echo "Signed with: $ID"
else
  codesign --force --entitlements Resources/Murmure.entitlements --sign - "$APP"
  echo "Signed ad-hoc (permissions reset on each rebuild)"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  pkill -x Murmure 2>/dev/null || true
  rm -rf /Applications/Murmure.app
  cp -R "$APP" /Applications/Murmure.app
  open /Applications/Murmure.app
  echo "Installed /Applications/Murmure.app"
fi
