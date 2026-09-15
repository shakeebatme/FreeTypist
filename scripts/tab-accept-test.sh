#!/bin/zsh
# End-to-end Tab-acceptance check against a real app.
#
# Unlike scripts/test.sh, this is not pure logic: it drives a live app with real
# events, so it needs FreeTypist installed and running, Accessibility permission
# for both FreeTypist and your terminal, and the screen to itself for a few
# seconds. Keep hands off the keyboard while it runs.
#
#   scripts/tab-accept-test.sh            # Safari (the app this bug came from)
#   scripts/tab-accept-test.sh textedit   # the Accessibility-write path
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"

TARGET="${1:-safari}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

if [ "$TARGET" = "safari" ]; then
  cat > "$OUT/page.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>FreeTypist Tab test</title>
<style>body{font:16px -apple-system;padding:40px}
textarea,input{font:16px/1.4 -apple-system;width:520px;padding:8px;display:block;margin:12px 0}</style>
<h2>FreeTypist Tab test</h2>
<textarea id="target" rows="4"></textarea>
<input id="decoy" type="text" placeholder="focus must NOT land here">
HTML
  open -a Safari "file://$OUT/page.html"
  sleep 2
else
  : > "$OUT/scratch.txt"
  open -a TextEdit "$OUT/scratch.txt"
  sleep 2
fi

xcrun swiftc -swift-version 5 scripts/tab-accept-test.swift -o "$OUT/tabtest"
"$OUT/tabtest" "$TARGET"
