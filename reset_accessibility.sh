#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.lixingchen.GlobalClipboard"
EXECUTABLE_NAME="GlobalClipboard"
APP_PATH="/Applications/Y-Clip.app"
EXPECTED_TEAM_ID="A94225N8T5"

if [[ ! -d "$APP_PATH" ]]; then
  echo "错误：未找到 $APP_PATH。请先安装正式发布版。" >&2
  exit 1
fi

INSTALLED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [[ "$INSTALLED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "错误：$APP_PATH 的 Bundle ID 为 $INSTALLED_BUNDLE_ID，不是 $BUNDLE_ID。" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
if ! grep -q "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$SIGNATURE_INFO"; then
  echo "错误：$APP_PATH 不是预期团队 $EXPECTED_TEAM_ID 的正式签名副本。" >&2
  exit 1
fi

pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
for _ in {1..50}; do
  pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || break
  sleep 0.1
done
if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
  pkill -KILL -x "$EXECUTABLE_NAME" 2>/dev/null || true
fi
tccutil reset Accessibility "$BUNDLE_ID"
open -n "$APP_PATH"

echo "已重置 $BUNDLE_ID 的辅助功能权限并重新打开正式安装版。"
echo "请在 System Settings → Privacy & Security → Accessibility 中重新允许 Y-Clip。"
