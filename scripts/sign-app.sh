#!/bin/zsh
# Sign FreeTypist.app in place, nested code first.
#
# install.sh, make-dmg.sh and release.sh all need this and need it identical:
# Sparkle nests four executables of its own and each has to be signed before
# the framework that holds it. Getting the order wrong produces an app that
# passes codesign --verify and then silently fails to install its own updates.
# One copy, called three times.
#
#   scripts/sign-app.sh [options] /path/to/FreeTypist.app
#   scripts/sign-app.sh [options] --identity-only    # print the resolved SHA-1
#
# Options:
#   --adhoc-ok       fall back to ad-hoc signing instead of failing (local installs)
#   --no-timestamp   skip the secure timestamp, which needs the network
set -e

ROOT="${0:A:h:h}"

ADHOC_OK=0
TIMESTAMP=1
IDENTITY_ONLY=0
APP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --adhoc-ok) ADHOC_OK=1; shift ;;
    --no-timestamp) TIMESTAMP=0; shift ;;
    --identity-only) IDENTITY_ONLY=1; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) APP="$1"; shift ;;
  esac
done

# Match by SHA-1, not by name. Six certificates share one name on this machine
# and five are revoked, so letting `head -1` of a name grep decide is a coin toss.
IDENTITY="${FREETYPIST_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -v CSSMERR_TP_CERT_REVOKED \
    | grep -oE '[0-9A-F]{40}' | head -1)
fi
if [ -z "$IDENTITY" ]; then
  if [ "$ADHOC_OK" -eq 1 ]; then
    IDENTITY="-"
  else
    echo "No usable code signing identity found." >&2
    echo "Set FREETYPIST_IDENTITY to a SHA-1 from: security find-identity -v -p codesigning" >&2
    exit 1
  fi
fi

if [ "$IDENTITY_ONLY" -eq 1 ]; then
  echo "$IDENTITY"
  exit 0
fi

[ -n "$APP" ] && [ -d "$APP" ] || { echo "Usage: sign-app.sh [options] <path to .app>" >&2; exit 1; }

# A secure timestamp needs the network, which a local install should not.
if [ "$TIMESTAMP" -eq 1 ]; then
  FLAGS=(--force --timestamp --sign "$IDENTITY")
else
  FLAGS=(--force --sign "$IDENTITY")
fi

sign() { codesign $FLAGS "$@" }

# Sparkle's own helpers: two XPC services, the Autoupdate tool and Updater.app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
if [ -d "$SPARKLE" ]; then
  for nested in "$SPARKLE"/XPCServices/*.xpc(N) "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    [ -e "$nested" ] || continue
    echo "    sparkle: ${nested:t}"
    sign "$nested"
  done
fi

# `--deep` is deprecated and gets this order wrong, leaving the app looking
# valid while macOS quietly refuses it Accessibility.
for fw in "$APP"/Contents/Frameworks/*.framework(N); do
  echo "    framework: ${fw:t}"
  # Walk the version directories rather than hardcoding A: llama ships
  # Versions/A, Sparkle ships Versions/B, and signing a path that does not
  # exist aborts the script.
  for ver in "$fw"/Versions/*(/N); do
    case "${ver:t}" in
      Current) continue ;;
    esac
    sign "$ver"
  done
done

sign --entitlements "$ROOT/FreeTypist/FreeTypist.entitlements" "$APP"

codesign --verify --verbose=1 --deep --strict "$APP" 2>&1 | sed 's/^/    /'
