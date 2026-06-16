#!/bin/zsh
set -euo pipefail

# 打包可分发的 DMG：标准拖拽安装窗口（App 图标 → 应用程序文件夹）。
# 依赖：已先执行 ./build.sh 生成 build/Global Clipboard.app
# 用法：./make_dmg.sh

APP_NAME="Global Clipboard"
VOL_NAME="全局剪切板"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$ROOT_DIR/build/$APP_NAME.app"
BG_SRC="$ROOT_DIR/icon/dmg_bg.png"
DIST_DIR="$ROOT_DIR/dist"
DMG_FINAL="$DIST_DIR/$VOL_NAME.dmg"
DMG_TMP="$DIST_DIR/.tmp_$VOL_NAME.dmg"
STAGE_DIR="$DIST_DIR/.stage"

if [[ ! -d "$APP_PATH" ]]; then
  echo "找不到 app：$APP_PATH —— 请先执行 ./build.sh" >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"

# 1) 准备暂存目录内容：app + Applications 软链接 + 背景图
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
mkdir -p "$STAGE_DIR/.background"
if [[ -f "$BG_SRC" ]]; then
  cp "$BG_SRC" "$STAGE_DIR/.background/bg.png"
fi

# 2) 创建可写 DMG（按内容大小自适应 + 余量）
hdiutil create \
  -srcfolder "$STAGE_DIR" \
  -volname "$VOL_NAME" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$DMG_TMP" >/dev/null

# 3) 挂载
MOUNT_DIR="/Volumes/$VOL_NAME"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen >/dev/null
sleep 2

# 4) 用 Finder/AppleScript 设置窗口外观与图标布局
# 失败不致命：无 GUI 会话或未授权控制 Finder 时，跳过美化仍能产出可用 DMG。
osascript <<EOF || echo "（提示：Finder 布局设置被跳过，DMG 仍可正常使用）"
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 840, 550}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set background picture of theViewOptions to file ".background:bg.png"
    set position of item "$APP_NAME.app" of container window to {165, 200}
    set position of item "Applications" of container window to {475, 200}
    set position of item ".background" of container window to {900, 900}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF

sync

# 5) 卸载
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || \
  (sleep 2 && hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1) || true

# 6) 转成压缩只读 DMG
rm -f "$DMG_FINAL"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -f "$DMG_TMP"
rm -rf "$STAGE_DIR"

echo "已生成：$DMG_FINAL"
hdiutil imageinfo "$DMG_FINAL" -format 2>/dev/null | head -1 || true
ls -lh "$DMG_FINAL"
