#!/bin/zsh
# Build FreeTypist and package it as a distributable .dmg.
#
# The DMG is signed but NOT notarized: this keychain holds only Apple
# Development certificates, and notarization refuses those. Testers on other
# Macs must therefore clear the quarantine attribute by hand — see INSTALL.txt,
# which is written into the image.
set -e

ROOT="${0:A:h:h}"
cd "$ROOT"

# Identity resolution and the app signing itself both live in sign-app.sh, so
# this script and release.sh cannot drift apart on Sparkle's signing order.
IDENTITY=$(scripts/sign-app.sh --identity-only)

STAGE="$(mktemp -d /tmp/freetypist-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Building Release"
xcodegen generate >/dev/null
xcodebuild -project FreeTypist.xcodeproj -scheme FreeTypist \
  -configuration Release -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build >/tmp/freetypist-dmg-build.log 2>&1 \
  || { echo "Build failed. See /tmp/freetypist-dmg-build.log" >&2; exit 1; }

APP_SRC="DerivedData/Build/Products/Release/FreeTypist.app"
[ -d "$APP_SRC" ] || { echo "Missing $APP_SRC" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo "0.0")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo "0")

VOLUME="FreeTypist $VERSION"
SRCDIR="$STAGE/src"
mkdir -p "$SRCDIR"
cp -R "$APP_SRC" "$SRCDIR/FreeTypist.app"
APP="$SRCDIR/FreeTypist.app"

echo "==> Signing"
scripts/sign-app.sh "$APP"

ln -s /Applications "$SRCDIR/Applications"

cat > "$SRCDIR/INSTALL.txt" <<'TXT'
FreeTypist — installing on a Mac that is not the build machine
==============================================================

Requires an Apple Silicon Mac running macOS 14 or later.

1. Drag FreeTypist.app onto the Applications folder in this window.

2. This build is signed but NOT notarized, so macOS quarantines it and will
   refuse to open it ("damaged", or "cannot be opened"). Clear the quarantine
   flag in Terminal:

       xattr -dr com.apple.quarantine /Applications/FreeTypist.app

   Do this before the first launch. Right-click > Open does not work for a
   non-notarized app on recent macOS.

3. Launch it from /Applications — not from a Downloads folder or a disk image.
   macOS attaches permissions to a code identity at a path; running a copy
   elsewhere means granting permission all over again.

4. Grant access in System Settings > Privacy & Security > Accessibility, and
   again under Screen Recording if the app asks. FreeTypist has no Dock icon:
   it lives in the menu bar.

5. On first run it downloads a GGUF model into Application Support. That is the
   only network request the app makes; after it completes, nothing you type
   leaves the machine.

Updates: once installed, FreeTypist can check for new versions itself —
Settings > General > Updates, or "Check for Updates" in the menu bar. An update
it installs does not need the xattr step again.

Uninstalling: quit from the menu bar, then delete /Applications/FreeTypist.app
and ~/Library/Application Support/FreeTypist.
TXT

DIST="$ROOT/dist"
mkdir -p "$DIST"
DMG="$DIST/FreeTypist-$VERSION.dmg"
rm -f "$DMG"

echo "==> Building disk image"
hdiutil create -volname "$VOLUME" -srcfolder "$SRCDIR" \
  -ov -format UDZO -quiet "$DMG"

codesign --force --timestamp --sign "$IDENTITY" "$DMG"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo
echo "==> $DMG  ($SIZE, version $VERSION build $BUILD)"
echo
echo "NOT notarized — this keychain has no Developer ID Application certificate."
echo "Testers must run: xattr -dr com.apple.quarantine /Applications/FreeTypist.app"
