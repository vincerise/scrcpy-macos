#!/bin/bash
# Xcode 构建阶段的钩子，由 project.yml 的 postBuildScripts 调用。
# 把仓库根的 engine/ 拷进 App 的 Contents/Resources/engine-seed/。
#
# engine/ 不存在时**不是错误** —— 直接跳过。这样 clone 下来没跑过
# fetch-engine.sh 的人也能构建成功，只是 App 首次启动要联网下载引擎。
#
# 时序说明：Run Script 阶段在 Xcode 对产物签名**之前**执行，
# 所以这里加进去的文件会被正常 seal 进签名。
set -euo pipefail

APP="${1:?用法: seed-engine.sh <App 路径>}"
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ENGINE="$ROOT/engine"

if [[ ! -d "$ENGINE" ]]; then
  echo "note: 未找到 ${ENGINE}，跳过引擎种子（App 首次启动时将联网下载）"
  exit 0
fi

DEST="$APP/Contents/Resources/engine-seed"
echo "note: 打入引擎种子 $ENGINE -> $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

# ditto 保留可执行位；逐个拷贝以免把 .DS_Store 之类带进去。
for f in scrcpy adb scrcpy-server scrcpy.png disconnected.png scrcpy.1 LICENSE; do
  [[ -e "$ENGINE/$f" ]] && ditto "$ENGINE/$f" "$DEST/$f"
done
chmod +x "$DEST/scrcpy" "$DEST/adb"

# 保险起见再清一次（Xcode 不会给资源加 quarantine，但拷贝链路多，不赌）。
xattr -cr "$DEST" 2>/dev/null || true

VER="$("$DEST/scrcpy" --version 2>/dev/null | head -1 || true)"
echo "note: 引擎种子就绪 — $VER"
