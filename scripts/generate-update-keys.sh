#!/bin/zsh
# Create the EdDSA key pair Sparkle uses to verify updates, once per project.
#
# The private half goes into the login keychain and is never written to the
# repo; the public half is written into FreeTypist/Info.plist, which ships
# inside every build. An update is only accepted if it was signed by the
# private key matching the public key already on the user's disk — which is
# what makes it safe to serve updates over a URL anyone could impersonate.
#
# Back the private key up somewhere safe. Losing it means no existing install
# can ever be updated again: they will all reject anything signed by a new key,
# and the only way out is asking every user to download the app by hand.
set -e

ROOT="${0:A:h:h}"
cd "$ROOT"

TOOLS=""
for dir in "$ROOT"/DerivedData/SourcePackages/artifacts/*/Sparkle/bin(N/); do
  TOOLS="$dir"
  break
done
if [ -z "$TOOLS" ]; then
  echo "Sparkle's command line tools are not unpacked yet." >&2
  echo "Build once first — scripts/install.sh, or xcodebuild — then re-run this." >&2
  exit 1
fi

PLIST="$ROOT/FreeTypist/Info.plist"
EXISTING=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null || echo "")
if [ -n "$EXISTING" ]; then
  echo "Info.plist already carries a public key:"
  echo "    $EXISTING"
  echo
  echo "Leaving it alone. Replacing it would orphan every install that has the"
  echo "old one — they would reject all future updates."
  exit 0
fi

# Generates a key pair if the keychain has none; otherwise reuses it. macOS may
# ask for permission to access the keychain.
if ! PUBKEY=$("$TOOLS/generate_keys" -p 2>/dev/null); then
  echo "==> Generating a key pair (a keychain prompt may appear)"
  "$TOOLS/generate_keys"
  PUBKEY=$("$TOOLS/generate_keys" -p)
fi

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBKEY" "$PLIST"

echo
echo "==> Wrote SUPublicEDKey to FreeTypist/Info.plist"
echo "    $PUBKEY"
echo
echo "Commit that change — every build from here on must carry this key."
echo
echo "Back up the private key now, and keep it out of the repo:"
echo "    $TOOLS/generate_keys -x ~/Desktop/freetypist-private-key.txt"
