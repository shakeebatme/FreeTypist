#!/bin/zsh
# Notarize and staple an app bundle or a disk image.
#
#   scripts/notarize.sh /path/to/FreeTypist.app
#   scripts/notarize.sh /path/to/FreeTypist-0.3.dmg
#
# Notarization is Apple checking the build and issuing a ticket; stapling
# attaches that ticket to the file so the first launch validates without a
# network round trip. Both are needed: notarizing alone leaves a user who is
# offline, or behind a firewall, staring at the same Gatekeeper refusal.
#
# Requires a Developer ID Application certificate and stored credentials:
#
#   xcrun notarytool store-credentials FreeTypist \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# The app-specific password is generated at appleid.apple.com, not your Apple
# ID password. Override the profile name with FREETYPIST_NOTARY_PROFILE.
set -e

TARGET="$1"
[ -n "$TARGET" ] && [ -e "$TARGET" ] || { echo "Usage: notarize.sh <path to .app or .dmg>" >&2; exit 1; }

PROFILE="${FREETYPIST_NOTARY_PROFILE:-FreeTypist}"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No stored notarization credentials under the profile \"$PROFILE\"." >&2
  echo "Create them once with:" >&2
  echo "    xcrun notarytool store-credentials $PROFILE \\" >&2
  echo "      --apple-id <your-apple-id> --team-id <team-id> --password <app-specific-password>" >&2
  exit 1
fi

case "$TARGET" in
  *.app)
    # A bundle cannot be submitted directly; Apple takes an archive of it. This
    # archive is only the carrier — the ticket gets stapled to the .app itself,
    # and the caller re-archives afterwards to pick the ticket up.
    UPLOAD="$(mktemp -d)/$(basename "${TARGET%.app}").zip"
    echo "    archiving for submission"
    ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$UPLOAD"
    ;;
  *.dmg)
    UPLOAD="$TARGET"
    ;;
  *)
    echo "Can only notarize a .app or a .dmg, got: $TARGET" >&2
    exit 1
    ;;
esac

echo "    submitting to Apple (this usually takes a few minutes)"
if ! xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait; then
  echo >&2
  echo "Notarization failed. Apple's log says why:" >&2
  echo "    xcrun notarytool log <submission-id> --keychain-profile $PROFILE" >&2
  echo "The submission id is in the output above." >&2
  exit 1
fi

echo "    stapling the ticket"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# Proves the result is what a user's Mac will actually conclude, rather than
# trusting that the steps above succeeded.
echo "    Gatekeeper assessment:"
spctl --assess --type execute --verbose=2 "$TARGET" 2>&1 | sed 's/^/        /' || true
