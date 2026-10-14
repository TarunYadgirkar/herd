#!/usr/bin/env bash
set -euo pipefail

# Builds Herd with a Developer ID signature, sends it to Apple's notary service, staples the ticket,
# and leaves build/Herd.zip ready to share. Other Macs then open it without a Gatekeeper warning.
#
# One-time setup on this Mac:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials herd-notary --apple-id <apple id> --team-id 5AKJYZ7USP
#      (asks for an app-specific password from account.apple.com)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Herd.app"
ZIP="$ROOT/build/Herd.zip"
PROFILE="${HERD_NOTARY_PROFILE:-herd-notary}"

IDENTITY="$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate for team 5AKJYZ7USP. Create one in Xcode first (see the top of this script)." >&2
  exit 1
fi

HERD_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "$ZIP"
