#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "${Y_RELEASE_REQUIRE_VENDORED:-0}" == "1" &&
      ( ! -d "$ROOT_DIR/Y-Framework" || -L "$ROOT_DIR/Y-Framework" ) ]]; then
  echo "错误：正式发布要求仓库内非符号链接 Y-Framework 根目录。" >&2
  exit 1
fi
FRAMEWORK_DIR="$ROOT_DIR/Y-Framework/DMG"
if [[ ! -d "$FRAMEWORK_DIR" ||
      ( "${Y_RELEASE_REQUIRE_VENDORED:-0}" == "1" && -L "$FRAMEWORK_DIR" ) ]]; then
  if [[ "${Y_RELEASE_REQUIRE_VENDORED:-0}" == "1" ]]; then
    echo "错误：正式发布要求仓库内非符号链接 vendored DMG 框架，禁止回退父目录。" >&2
    exit 1
  fi
  FRAMEWORK_DIR="$ROOT_DIR/../Y-Framework/DMG"
fi
if [[ ! -f "$FRAMEWORK_DIR/YDMGFramework.zsh" ]]; then
  echo "错误：找不到 Y-Framework/DMG。" >&2
  exit 1
fi
if [[ "${Y_RELEASE_REQUIRE_VENDORED:-0}" == "1" ]]; then
  if [[ -L "$FRAMEWORK_DIR/YDMGFramework.zsh" ||
        ! -f "$FRAMEWORK_DIR/DmgBackgroundGenerator.swift" ||
        -L "$FRAMEWORK_DIR/DmgBackgroundGenerator.swift" ]]; then
    echo "错误：正式发布要求仓库内普通文件形式的 DMG 框架和背景生成器。" >&2
    exit 1
  fi
  unset Y_DMG_BACKGROUND_TITLE Y_DMG_WINDOW_LEFT Y_DMG_WINDOW_TOP
  unset Y_DMG_WINDOW_WIDTH Y_DMG_WINDOW_HEIGHT Y_DMG_ICON_SIZE
  unset Y_DMG_BACKGROUND_SCALE Y_DMG_APP_ICON_X Y_DMG_APP_ICON_Y
  unset Y_DMG_APPLICATIONS_ICON_X Y_DMG_APPLICATIONS_ICON_Y
  Y_DMG_BACKGROUND_GENERATOR="$FRAMEWORK_DIR/DmgBackgroundGenerator.swift"
fi

Y_DMG_APP_NAME="${APP_NAME_OVERRIDE:-Y-Clip}"
Y_DMG_APP_PATH="${APP_PATH_OVERRIDE:-$ROOT_DIR/build/Y-Clip.app}"
Y_DMG_VOLUME_NAME="${VOLUME_NAME_OVERRIDE:-Y-Clip}"
Y_DMG_OUTPUT_PATH="${DMG_OUTPUT_PATH_OVERRIDE:-${OUTPUT_PATH_OVERRIDE:-$ROOT_DIR/dist/Y-Clip.dmg}}"
Y_DMG_HIDDEN_APP_NAMES=("Global Clipboard")

source "$FRAMEWORK_DIR/YDMGFramework.zsh"
y_dmg_build
