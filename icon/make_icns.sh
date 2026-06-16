#!/bin/zsh
set -euo pipefail

# 从 1024px 主图生成 AppIcon.icns
# 用法：./make_icns.sh [源PNG] [输出icns]

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$ROOT_DIR/icon_1024.png}"
OUT="${2:-$ROOT_DIR/AppIcon.icns}"
ICONSET="$ROOT_DIR/AppIcon.iconset"

if [[ ! -f "$SRC" ]]; then
  echo "找不到源图：$SRC" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# macOS 标准 iconset 各尺寸（名字必须严格匹配）
gen() {
  local size=$1 name=$2
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
}

gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "已生成：$OUT"
