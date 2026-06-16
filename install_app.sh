#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Global Clipboard"
SOURCE_APP="$ROOT_DIR/build/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  "$ROOT_DIR/build.sh"
fi

pkill -x GlobalClipboard 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
xattr -cr "$TARGET_APP"

codesign --verify --deep --verbose=2 "$TARGET_APP"

echo "已安装：$TARGET_APP"
