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

echo "==> Heuristics"
xcrun swiftc -swift-version 6 \
  FreeTypist/HeuristicProvider.swift \
  FreeTypist/Suggestion.swift \
  FreeTypist/WordBoundary.swift \
  Tests/HeuristicTests/main.swift \
  -o "$OUT/heuristics"
"$OUT/heuristics"

echo "==> Shortcuts"
xcrun swiftc -swift-version 6 \
  FreeTypist/Shortcut.swift FreeTypist/KeyEventTap.swift FreeTypist/Suggestion.swift \
  Tests/ShortcutTests/main.swift \
  -o "$OUT/shortcuts"
"$OUT/shortcuts"

echo "==> System links and emoji"
xcrun swiftc -swift-version 6 \
  FreeTypist/SystemSettings.swift FreeTypist/HeuristicProvider.swift \
  FreeTypist/Suggestion.swift FreeTypist/WordBoundary.swift \
  Tests/SystemLinkTests/main.swift \
  -o "$OUT/systemlinks"
"$OUT/systemlinks"

echo "==> Statistics"
xcrun swiftc -swift-version 6 \
  FreeTypist/Statistics.swift Tests/StatisticsTests/main.swift \
  -o "$OUT/statistics"
"$OUT/statistics"

echo "==> Latency window"
xcrun swiftc -swift-version 6 \
  FreeTypist/LatencyStats.swift Tests/LatencyTests/main.swift \
  -o "$OUT/latency"
"$OUT/latency"

echo "==> Suggestion presentation"
xcrun swiftc -swift-version 6 \
  FreeTypist/SuggestionOverlayController.swift FreeTypist/Suggestion.swift \
  Tests/PresentationTests/main.swift \
  -o "$OUT/presentation"
"$OUT/presentation"

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

echo "==> Secure input"
xcrun swiftc -swift-version 6 \
  FreeTypist/SecureInput.swift Tests/SecureInputTests/main.swift \
  -o "$OUT/secureinput"
"$OUT/secureinput"

echo "==> Per-app overrides"
xcrun swiftc -swift-version 6 \
  FreeTypist/AppOverrides.swift Tests/OverrideTests/main.swift \
  -o "$OUT/overrides"
"$OUT/overrides"

echo "==> Excluded apps"
xcrun swiftc -swift-version 6 \
  FreeTypist/AppExclusions.swift Tests/ExclusionTests/main.swift \
  -o "$OUT/exclusions"
"$OUT/exclusions"

echo "==> Model catalogue"
# Hashes any model already downloaded, so this one takes a few seconds per
# gigabyte on disk. It is the check that decides whether arbitrary bytes reach
# ggml, so it runs whether or not a model is there: shape always, contents when
# there is something to check.
xcrun swiftc -swift-version 6 \
  FreeTypist/ModelRepository.swift Tests/ModelCatalogueTests/main.swift \
  -o "$OUT/catalogue"
"$OUT/catalogue"

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
MODEL="$HOME/Library/Application Support/FreeTypist/Models/Qwen3-1.7B-Base.i1-Q4_K_M.gguf"
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

  echo "==> Token healing"
  xcrun swiftc -swift-version 6 -O -F "$FW" -framework llama \
    -Xlinker -rpath -Xlinker "$FW" \
    "${ENGINE[@]}" Tests/HealingTests/main.swift -o "$OUT/healing"
  "$OUT/healing" "$MODEL" 2>/dev/null

  echo "==> Alternatives"
  xcrun swiftc -swift-version 6 -O -F "$FW" -framework llama \
    -Xlinker -rpath -Xlinker "$FW" \
    "${ENGINE[@]}" Tests/AlternativesTests/main.swift -o "$OUT/alternatives"
  "$OUT/alternatives" "$MODEL" 2>/dev/null | grep -E "^PASS|^FAIL|ms ·|verified|FAILED"

  echo "==> KV-cache reuse"
  xcrun swiftc -swift-version 6 -O -F "$FW" -framework llama \
    -Xlinker -rpath -Xlinker "$FW" \
    "${ENGINE[@]}" Tests/CacheTests/main.swift -o "$OUT/cache"
  "$OUT/cache" "$MODEL" 2>/dev/null
else
  echo "==> Word-choice bias (skipped: no model downloaded)"
  echo "==> Token healing (skipped: no model downloaded)"
  echo "==> Alternatives (skipped: no model downloaded)"
  echo "==> KV-cache reuse (skipped: no model downloaded)"
fi
