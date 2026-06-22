#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Y-Clip"
LEGACY_APP_NAME="Global Clipboard"
SOURCE_APP="$ROOT_DIR/build/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
LEGACY_TARGET_APP="$INSTALL_DIR/$LEGACY_APP_NAME.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  "$ROOT_DIR/build.sh"
fi

pkill -x GlobalClipboard 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
if [[ -d "$TARGET_APP" ]]; then
  find "$TARGET_APP" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
else
  mkdir -p "$TARGET_APP"
fi
ditto "$SOURCE_APP" "$TARGET_APP"
xattr -cr "$TARGET_APP"

if [[ "$LEGACY_TARGET_APP" != "$TARGET_APP" && -d "$LEGACY_TARGET_APP" ]]; then
  find "$LEGACY_TARGET_APP" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  rmdir "$LEGACY_TARGET_APP" 2>/dev/null || true
fi

codesign --verify --deep --verbose=2 "$TARGET_APP"

echo "已安装：$TARGET_APP"
