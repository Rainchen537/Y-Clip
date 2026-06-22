#!/bin/zsh
set -euo pipefail

APP_NAME="Y-Clip"
LEGACY_APP_NAME="Global Clipboard"
EXECUTABLE_NAME="GlobalClipboard"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
FINAL_APP_DIR="$BUILD_DIR/$APP_NAME.app"
LEGACY_APP_DIR="$BUILD_DIR/$LEGACY_APP_NAME.app"
TMP_PARENT="${TMPDIR:-/tmp}"
TMP_BUILD_DIR="$(mktemp -d "$TMP_PARENT/global-clipboard-build.XXXXXX")"
APP_DIR="$TMP_BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
ENTITLEMENTS="$ROOT_DIR/GlobalClipboard.entitlements"

trap 'rm -rf "$TMP_BUILD_DIR"' EXIT

# 签名模式：
#   RELEASE=1 时用 Developer ID + hardened runtime（发布/公证用）；
#   否则沿用本地证书快速签名（日常测试用）。
RELEASE="${RELEASE:-0}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"

if [[ "$RELEASE" == "1" ]]; then
  # 发布模式：优先选 Developer ID Application 证书
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
  fi
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "错误：RELEASE=1 但找不到 Developer ID Application 证书。" >&2
    echo "请在 Xcode → Settings → Accounts → Manage Certificates 生成。" >&2
    exit 1
  fi
else
  # 测试模式：用本地任意可用证书（找不到则 ad-hoc）
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F '"' '/"[^"]+"/ { print $2; exit }')"
  fi
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
  fi
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

xcrun swiftc \
  -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  -framework ServiceManagement \
  -O \
  "$ROOT_DIR"/Sources/*.swift \
  -o "$MACOS_DIR/$EXECUTABLE_NAME"

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
mkdir -p "$BUILD_DIR"
ditto --noextattr --noqtn "$APP_DIR" "$FINAL_APP_DIR"

echo "已构建：$FINAL_APP_DIR"
echo "签名身份：$SIGN_IDENTITY"
if [[ "$RELEASE" == "1" ]]; then
  echo "模式：发布（hardened runtime）"
else
  echo "模式：本地测试"
fi
