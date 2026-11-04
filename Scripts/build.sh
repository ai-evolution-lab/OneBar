#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/OneBar.app}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_MIN="${MACOS_MIN:-14.0}"
BIN="$OUT/Contents/MacOS/OneBar"

mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
OBJ_DIR="$(mktemp -d)"
trap 'rm -rf "$OBJ_DIR"' EXIT
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
echo -n 'APPL????' > "$OUT/Contents/PkgInfo"

clang -fobjc-arc -O2 -target "arm64-apple-macosx${MACOS_MIN}" -isysroot "$SDK" \
  -c "$ROOT/Sources/MenuBarNative.m" -o "$OBJ_DIR/MenuBarNative.o"

swiftc -O -parse-as-library \
  -target "arm64-apple-macosx${MACOS_MIN}" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework ServiceManagement \
  -framework Carbon \
  -framework ImageIO \
  -framework Vision \
  -import-objc-header "$ROOT/Sources/MenuBarNative.h" \
  -o "$BIN" \
  "$OBJ_DIR/MenuBarNative.o" \
  "$ROOT"/Sources/*.swift

chmod +x "$BIN"
codesign --force --deep --sign - "$OUT" >/dev/null

echo "Built $OUT"
