#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/OneBar.app"
ZIP="$ROOT/build/OneBar.app.zip"

"$ROOT/Scripts/build.sh"

[ -d "$APP" ] || { echo "错误: 构建产物不存在 $APP" >&2; exit 1; }
[ -x "$APP/Contents/MacOS/OneBar" ] || { echo "错误: 缺少可执行文件" >&2; exit 1; }

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packed $ZIP"
