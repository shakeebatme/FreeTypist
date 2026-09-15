#!/bin/zsh
# Cut a release: build, sign, zip, sign the zip for Sparkle, and add it to the
# appcast that installed copies poll.
#
#   scripts/release.sh 0.3
#   scripts/release.sh 0.3 --notes notes.html
#   scripts/release.sh 0.3 --notes notes.html --publish
#
# Without --publish nothing leaves the machine: the zip lands in dist/ and
# appcast.xml is edited but not committed or pushed. Users only see the update
# once appcast.xml is on the main branch, so that is the real publish step.
set -e

ROOT="${0:A:h:h}"
cd "$ROOT"

REPO="shakeebatme/FreeTypist"
VERSION=""
NOTES=""
PUBLISH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) VERSION="$1"; shift ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Usage: scripts/release.sh <version> [--notes FILE] [--publish]" >&2
  exit 1
fi
if [ -n "$NOTES" ] && [ ! -f "$NOTES" ]; then
  echo "No such notes file: $NOTES" >&2
  exit 1
fi

PLIST="$ROOT/FreeTypist/Info.plist"
PUBKEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null || echo "")
if [ -z "$PUBKEY" ]; then
  echo "FreeTypist/Info.plist has no SUPublicEDKey — run scripts/generate-update-keys.sh first." >&2
  echo "Shipping without it means no installed copy can verify this update." >&2
  exit 1
fi

# Checked here rather than at the end: by the time the publish step runs, the
# version in project.yml has been bumped and appcast.xml edited, and failing
# there leaves a half-cut release to unpick by hand.
if [ "$PUBLISH" -eq 1 ] && ! command -v gh >/dev/null 2>&1; then
  echo "--publish needs the GitHub CLI, which is not installed." >&2
  echo "    brew install gh && gh auth login" >&2
  echo "Or re-run without --publish and upload the zip through the web UI." >&2
  exit 1
fi

