#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Herd.app"

cd "$ROOT"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Herd"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Herd"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Herd.app
  cp -R "$APP" /Applications/Herd.app
  echo "Installed to /Applications/Herd.app"
fi
