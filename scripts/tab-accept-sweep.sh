#!/bin/zsh
# Walks a list of apps and reports, for each, whether Tab accepts word by word,
# whether focus stays put, and whether the app feeds the AX observer or leaves
# FreeTypist on the backstop poll.
#
# Needs FreeTypist running and Accessibility permission for this terminal. Takes
# the screen for the duration — keep hands off the keyboard.
#
#   scripts/tab-accept-sweep.sh                 # the default set
#   scripts/tab-accept-sweep.sh com.apple.Notes # one app (must already be open
#                                               # on a document you can type in)
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
BIN="$OUT/tabtest"
xcrun swiftc -swift-version 5 scripts/tab-accept-test.swift -o "$BIN"

cat > "$OUT/page.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>FreeTypist Tab test</title>
<style>body{font:16px -apple-system;padding:40px}
textarea,input{font:16px/1.4 -apple-system;width:520px;padding:8px;display:block;margin:12px 0}</style>
<h2>FreeTypist Tab test</h2><textarea id="target" rows="4"></textarea>
<input id="decoy" type="text" placeholder="focus must NOT land here">
HTML

# app bundle id | how to give it something to type in | dom id (browsers)
ROWS=(
  "com.apple.TextEdit|file|"
  "com.barebones.bbedit|file|"
  "com.coteditor.CotEditor|file|"
  "pro.writer.mac|file|"
  "com.apple.dt.Xcode|file|"
  "com.microsoft.Word|file|"
  "com.postmanlabs.mac|open|"
  "com.apple.Safari|url|target"
  "com.google.Chrome|url|target"
)
[ $# -gt 0 ] && ROWS=("$1|open|")

printf '%-34s %-9s %s\n' "APP" "VERDICT" "DETAIL"
printf '%s\n' "----------------------------------------------------------------------------------"
for row in $ROWS; do
  id="${row%%|*}"; rest="${row#*|}"; how="${rest%%|*}"; dom="${rest#*|}"
  app=$(mdfind "kMDItemCFBundleIdentifier == '$id'" 2>/dev/null | grep '\.app$' | head -1)
  if [ -z "$app" ]; then printf '%-34s %-9s %s\n' "$id" "skip" "not installed"; continue; fi

  case "$how" in
    file) doc="$OUT/${id}.txt"; : > "$doc"; open -a "$app" "$doc" ;;
    url)  open -a "$app" "file://$OUT/page.html" ;;
    open) open -a "$app" 2>/dev/null || true ;;
  esac
  sleep 8

  set +e
  line=$(FT_NO_MANUAL_AX=1 "$BIN" "$id" $dom 2>&1 | grep '^RESULT' | head -1)
  set -e
  if [ -z "$line" ]; then line="RESULT $id error harness produced no result"; fi
  verdict=$(echo "$line" | awk '{print $3}')
  detail=$(echo "$line" | cut -d' ' -f4-)
  printf '%-34s %-9s %s\n' "$id" "$verdict" "$detail"

  osascript -e "tell application id \"$id\" to close every window saving no" >/dev/null 2>&1 || true
done
