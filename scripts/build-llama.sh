#!/bin/zsh
# Rebuilds Vendor/llama.xcframework from the pinned upstream commit.
#
# Only needed when bumping llama.cpp — the built framework is committed, so a
# normal build does not require cmake. Requires: brew install cmake
set -e
ROOT="${0:A:h:h}"
TAG=$(head -1 "$ROOT/Vendor/LLAMA_VERSION.txt")
COMMIT=$(sed -n 2p "$ROOT/Vendor/LLAMA_VERSION.txt")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> llama.cpp $TAG ($COMMIT)"
git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$WORK/llama.cpp" 2>/dev/null
ACTUAL=$(cd "$WORK/llama.cpp" && git rev-parse HEAD)
[ "$ACTUAL" = "$COMMIT" ] || { echo "Commit mismatch: got $ACTUAL, pinned $COMMIT"; exit 1; }

echo "==> Building (macOS only)"
(cd "$WORK/llama.cpp" && ./build-xcframework.sh macos >/dev/null)

XCF="$WORK/llama.cpp/build-apple/llama.xcframework"
BIN="$XCF/macos-arm64_x86_64/llama.framework/Versions/A/llama"

echo "==> Thinning to arm64 and stripping"
lipo "$BIN" -thin arm64 -output "$WORK/thin" && mv "$WORK/thin" "$BIN"
strip -S -x "$BIN"
rm -rf "$XCF/macos-arm64_x86_64/dSYMs"
mv "$XCF/macos-arm64_x86_64" "$XCF/macos-arm64"
python3 - "$XCF/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, "rb"))
for lib in d.get("AvailableLibraries", []):
    lib["LibraryIdentifier"] = "macos-arm64"
    lib["SupportedArchitectures"] = ["arm64"]
    lib.pop("DebugSymbolsPath", None)
plistlib.dump(d, open(p, "wb"))
PY

rm -rf "$ROOT/Vendor/llama.xcframework"
cp -R "$XCF" "$ROOT/Vendor/llama.xcframework"
du -sh "$ROOT/Vendor/llama.xcframework"
