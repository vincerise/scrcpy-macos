#!/bin/bash
# 一键 Release 构建通用二进制（arm64 + x86_64）。
# 用法：scripts/build.sh [Debug|Release]（默认 Release）
#
# 构建前如果 engine/ 不存在，App 照样能构建，只是首次启动要联网下载引擎。
# 想离线自带一份就先跑 scripts/fetch-engine.sh。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "缺少 xcodegen：brew install xcodegen" >&2; exit 1; }
xcodegen generate >/dev/null

if [[ ! -d "$ROOT/engine" ]]; then
  echo "note: 未找到 engine/，本次构建不带引擎种子（App 首次启动将联网下载）"
fi

xcodebuild -project Scrcpy.xcodeproj -scheme Scrcpy -configuration "$CONFIG" \
  -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build \
  | grep -E "error:|warning:|note: |\*\* BUILD" || true

APP="$ROOT/build/Build/Products/$CONFIG/Scrcpy.app"
[[ -d "$APP" ]] || { echo "构建失败，未找到 $APP" >&2; exit 1; }

# ---- 验证 -------------------------------------------------------------------
# 只签 App 本身，绝不加 --deep：引擎里的 adb 带 Google 的 Developer ID 签名，
# --deep 会把它重签成 ad-hoc，直接毁掉那个签名。
echo
echo "==> 校验签名"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> 冒烟测试"
if [[ -d "$APP/Contents/Resources/engine-seed" ]]; then
  "$APP/Contents/Resources/engine-seed/scrcpy" --version | head -1 | sed 's/^/    /'
  "$APP/Contents/Resources/engine-seed/adb" version | head -1 | sed 's/^/    /'
else
  echo "    （无内置种子，跳过）"
fi

echo "==> 通用二进制检查"
lipo -archs "$APP/Contents/MacOS/Scrcpy" | sed 's/^/    Scrcpy: /'

echo
echo "构建完成：$APP"
echo "安装到 /Applications：scripts/install.sh"
