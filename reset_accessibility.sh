#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.lixingchen.GlobalClipboard"
APP_NAME="GlobalClipboard"

pkill -x "$APP_NAME" 2>/dev/null || true
tccutil reset Accessibility "$BUNDLE_ID"

echo "已重置 $BUNDLE_ID 的辅助功能权限。"
echo "请重新打开 build/Y-Clip.app，然后在系统设置里重新允许 Y-Clip。"
