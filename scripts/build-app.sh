#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Herd.app"
TEAM_ID="5AKJYZ7USP"
HELPER_ID="com.tarunyadgirkar.herd.helper"

# Developer ID can be notarized and shipped; Apple Development runs the root helper on this Mac; ad-hoc runs without it.
# Only this team's certificates count: the helper refuses an app signed by anyone else, so a stray identity would fail silently.
# An identity's name carries a certificate ID, not always the team, so the team is read from the certificate's OU.
belongs_to_team() {
  security find-certificate -c "$1" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$TEAM_ID"
}

signing_identity() {
  if [[ -n "${HERD_SIGN_IDENTITY:-}" ]]; then
    [[ "$HERD_SIGN_IDENTITY" == "-" ]] || belongs_to_team "$HERD_SIGN_IDENTITY" || { echo "HERD_SIGN_IDENTITY must belong to team $TEAM_ID" >&2; exit 1; }
    echo "$HERD_SIGN_IDENTITY"
    return
  fi
  local identities name
  identities="$(security find-identity -v -p codesigning)"
  for kind in "Developer ID Application" "Apple Development"; do
    while IFS= read -r name; do
      if [[ -n "$name" ]] && belongs_to_team "$name"; then echo "$name"; return; fi
    done < <(grep "\"$kind: " <<<"$identities" | sed -E 's/.*"(.*)"/\1/')
  done
  echo "No signing certificate for team $TEAM_ID; signing ad-hoc, so the root helper won't run." >&2
  echo "-"
}

cd "$ROOT"
swift build -c release --arch arm64 --product Herd
swift build -c release --arch arm64 --product HerdHelper
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN_DIR/Herd" "$APP/Contents/MacOS/Herd"
cp "$BIN_DIR/HerdHelper" "$APP/Contents/MacOS/HerdHelper"
cp "Resources/LaunchDaemons/$HELPER_ID.plist" "$APP/Contents/Library/LaunchDaemons/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 --output-format human-readable-text >/dev/null

IDENTITY="$(signing_identity)"
SIGN_FLAGS=(--force --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--options runtime --timestamp)
codesign "${SIGN_FLAGS[@]}" --identifier "$HELPER_ID" "$APP/Contents/MacOS/HerdHelper" >/dev/null
codesign "${SIGN_FLAGS[@]}" "$APP" >/dev/null
codesign --verify --strict --deep "$APP"
echo "Signed with: $IDENTITY"
echo "$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Herd.app
  cp -R "$APP" /Applications/Herd.app
  echo "Installed to /Applications/Herd.app"
fi