TOOLS=""
for dir in "$ROOT"/DerivedData/SourcePackages/artifacts/*/Sparkle/bin(N/); do
  TOOLS="$dir"
  break
done
if [ -z "$TOOLS" ]; then
  echo "Sparkle's tools are not unpacked yet. Build once, then re-run." >&2
  exit 1
fi

# The key in Info.plist is what every installed copy verifies against. If it
# does not match the private key about to sign this archive, the update ships
# and every user rejects it — and no later release can reach them either,
# because they are all still checking against the key they already have.
KEYCHAIN_PUBKEY=$("$TOOLS/generate_keys" -p 2>/dev/null || echo "")
if [ -z "$KEYCHAIN_PUBKEY" ]; then
  echo "No private signing key in the keychain." >&2
  echo "Info.plist expects one matching: $PUBKEY" >&2
  echo "Restore it from your backup with: $TOOLS/generate_keys -f <backup-file>" >&2
  exit 1
fi
if [ "$KEYCHAIN_PUBKEY" != "$PUBKEY" ]; then
  echo "Signing key mismatch — refusing to build an update nobody can install." >&2
  echo "    Info.plist: $PUBKEY" >&2
  echo "    keychain:   $KEYCHAIN_PUBKEY" >&2
  exit 1
fi

# Sparkle orders updates by CFBundleVersion, not by the marketing version, so
# this has to climb on every release regardless of what the version string does.
BUILD=$(( $(grep -E '^\s+CURRENT_PROJECT_VERSION:' project.yml \
  | grep -oE '[0-9]+' | head -1) + 1 ))

echo "==> FreeTypist $VERSION (build $BUILD)"
python3 - "$VERSION" "$BUILD" <<'PY'
import re, sys
version, build = sys.argv[1], sys.argv[2]
src = open('project.yml').read()
src = re.sub(r'(MARKETING_VERSION: )"[^"]*"', r'\g<1>"%s"' % version, src, count=1)
src = re.sub(r'(CURRENT_PROJECT_VERSION: )"[^"]*"', r'\g<1>"%s"' % build, src, count=1)
open('project.yml', 'w').write(src)
PY

echo "==> Building Release"
xcodegen generate >/dev/null
xcodebuild -project FreeTypist.xcodeproj -scheme FreeTypist \
  -configuration Release -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build >/tmp/freetypist-release-build.log 2>&1 \
  || { echo "Build failed. See /tmp/freetypist-release-build.log" >&2; exit 1; }

APP_SRC="DerivedData/Build/Products/Release/FreeTypist.app"
[ -d "$APP_SRC" ] || { echo "Missing $APP_SRC" >&2; exit 1; }

STAGE="$(mktemp -d /tmp/freetypist-release.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_SRC" "$STAGE/FreeTypist.app"

echo "==> Signing"
scripts/sign-app.sh "$STAGE/FreeTypist.app"

DIST="$ROOT/dist"
mkdir -p "$DIST"
ZIP="$DIST/FreeTypist-$VERSION.zip"
rm -f "$ZIP"

echo "==> Archiving"
# ditto, not zip: it is the only one that preserves the symlinks and extended
# attributes inside a framework, and a mangled framework fails to load rather
# than failing to install.
ditto -c -k --sequesterRsrc --keepParent "$STAGE/FreeTypist.app" "$ZIP"

echo "==> Signing the archive for Sparkle"
SIGNATURE=$("$TOOLS/sign_update" "$ZIP")

# Verify what was just produced, against the archive that will actually be
# uploaded. Cheap here; a broken download for everyone if it is wrong.
ED=$(echo "$SIGNATURE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
if ! "$TOOLS/sign_update" --verify "$ZIP" "$ED" >/dev/null 2>&1; then
  echo "The signature does not verify against $ZIP." >&2
  exit 1
fi
echo "    signature verifies"

URL="https://github.com/$REPO/releases/download/v$VERSION/FreeTypist-$VERSION.zip"

VERSION="$VERSION" BUILD="$BUILD" URL="$URL" SIGNATURE="$SIGNATURE" NOTES="$NOTES" \
python3 - <<'PY'
import html, os, re, time

version, build = os.environ['VERSION'], os.environ['BUILD']
url, signature, notes = os.environ['URL'], os.environ['SIGNATURE'], os.environ['NOTES']

# sign_update prints the two attributes ready to paste into the enclosure.
ed = re.search(r'sparkle:edSignature="([^"]+)"', signature).group(1)
length = re.search(r'length="([0-9]+)"', signature).group(1)

if notes:
    body = open(notes).read().strip()
else:
    body = '<p>Version %s of FreeTypist.</p>' % html.escape(version)

item = '''    <item>
      <title>%s</title>
      <pubDate>%s</pubDate>
      <sparkle:version>%s</sparkle:version>
      <sparkle:shortVersionString>%s</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
%s
      ]]></description>
      <enclosure url="%s"
                 length="%s"
                 type="application/octet-stream"
                 sparkle:edSignature="%s" />
    </item>
''' % (html.escape(version), time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime()),
       build, html.escape(version), body, html.escape(url), length, ed)

path = 'appcast.xml'
if os.path.exists(path):
    feed = open(path).read()
else:
    feed = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>FreeTypist</title>
    <link>https://raw.githubusercontent.com/shakeebatme/FreeTypist/main/appcast.xml</link>
    <description>Updates for FreeTypist.</description>
    <language>en</language>
  </channel>
</rss>
'''

if '<sparkle:version>%s</sparkle:version>' % build in feed:
    raise SystemExit('appcast.xml already has build %s — bump and retry.' % build)

# Newest first: ahead of the topmost existing item, or at the end of the
# channel when this is the first release. Sparkle reads the whole feed either
# way; this is so a human opening the file sees the current release first.
anchor = feed.find('    <item>')
if anchor == -1:
    anchor = feed.index('  </channel>')
feed = feed[:anchor] + item + feed[anchor:]
open(path, 'w').write(feed)
print('    appcast.xml: added build %s' % build)
PY

SIZE=$(du -h "$ZIP" | cut -f1 | tr -d ' ')
echo
echo "==> $ZIP  ($SIZE)"

if [ "$PUBLISH" -eq 1 ]; then
  echo "==> Publishing v$VERSION to GitHub"
  if [ -n "$NOTES" ]; then
    NOTES_ARGS=(--notes-file "$NOTES")
  else
    NOTES_ARGS=(--generate-notes)
  fi
  gh release create "v$VERSION" "$ZIP" \
    --repo "$REPO" --title "FreeTypist $VERSION" $NOTES_ARGS
  git add project.yml appcast.xml
  git commit -m "Release $VERSION"
  git push
  echo
  echo "Live. Installed copies will see it on their next check."
else
  echo
  echo "Nothing published yet. To finish:"
  echo "    gh release create v$VERSION $ZIP --repo $REPO --title \"FreeTypist $VERSION\""
  echo "    git add project.yml appcast.xml && git commit -m \"Release $VERSION\" && git push"
  echo
  echo "The upload has to land before appcast.xml does, or the first person to"
  echo "check gets an update whose download 404s."
fi
