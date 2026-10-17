#!/bin/bash
# 一键 Release 构建通用二进制（arm64 + x86_64）。
# 用法：scripts/build.sh [Debug|Release]（默认 Release）
#
# 构建前如果 engine/ 不存在，App 照样能构建，只是首次启动要联网下载引擎。
# 想离线自带一份就先跑 scripts/fetch-engine.sh。
#
# 测试自更新时可以覆盖版本号：
#   MARKETING_VERSION=0.0.9 CURRENT_PROJECT_VERSION=1 scripts/build.sh Release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "缺少 xcodegen：brew install xcodegen" >&2; exit 1; }
xcodegen generate >/dev/null

if [[ ! -d "$ROOT/engine" ]]; then
  echo "note: 未找到 engine/，本次构建不带引擎种子（App 首次启动将联网下载）"
fi

# xcodebuild 的设置同时会成为 Run Script 阶段的环境变量，
# seed-engine.sh 靠 SKIP_ENGINE_SEED 决定要不要把 engine/ 打进 App。
XCODE_ARGS=("SKIP_ENGINE_SEED=${SKIP_ENGINE_SEED:-0}")
[[ -n "${MARKETING_VERSION:-}" ]] && XCODE_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION")
[[ -n "${CURRENT_PROJECT_VERSION:-}" ]] && XCODE_ARGS+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")

LOG="$ROOT/build/xcodebuild-$CONFIG.log"
mkdir -p "$ROOT/build"

echo "==> xcodebuild（日志：${LOG}）"
set +e
xcodebuild -project ScrcpyMac.xcodeproj -scheme ScrcpyMac -configuration "$CONFIG" \
  -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  "${XCODE_ARGS[@]}" build >"$LOG" 2>&1
STATUS=$?
set -e

# 只把有用的行打出来。失败判定看 xcodebuild 的退出码和 BUILD SUCCEEDED，
# 不看 grep 的结果——旧版本用 `| grep ... || true` 把失败吞掉了，
# 于是上一次留下的 App 会让一次失败的构建看起来像成功。
grep -E "error:|warning:|note: |\*\* BUILD" "$LOG" || true
if [[ $STATUS -ne 0 ]]; then
  echo "构建失败（xcodebuild 退出码 ${STATUS}），完整日志：$LOG" >&2
  exit 1
fi
grep -q "\*\* BUILD SUCCEEDED \*\*" "$LOG" || {
  echo "构建失败，产物未生成，完整日志：$LOG" >&2
  exit 1
}

APP="$ROOT/build/Build/Products/$CONFIG/ScrcpyMac.app"
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
lipo -archs "$APP/Contents/MacOS/ScrcpyMac" | sed 's/^/    ScrcpyMac: /'

echo
echo "构建完成：$APP"
echo "安装到 /Applications：scripts/install.sh"
