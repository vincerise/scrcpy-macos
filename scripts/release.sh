#!/bin/bash
# 打一个可发布的通用包，并生成 SHA256SUMS.txt。
#
# 用法：scripts/release.sh
# 版本号取自 project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION。
#
# 只打包、不发布。最后会打印 gh release create 命令，确认无误后自己执行。
# 发布包**不带**引擎种子：把 scrcpy 的二进制打进安装包属于重分发，会触发
# GPLv3 的传染性；App 首次启动会自己从官方 Releases 下载。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(awk -F: '/^[[:space:]]*MARKETING_VERSION:/ { gsub(/[\" ]/, "", $2); print $2; exit }' project.yml)"
BUILD="$(awk -F: '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ { gsub(/[\" ]/, "", $2); print $2; exit }' project.yml)"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "project.yml 里的 MARKETING_VERSION 不合法：$VERSION" >&2
  exit 1
}
[[ "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "project.yml 里的 CURRENT_PROJECT_VERSION 不合法：$BUILD" >&2
  exit 1
}

APP="$ROOT/build/Build/Products/Release/ScrcpyMac.app"
DIST="$ROOT/dist"
ZIP_NAME="ScrcpyMac-v${VERSION}-macos-universal.zip"
ZIP="$DIST/$ZIP_NAME"

# 先删掉旧产物：构建失败时不能拿上一次的 App 继续打包。
rm -rf "$APP" "$DIST"
mkdir -p "$DIST"

echo "==> 构建 v${VERSION}（build ${BUILD}），不带引擎种子"
SKIP_ENGINE_SEED=1 scripts/build.sh Release

echo "==> 检查产物"
[[ -d "$APP" ]] || { echo "没有构建出 $APP" >&2; exit 1; }
[[ ! -d "$APP/Contents/Resources/engine-seed" ]] || {
  echo "发布包不能带 engine-seed（scrcpy 二进制属于重分发）" >&2
  exit 1
}
# 少了这个脚本，App 能检查、能下载，但点「重启并更新」会直接失败。
[[ -f "$APP/Contents/Resources/app-update-helper.sh" ]] || {
  echo "发布包里缺少 app-update-helper.sh" >&2
  exit 1
}

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || {
  echo "App 里的版本是 ${ACTUAL_VERSION}，project.yml 是 $VERSION" >&2
  exit 1
}
[[ "$ACTUAL_BUILD" == "$BUILD" ]] || {
  echo "App 里的 build 是 ${ACTUAL_BUILD}，project.yml 是 $BUILD" >&2
  exit 1
}

codesign --verify --strict --verbose=2 "$APP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/ScrcpyMac")"
echo "    架构：$ARCHS"
grep -q arm64 <<<"$ARCHS" || { echo "缺少 arm64 slice" >&2; exit 1; }
grep -q x86_64 <<<"$ARCHS" || { echo "缺少 x86_64 slice" >&2; exit 1; }

echo "==> 打包 $ZIP_NAME"
# --sequesterRsrc 把资源叉放进 __MACOSX；App 的解压逻辑会忽略它。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd "$DIST"
  shasum -a 256 "$ZIP_NAME" > SHA256SUMS.txt
)

echo "==> 解包回验"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP/extract"
EXTRACTED="$TMP/extract/ScrcpyMac.app"
[[ -d "$EXTRACTED" ]] || { echo "zip 顶层不是 ScrcpyMac.app" >&2; exit 1; }
codesign --verify --strict --verbose=2 "$EXTRACTED"
EXTRACTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXTRACTED/Contents/Info.plist")"
[[ "$EXTRACTED_VERSION" == "$VERSION" ]] || {
  echo "解包后的版本是 ${EXTRACTED_VERSION}，应为 $VERSION" >&2
  exit 1
}
EXPECT="$(awk '{ print $1 }' "$DIST/SHA256SUMS.txt")"
ACTUAL="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
[[ "$EXPECT" == "$ACTUAL" ]] || { echo "SHA256 回验不通过" >&2; exit 1; }

echo
echo "完成："
echo "    $ZIP"
echo "    $DIST/SHA256SUMS.txt"
echo "    SHA256 $ACTUAL"
echo
echo "确认无误后发布："
echo "    gh release create \"v$VERSION\" \"$ZIP\" \"$DIST/SHA256SUMS.txt\" \\"
echo "      --title \"v$VERSION\" --notes-file <发布说明>"
