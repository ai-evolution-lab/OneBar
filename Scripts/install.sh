#!/bin/bash
# OneBar 安装脚本：可被 `curl -fsSL <raw-url> | bash` 执行。
set -euo pipefail

REPO="ai-evolution-lab/OneBar"
ASSET="OneBar.app.zip"
INSTALL_DIR="/Applications/OneBar.app"
BIN="${INSTALL_DIR}/Contents/MacOS/OneBar"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

err() {
  echo "错误: $*" >&2
  exit 1
}

is_apple_silicon() {
  if [ "$(uname -m)" = "arm64" ]; then
    return 0
  fi
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ]
}

if [ "$(uname -s)" != "Darwin" ]; then
  err "OneBar 只支持 macOS。"
fi

if ! is_apple_silicon; then
  err "OneBar 目前仅支持 Apple Silicon（arm64），当前架构是 $(uname -m)。"
fi

os_major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "${os_major}" -lt 14 ]; then
  err "需要 macOS 14 或更高版本，当前是 $(sw_vers -productVersion)。"
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

echo "正在下载 OneBar…"
if ! curl -fL --progress-bar -o "${TMP}/${ASSET}" "${DOWNLOAD_URL}"; then
  err "下载失败。请检查网络，或打开 https://github.com/${REPO}/releases 确认已发布安装包。"
fi

if ! ditto -x -k "${TMP}/${ASSET}" "${TMP}/out"; then
  err "解压失败，安装包可能损坏。"
fi

APP="${TMP}/out/OneBar.app"
if [ ! -d "${APP}" ]; then
  APP="$(find "${TMP}/out" -name 'OneBar.app' -type d -maxdepth 3 | head -n 1 || true)"
fi
[ -d "${APP}" ] || err "安装包里找不到 OneBar.app。"
[ -x "${APP}/Contents/MacOS/OneBar" ] || err "安装包不完整：缺少可执行文件。"

xattr -cr "${APP}" 2>/dev/null || true

if pgrep -x OneBar >/dev/null 2>&1; then
  osascript -e 'tell application "OneBar" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x OneBar >/dev/null 2>&1 || true
fi

rm -rf "${INSTALL_DIR}"
if ! ditto "${APP}" "${INSTALL_DIR}"; then
  err "无法写入 ${INSTALL_DIR}，请确认对该目录有写权限。"
fi
xattr -cr "${INSTALL_DIR}" 2>/dev/null || true
chmod +x "${BIN}"

# 与 App 内 PrivilegedWriter.installSudoers 相同：只放行这一条可执行文件。
authorize_fan() {
  local user line shell escaped
  user="$(id -un)"
  line="${user} ALL=(root) NOPASSWD: ${BIN}"
  shell="printf '%s\\n' '${line}' > /etc/sudoers.d/onebar && chmod 440 /etc/sudoers.d/onebar && visudo -cf /etc/sudoers.d/onebar"
  escaped="$(printf '%s' "${shell}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  osascript -e "do shell script \"${escaped}\" with administrator privileges" >/dev/null
}

echo "接下来会弹出管理员密码窗口，用于授权风扇控制（仅此一次）。"
if authorize_fan; then
  echo "风扇授权已写入 /etc/sudoers.d/onebar。"
else
  echo "风扇授权未完成。可稍后在菜单栏风扇面板点「授权风扇控制（仅一次）」。"
fi

open "${INSTALL_DIR}"
echo "已安装到 ${INSTALL_DIR}，OneBar 正在启动。"
echo "之后可在「应用程序」里双击 OneBar 打开。"
echo "任意菜单栏图标右键：重新启动 / 退出。"
echo "若菜单栏没有图标：系统设置 → 菜单栏，打开 OneBar。"
