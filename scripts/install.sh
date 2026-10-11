#!/bin/bash
# 把构建好的 App 装到 /Applications（想装到别处就设 DEST_DIR）。
# 用法：scripts/install.sh [Debug|Release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
SRC="$ROOT/build/Build/Products/$CONFIG/ScrcpyMac.app"
DEST_DIR="${DEST_DIR:-/Applications}"
DEST="$DEST_DIR/ScrcpyMac.app"

[[ -d "$SRC" ]] || { echo "没找到 $SRC，先跑 scripts/build.sh" >&2; exit 1; }

# 正在跑就先退掉：替换一个正在运行的 bundle，行为未定义。
if pgrep -f "$DEST/Contents/MacOS/ScrcpyMac" >/dev/null 2>&1; then
  echo "==> 先退出正在运行的 ScrcpyMac"
  osascript -e 'tell application "ScrcpyMac" to quit' 2>/dev/null || true
  sleep 1
  pkill -f "$DEST/Contents/MacOS/ScrcpyMac" 2>/dev/null || true
fi

echo "==> 安装到 $DEST"
rm -rf "$DEST"
# 用 ditto 而不是 cp -R：它保留可执行位与符号链接语义，是 macOS 上搬 bundle 的正确工具。
ditto "$SRC" "$DEST"
# 本地构建本来不带 quarantine，这一步是防止产物中途经过网络或压缩包。
xattr -cr "$DEST"

# 让 Finder / 启动台 / 程序坞重新读取图标与元数据。
# 不清缓存的话，换了图标之后旧图标会一直粘着（IconServices 的缓存很顽固）。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST" || true
killall Dock 2>/dev/null || true

echo
echo "完成。现在可以在启动台里找到 ScrcpyMac，也可以拖进程序坞。"
