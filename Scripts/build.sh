#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/OneBar.app}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_MIN="${MACOS_MIN:-14.0}"
BIN="$OUT/Contents/MacOS/OneBar"

mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
echo -n 'APPL????' > "$OUT/Contents/PkgInfo"

swiftc -O -parse-as-library \
  -target "arm64-apple-macosx${MACOS_MIN}" \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework ServiceManagement \
  -framework Carbon \
  -framework ImageIO \
  -o "$BIN" \
  "$ROOT"/Sources/*.swift

chmod +x "$BIN"
codesign --force --deep --sign - "$OUT" >/dev/null

echo "Built $OUT"
