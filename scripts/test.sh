#!/bin/zsh
# Pure-logic tests. No Xcode project, no app launch — these must stay green
# through engine swaps, since the rules they cover were established by measuring
# real model output.
set -e
ROOT="${0:A:h:h}"
cd "$ROOT"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "==> Sanitizer"
xcrun swiftc -swift-version 6 \
  FreeTypist/CompletionSanitizer.swift \
  FreeTypist/WordBoundary.swift \
  Tests/SanitizerTests/main.swift \
  -o "$OUT/sanitizer"
"$OUT/sanitizer"

echo "==> Spell check"
xcrun swiftc -swift-version 6 \
  FreeTypist/WordBoundary.swift \
  Tests/SpellTests/main.swift \
  -o "$OUT/spell"
"$OUT/spell"

echo "==> Shortcuts"
xcrun swiftc -swift-version 6 \
  FreeTypist/Shortcut.swift FreeTypist/KeyEventTap.swift FreeTypist/Suggestion.swift \
  Tests/ShortcutTests/main.swift \
  -o "$OUT/shortcuts"
"$OUT/shortcuts"

echo "==> Terminal"
xcrun swiftc -swift-version 6 \
  FreeTypist/TerminalContext.swift Tests/TerminalTests/main.swift \
  -o "$OUT/terminal"
"$OUT/terminal"

echo "==> Compatibility"
xcrun swiftc -swift-version 6 \
  FreeTypist/AppCompatibility.swift FreeTypist/TerminalContext.swift \
  Tests/CompatibilityTests/main.swift \
  -o "$OUT/compatibility"
"$OUT/compatibility"

echo "==> Backdrop"
# AXSupport comes along for the coordinate flip: ScreenCaptureService converts
# NSScreen.visibleFrame to Quartz, and duplicating that flip locally is the one
# thing AXSupport's own comment warns against.
xcrun swiftc -swift-version 6 \
  FreeTypist/ScreenCaptureService.swift \
  FreeTypist/AXSupport.swift \
  FreeTypist/BackdropSampler.swift \
  Tests/BackdropTests/main.swift \
  -o "$OUT/backdrop"
"$OUT/backdrop"

echo "==> Screen text"
xcrun swiftc -swift-version 6 \
  FreeTypist/ScreenText.swift \
  Tests/ScreenTextTests/main.swift \
  -o "$OUT/screentext"
"$OUT/screentext"

echo "==> Correspondent"
xcrun swiftc -swift-version 6 \
  FreeTypist/Correspondent.swift \
  Tests/CorrespondentTests/main.swift \
  -o "$OUT/correspondent"
"$OUT/correspondent"

echo "==> Prompt assembly"
xcrun swiftc -swift-version 6 \
  FreeTypist/CompletionRequest.swift \
  FreeTypist/Correspondent.swift \
  FreeTypist/CompletionPrompt.swift \
  Tests/PromptTests/main.swift \
  -o "$OUT/prompt"
"$OUT/prompt"

echo "==> Clipboard context"
xcrun swiftc -swift-version 6 \
  FreeTypist/ClipboardContext.swift \
  Tests/ClipboardTests/main.swift \
  -o "$OUT/clipboard"
"$OUT/clipboard"

echo "==> Personalization store"
xcrun swiftc -swift-version 6 \
  FreeTypist/Log.swift \
  FreeTypist/PersonalizationStore.swift \
  Tests/StoreTests/main.swift \
  -o "$OUT/store"
"$OUT/store"

# The last two need a model on disk; skipped when absent.
MODEL="$HOME/Library/Application Support/FreeTypist/Models/Qwen3-1.7B-Q4_K_M.gguf"
FW="$ROOT/Vendor/llama.xcframework/macos-arm64"
ENGINE=(
  FreeTypist/Log.swift FreeTypist/CompletionRequest.swift
  FreeTypist/Correspondent.swift FreeTypist/CompletionPrompt.swift
  FreeTypist/CompletionSanitizer.swift FreeTypist/WordBoundary.swift
  FreeTypist/ModelBackend.swift FreeTypist/LlamaBackend.swift
)
if [ -f "$MODEL" ]; then
  echo "==> Word-choice bias"
  xcrun swiftc -swift-version 6 -O -F "$FW" -framework llama \
    -Xlinker -rpath -Xlinker "$FW" \
    "${ENGINE[@]}" Tests/BiasTest/main.swift -o "$OUT/bias"
  "$OUT/bias" "$MODEL" 2>/dev/null | grep -E "^  bias|^PASS|^FAIL|^NOTE|verified|FAILED"

  echo "==> KV-cache reuse"
  xcrun swiftc -swift-version 6 -O -F "$FW" -framework llama \
    -Xlinker -rpath -Xlinker "$FW" \
    "${ENGINE[@]}" Tests/CacheTests/main.swift -o "$OUT/cache"
  "$OUT/cache" "$MODEL" 2>/dev/null
else
  echo "==> Word-choice bias (skipped: no model downloaded)"
  echo "==> KV-cache reuse (skipped: no model downloaded)"
fi
