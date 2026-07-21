#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK_DIR="$ROOT_DIR/Y-Framework/DMG"
if [[ ! -d "$FRAMEWORK_DIR" ]]; then
  FRAMEWORK_DIR="$ROOT_DIR/../Y-Framework/DMG"
fi
if [[ ! -f "$FRAMEWORK_DIR/YDMGFramework.zsh" ]]; then
  echo "错误：找不到 Y-Framework/DMG。" >&2
  exit 1
fi

Y_DMG_APP_NAME="${APP_NAME_OVERRIDE:-Y-Clip}"
Y_DMG_APP_PATH="${APP_PATH_OVERRIDE:-$ROOT_DIR/build/Y-Clip.app}"
Y_DMG_VOLUME_NAME="${VOLUME_NAME_OVERRIDE:-Y-Clip}"
Y_DMG_OUTPUT_PATH="${DMG_OUTPUT_PATH_OVERRIDE:-${OUTPUT_PATH_OVERRIDE:-$ROOT_DIR/dist/Y-Clip.dmg}}"
Y_DMG_HIDDEN_APP_NAMES=("Global Clipboard")

source "$FRAMEWORK_DIR/YDMGFramework.zsh"
y_dmg_build
