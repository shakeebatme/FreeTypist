#!/bin/zsh
# Build FreeTypist and install it to a stable location.
#
# Why this exists: macOS grants Accessibility to a specific *code identity*.
# An ad-hoc signed app gets a new identity on every build, so permission is
# silently revoked each time. Signing with a real certificate and installing to
# a fixed path means you grant permission once.
set -e

ROOT="${0:A:h:h}"
cd "$ROOT"

DEST="/Applications/FreeTypist.app"
[ -w /Applications ] || DEST="$HOME/Applications/FreeTypist.app"
mkdir -p "$(dirname "$DEST")"

# Prefer a real certificate; fall back to ad-hoc. Resolution and the signing
# itself live in sign-app.sh, shared with make-dmg.sh and release.sh so they
# cannot drift apart on Sparkle's nested-code order.
IDENTITY=$(scripts/sign-app.sh --identity-only --adhoc-ok)
IDENTITY_NAME="$IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  IDENTITY_NAME="ad-hoc"
fi

echo "==> Building Release"
xcodegen generate >/dev/null
xcodebuild -project FreeTypist.xcodeproj -scheme FreeTypist \
  -configuration Release -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build >/tmp/freetypist-install.log 2>&1 \
  || { echo "Build failed. See /tmp/freetypist-install.log"; exit 1; }

echo "==> Installing to $DEST"
pkill -f "FreeTypist.app/Contents/MacOS/FreeTypist" 2>/dev/null || true
rm -rf "$DEST"
cp -R DerivedData/Build/Products/Release/FreeTypist.app "$DEST"

echo "==> Signing with: $IDENTITY_NAME"
# No secure timestamp here: it needs the network, and a local install does not
# need one. make-dmg.sh and release.sh pass --timestamp.
FREETYPIST_IDENTITY="$IDENTITY" scripts/sign-app.sh --adhoc-ok --no-timestamp "$DEST"

echo "==> Installed: $DEST"
echo
if [ "$IDENTITY" = "-" ]; then
  echo "NOTE: ad-hoc signed. You must re-grant Accessibility after every rebuild."
else
  echo "Signed with a certificate, so Accessibility permission survives rebuilds."
fi
echo "Grant access to exactly this app in:"
echo "  System Settings > Privacy & Security > Accessibility"
