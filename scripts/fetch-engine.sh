#!/bin/bash
# 把 scrcpy 引擎准备到仓库根目录的 engine/ 下，作为构建时打进 App 的种子。
#
# 用法：
#   scripts/fetch-engine.sh <本地 scrcpy 解压目录>   # 从本地已有的目录拷（不联网）
#   scripts/fetch-engine.sh                          # 从 Genymobile 官方 releases 下最新版
#
# engine/ 不进仓库（见 .gitignore）：一是里面有 30MB 二进制，二是 scrcpy 是 GPLv3，
# 我们不重分发它，改成构建时/首次运行时从官方渠道取。详见 NOTICE。
#
# 这个脚本是可选的 —— engine/ 不存在时 App 照样能构建，只是首次启动要联网下载引擎。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/engine"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# scrcpy 客户端与 scrcpy-server 版本必须严格一致，少一个都会在运行时被拒绝，
# 所以这里三个文件一个都不能缺。
REQUIRED=(scrcpy adb scrcpy-server)

check_dir() {
  local d="$1" f
  for f in "${REQUIRED[@]}"; do
    [[ -f "$d/$f" ]] || { echo "缺少 $d/$f" >&2; return 1; }
  done
}

if [[ $# -ge 1 ]]; then
  SRC="${1%/}"
  [[ -d "$SRC" ]] || { echo "目录不存在：$SRC" >&2; exit 1; }
  check_dir "$SRC" || { echo "$SRC 看起来不是 scrcpy 的解压目录" >&2; exit 1; }
  echo "==> 从本地目录取引擎：$SRC"
  STAGE="$TMP/engine"
  mkdir -p "$STAGE"
  # 用 ditto 而不是 cp：xattr 行为明确可控。
  for f in "${REQUIRED[@]}" scrcpy.png disconnected.png scrcpy.1 LICENSE; do
    [[ -e "$SRC/$f" ]] && ditto "$SRC/$f" "$STAGE/$f"
  done
else
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64) ASSET_ARCH=aarch64 ;;
    x86_64) ASSET_ARCH=x86_64 ;;
    *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
  esac

  echo "==> 查询 Genymobile/scrcpy 最新 release"
  JSON="$(curl -fsSL --retry 3 --connect-timeout 15 \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/Genymobile/scrcpy/releases/latest)"

  TAG="$(printf '%s' "$JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
  VER="${TAG#v}"
  ASSET="scrcpy-macos-${ASSET_ARCH}-v${VER}.tar.gz"
  URL="https://github.com/Genymobile/scrcpy/releases/download/${TAG}/${ASSET}"
  SUMS_URL="https://github.com/Genymobile/scrcpy/releases/download/${TAG}/SHA256SUMS.txt"

  echo "==> 下载 $ASSET"
  curl -fL --retry 3 --connect-timeout 15 -o "$TMP/$ASSET" "$URL"
  curl -fsSL --retry 3 -o "$TMP/SHA256SUMS.txt" "$SUMS_URL"

  # 校验完整性。注意 SHA256SUMS.txt 与 tarball 同源，只能防传输损坏，
  # 不能防仓库被投毒 —— 真正的信任锚是同目录的 .asc 签名，但那需要 gpg。
  echo "==> 校验 SHA256"
  EXPECT="$(awk -v a="$ASSET" '$2 == a { print $1 }' "$TMP/SHA256SUMS.txt")"
  [[ -n "$EXPECT" ]] || { echo "SHA256SUMS.txt 里找不到 $ASSET" >&2; exit 1; }
  ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{ print $1 }')"
  [[ "$EXPECT" == "$ACTUAL" ]] || { echo "SHA256 不匹配！期望 ${EXPECT}，实际 ${ACTUAL}" >&2; exit 1; }

  echo "==> 解压"
  mkdir -p "$TMP/x"
  tar -xzf "$TMP/$ASSET" -C "$TMP/x"
  # tarball 顶层是单个目录 scrcpy-macos-<arch>-v<ver>/
  INNER="$(find "$TMP/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$INNER" ]] || { echo "tarball 结构不符合预期" >&2; exit 1; }
  check_dir "$INNER" || exit 1
  STAGE="$TMP/engine"
  mv "$INNER" "$STAGE"
fi

chmod +x "$STAGE/scrcpy" "$STAGE/adb"

# 清掉 quarantine：本机这份是从 Keka 解压来的，带着 com.apple.quarantine。
# 带着它做出来的 App，嵌套二进制会被 Gatekeeper 单独评估，分享给别人会看到
# 「无法验证开发者」。清零成本极低。注意必须在签名之前做。
echo "==> 清理扩展属性"
xattr -cr "$STAGE"

echo "==> 安装到 $DEST"
rm -rf "$DEST"
mv "$STAGE" "$DEST"

echo "==> 冒烟测试"
"$DEST/scrcpy" --version | head -1
"$DEST/adb" version | head -1
echo "引擎就绪：$DEST"
