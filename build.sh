#!/bin/zsh
set -euo pipefail

APP_NAME="Y-Clip"
LEGACY_APP_NAME="Global Clipboard"
EXECUTABLE_NAME="GlobalClipboard"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
FINAL_APP_DIR="${APP_PATH:-$BUILD_DIR/$APP_NAME.app}"
LEGACY_APP_DIR="$BUILD_DIR/$LEGACY_APP_NAME.app"
TMP_PARENT="${TMPDIR:-/tmp}"
ENTITLEMENTS="$ROOT_DIR/GlobalClipboard.entitlements"

case "$TARGET_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "错误：TARGET_ARCH 只允许 arm64 或 x86_64，当前值：$TARGET_ARCH" >&2
    exit 1
    ;;
esac

if [[ "$FINAL_APP_DIR" != *.app || "$FINAL_APP_DIR" == "/" ]]; then
  echo "错误：APP_PATH 必须指向有效的 .app 输出路径。" >&2
  exit 1
fi

TMP_BUILD_DIR="$(mktemp -d "$TMP_PARENT/global-clipboard-$TARGET_ARCH-build.XXXXXX")"
APP_DIR="$TMP_BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
trap 'rm -rf "$TMP_BUILD_DIR"' EXIT

assert_thin_binary() {
  local binary_path="$1"
  local actual_archs
  if [[ ! -f "$binary_path" ]]; then
    echo "错误：找不到待验证的可执行文件：$binary_path" >&2
    return 1
  fi
  actual_archs="$(/usr/bin/lipo -archs "$binary_path" 2>/dev/null)" || {
    echo "错误：无法读取可执行文件架构：$binary_path" >&2
    return 1
  }
  if [[ "$actual_archs" != "$TARGET_ARCH" ]]; then
    echo "错误：要求 $TARGET_ARCH thin binary，实际架构为：$actual_archs" >&2
    return 1
  fi
}

# 签名模式：
#   RELEASE=1 时用 Developer ID + hardened runtime（发布/公证用）；
#   否则默认使用 ad-hoc 签名，避免日常构建访问钥匙串证书。
RELEASE="${RELEASE:-0}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"

if [[ "$RELEASE" == "1" ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/Developer ID Application.*\(A94225N8T5\)/ { print $2; exit }')"
  fi
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "错误：RELEASE=1 但找不到 Developer ID Application 证书。" >&2
    echo "请在 Xcode → Settings → Accounts → Manage Certificates 生成。" >&2
    exit 1
  fi
else
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

# 先在临时目录中构建和签名，避免 iCloud/File Provider 工作区给 .app 附加 FinderInfo 导致 codesign 拒签。
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$RESOURCES_DIR"

cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

if [[ -f "$ROOT_DIR/icon/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/icon/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

SETTING_FRAMEWORK_DIR="$ROOT_DIR/Y-Framework/Setting"
PERMISSION_FRAMEWORK_DIR="$ROOT_DIR/Y-Framework/Permission"
if [[ ! -d "$SETTING_FRAMEWORK_DIR" ]]; then
  SETTING_FRAMEWORK_DIR="$ROOT_DIR/../Y-Framework/Setting"
fi
if [[ ! -d "$PERMISSION_FRAMEWORK_DIR" ]]; then
  PERMISSION_FRAMEWORK_DIR="$ROOT_DIR/../Y-Framework/Permission"
fi
FRAMEWORK_SOURCES=(
  "$SETTING_FRAMEWORK_DIR"/*.swift(N)
  "$PERMISSION_FRAMEWORK_DIR"/*.swift(N)
)
if (( ${#FRAMEWORK_SOURCES[@]} < 2 )); then
  echo "错误：找不到 Y-Framework/Setting 或 Permission Swift 源文件。" >&2
  exit 1
fi

xcrun swiftc \
  -swift-version 5 \
  -target "$TARGET_ARCH-apple-macosx13.0" \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  -framework ServiceManagement \
  -framework Security \
  -O \
  "${FRAMEWORK_SOURCES[@]}" \
  "$ROOT_DIR"/Sources/*.swift \
  -o "$MACOS_DIR/$EXECUTABLE_NAME"

assert_thin_binary "$MACOS_DIR/$EXECUTABLE_NAME"

xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true

if [[ "$RELEASE" == "1" ]]; then
  # 发布签名：hardened runtime + 安全时间戳 + entitlements。
  # 注意不用 --deep（Apple 已不推荐，对公证不可靠）；本 app 无内嵌组件，直接签 bundle 即可。
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP_DIR"
else
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
fi

rm -rf "$FINAL_APP_DIR"
if [[ "$LEGACY_APP_DIR" != "$FINAL_APP_DIR" ]]; then
  rm -rf "$LEGACY_APP_DIR"
fi
mkdir -p "$(dirname "$FINAL_APP_DIR")"
ditto --noextattr --noqtn "$APP_DIR" "$FINAL_APP_DIR"
xattr -cr "$FINAL_APP_DIR"
xattr -d com.apple.FinderInfo "$FINAL_APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$FINAL_APP_DIR" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$FINAL_APP_DIR"
assert_thin_binary "$FINAL_APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

echo "已构建：$FINAL_APP_DIR"
echo "目标架构：$TARGET_ARCH（thin）"
if [[ "$RELEASE" == "1" ]]; then
  echo "模式：发布（Developer ID + hardened runtime）"
else
  echo "模式：本地测试（ad-hoc 签名）"
fi
