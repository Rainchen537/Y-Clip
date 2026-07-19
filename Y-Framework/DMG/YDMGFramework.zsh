#!/bin/zsh

# Y-Project 通用 DMG 打包框架。
# 接入方先设置 Y_DMG_* 配置和 Y_DMG_HIDDEN_APP_NAMES 数组，再调用 y_dmg_build。

typeset -g Y_DMG_FRAMEWORK_DIR="${${(%):-%N}:A:h}"

y_dmg_build() {
  emulate -L zsh
  setopt ERR_EXIT NO_UNSET PIPE_FAIL LOCAL_TRAPS

  local app_name="${Y_DMG_APP_NAME:?缺少 Y_DMG_APP_NAME}"
  local app_path="${Y_DMG_APP_PATH:?缺少 Y_DMG_APP_PATH}"
  local volume_name="${Y_DMG_VOLUME_NAME:?缺少 Y_DMG_VOLUME_NAME}"
  local output_path="${Y_DMG_OUTPUT_PATH:?缺少 Y_DMG_OUTPUT_PATH}"
  local framework_dir="$Y_DMG_FRAMEWORK_DIR"
  local background_generator="${Y_DMG_BACKGROUND_GENERATOR:-$framework_dir/DmgBackgroundGenerator.swift}"
  local background_title="${Y_DMG_BACKGROUND_TITLE:-$app_name}"
  local window_left="${Y_DMG_WINDOW_LEFT:-200}"
  local window_top="${Y_DMG_WINDOW_TOP:-150}"
  local window_width="${Y_DMG_WINDOW_WIDTH:-640}"
  local window_height="${Y_DMG_WINDOW_HEIGHT:-400}"
  local icon_size="${Y_DMG_ICON_SIZE:-128}"
  local app_icon_x="${Y_DMG_APP_ICON_X:-165}"
  local app_icon_y="${Y_DMG_APP_ICON_Y:-200}"
  local applications_icon_x="${Y_DMG_APPLICATIONS_ICON_X:-475}"
  local applications_icon_y="${Y_DMG_APPLICATIONS_ICON_Y:-200}"
  local window_right=$((window_left + window_width))
  local window_bottom=$((window_top + window_height))
  local output_dir="${output_path:h}"
  local app_item_name="$app_name.app"
  local -a hidden_app_names=("${Y_DMG_HIDDEN_APP_NAMES[@]}")

  if [[ ! -d "$app_path" || -L "$app_path" ]]; then
    print -u2 "错误：找不到有效 App：$app_path"
    return 1
  fi
  if [[ ! -f "$background_generator" ]]; then
    print -u2 "错误：找不到 DMG 背景生成器：$background_generator"
    return 1
  fi
  if [[ "$app_name" == */* || "$volume_name" == */* ]]; then
    print -u2 "错误：应用名称和卷名称不能包含斜杠。"
    return 1
  fi

  /bin/mkdir -p "$output_dir"

  local work_root
  work_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/y-project-dmg.XXXXXX")"
  local stage_dir="$work_root/stage"
  local background_path="$work_root/bg.png"
  local writable_dmg="$work_root/writable.dmg"
  local compressed_dmg="$work_root/final.dmg"
  local mount_dir=""
  local mounted_target=""
  local verify_mount=""
  local verify_target=""
  local mounted=0
  local verify_mounted=0
  typeset -g Y_DMG_CLEANUP_WORK_ROOT="$work_root"
  typeset -g Y_DMG_CLEANUP_MOUNT_TARGET=""
  typeset -g Y_DMG_CLEANUP_VERIFY_TARGET=""

  cleanup_y_dmg_work() {
    if [[ -n "${Y_DMG_CLEANUP_VERIFY_TARGET:-}" ]]; then
      /usr/bin/hdiutil detach "$Y_DMG_CLEANUP_VERIFY_TARGET" >/dev/null 2>&1 || \
        /usr/bin/hdiutil detach "$Y_DMG_CLEANUP_VERIFY_TARGET" -force >/dev/null 2>&1 || true
    fi
    if [[ -n "${Y_DMG_CLEANUP_MOUNT_TARGET:-}" ]]; then
      /usr/bin/hdiutil detach "$Y_DMG_CLEANUP_MOUNT_TARGET" >/dev/null 2>&1 || \
        /usr/bin/hdiutil detach "$Y_DMG_CLEANUP_MOUNT_TARGET" -force >/dev/null 2>&1 || true
    fi
    if [[ -n "${Y_DMG_CLEANUP_WORK_ROOT:-}" ]]; then
      /bin/rm -rf "$Y_DMG_CLEANUP_WORK_ROOT"
    fi
    typeset -g Y_DMG_CLEANUP_WORK_ROOT=""
    typeset -g Y_DMG_CLEANUP_MOUNT_TARGET=""
    typeset -g Y_DMG_CLEANUP_VERIFY_TARGET=""
  }
  TRAPEXIT() {
    if (( ZSH_SUBSHELL == 0 )); then
      cleanup_y_dmg_work
    fi
  }

  y_dmg_plist_entity_value() {
    local plist_path="$1"
    local key="$2"
    local index value
    for index in {0..15}; do
      if value="$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:$key" "$plist_path" 2>/dev/null)"; then
        if [[ -n "$value" ]]; then
          print -r -- "$value"
          return 0
        fi
      fi
    done
    return 1
  }

  /bin/mkdir -p "$stage_dir/.background"

  /usr/bin/xcrun swift "$background_generator" \
    "$background_path" \
    "$background_title" \
    "$window_width" \
    "$window_height"

  local background_width background_height
  background_width="$(/usr/bin/sips -g pixelWidth "$background_path" 2>/dev/null | /usr/bin/awk '/pixelWidth/ { print $2; exit }')"
  background_height="$(/usr/bin/sips -g pixelHeight "$background_path" 2>/dev/null | /usr/bin/awk '/pixelHeight/ { print $2; exit }')"
  if [[ "$background_width" != "$window_width" || "$background_height" != "$window_height" ]]; then
    print -u2 "错误：DMG 背景尺寸 ${background_width}×${background_height} 与窗口 ${window_width}×${window_height} 不一致。"
    return 1
  fi

  /usr/bin/ditto --noextattr --noqtn "$app_path" "$stage_dir/$app_item_name"
  /usr/bin/xattr -cr "$stage_dir/$app_item_name"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$stage_dir/$app_item_name"

  local hidden_name
  for hidden_name in "${hidden_app_names[@]}"; do
    [[ -n "$hidden_name" ]] || continue
    if [[ "$hidden_name" == */* || "$hidden_name" == "$app_name" ]]; then
      print -u2 "错误：无效的隐藏兼容 App 名称：$hidden_name"
      return 1
    fi
    /usr/bin/ditto --noextattr --noqtn "$app_path" "$stage_dir/$hidden_name.app"
    /usr/bin/xattr -cr "$stage_dir/$hidden_name.app"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$stage_dir/$hidden_name.app"
  done

  if (( ${#hidden_app_names[@]} > 0 )); then
    : > "$stage_dir/.hidden"
    for hidden_name in "${hidden_app_names[@]}"; do
      [[ -n "$hidden_name" ]] || continue
      print -r -- "$hidden_name.app" >> "$stage_dir/.hidden"
    done
  fi

  /bin/ln -s /Applications "$stage_dir/Applications"
  /bin/cp "$background_path" "$stage_dir/.background/bg.png"
  /usr/bin/chflags hidden "$stage_dir/.background"

  /usr/bin/hdiutil create \
    -srcfolder "$stage_dir" \
    -volname "$volume_name" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$writable_dmg" >/dev/null

  local attach_plist="$work_root/attach.plist"
  /usr/bin/hdiutil attach "$writable_dmg" \
    -readwrite \
    -noverify \
    -noautoopen \
    -plist > "$attach_plist"
  mounted_target="$(y_dmg_plist_entity_value "$attach_plist" "dev-entry")"
  mount_dir="$(y_dmg_plist_entity_value "$attach_plist" "mount-point")"
  mounted=1
  typeset -g Y_DMG_CLEANUP_MOUNT_TARGET="$mount_dir"

  /usr/bin/osascript - \
    "$mount_dir" \
    "$app_item_name" \
    "$window_left" \
    "$window_top" \
    "$window_right" \
    "$window_bottom" \
    "$icon_size" \
    "$app_icon_x" \
    "$app_icon_y" \
    "$applications_icon_x" \
    "$applications_icon_y" <<'APPLESCRIPT'
on run arguments
  set mountPath to item 1 of arguments
  set appItemName to item 2 of arguments
  set windowLeft to (item 3 of arguments) as integer
  set windowTop to (item 4 of arguments) as integer
  set windowRight to (item 5 of arguments) as integer
  set windowBottom to (item 6 of arguments) as integer
  set configuredIconSize to (item 7 of arguments) as integer
  set appIconX to (item 8 of arguments) as integer
  set appIconY to (item 9 of arguments) as integer
  set applicationsIconX to (item 10 of arguments) as integer
  set applicationsIconY to (item 11 of arguments) as integer
  set mountedAlias to POSIX file mountPath as alias
  set backgroundAlias to POSIX file (mountPath & "/.background/bg.png") as alias

  tell application "Finder"
    set targetFolder to folder mountedAlias
    set targetDisk to disk of targetFolder
    tell targetDisk
      open
      delay 1
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {windowLeft, windowTop, windowRight, windowBottom}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to configuredIconSize
      set text size of viewOptions to 12
      set background picture of viewOptions to backgroundAlias
      set position of item appItemName to {appIconX, appIconY}
      set position of item "Applications" to {applicationsIconX, applicationsIconY}
      update without registering applications
      delay 2

      if position of item appItemName is not {appIconX, appIconY} then error "Finder 未保存 App 图标位置。"
      if position of item "Applications" is not {applicationsIconX, applicationsIconY} then error "Finder 未保存 Applications 图标位置。"
      close container window
    end tell
  end tell
end run
APPLESCRIPT

  if [[ ! -f "$mount_dir/.DS_Store" ]]; then
    print -u2 "错误：Finder 未生成 .DS_Store，DMG 布局无法持久化。"
    return 1
  fi
  if ! /usr/bin/strings "$mount_dir/.DS_Store" | /usr/bin/grep -Fq '/.background/bg.png'; then
    print -u2 "错误：Finder 未把背景图写入 DMG 布局。"
    return 1
  fi

  /usr/bin/xattr -cr "$mount_dir/$app_item_name"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/$app_item_name"
  for hidden_name in "${hidden_app_names[@]}"; do
    [[ -n "$hidden_name" ]] || continue
    /usr/bin/xattr -cr "$mount_dir/$hidden_name.app"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/$hidden_name.app"
  done
  /bin/sync
  /usr/bin/hdiutil detach "$mount_dir" >/dev/null
  mounted=0
  mount_dir=""
  mounted_target=""
  typeset -g Y_DMG_CLEANUP_MOUNT_TARGET=""

  /usr/bin/hdiutil convert "$writable_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$compressed_dmg" >/dev/null
  /usr/bin/hdiutil verify "$compressed_dmg" >/dev/null

  local verify_plist="$work_root/verify.plist"
  /usr/bin/hdiutil attach "$compressed_dmg" \
    -readonly \
    -nobrowse \
    -noautoopen \
    -plist > "$verify_plist"
  verify_target="$(y_dmg_plist_entity_value "$verify_plist" "dev-entry")"
  verify_mount="$(y_dmg_plist_entity_value "$verify_plist" "mount-point")"
  verify_mounted=1
  typeset -g Y_DMG_CLEANUP_VERIFY_TARGET="$verify_mount"

  if [[ ! -d "$verify_mount/$app_item_name" || -L "$verify_mount/$app_item_name" ]]; then
    print -u2 "错误：最终 DMG 缺少有效的 $app_item_name。"
    return 1
  fi
  if [[ ! -L "$verify_mount/Applications" || "$(/usr/bin/readlink "$verify_mount/Applications")" != "/Applications" ]]; then
    print -u2 "错误：最终 DMG 的 Applications 链接无效。"
    return 1
  fi
  if [[ ! -f "$verify_mount/.background/bg.png" || ! -f "$verify_mount/.DS_Store" ]]; then
    print -u2 "错误：最终 DMG 缺少背景图或 Finder 布局。"
    return 1
  fi
  if ! /usr/bin/strings "$verify_mount/.DS_Store" | /usr/bin/grep -Fq '/.background/bg.png'; then
    print -u2 "错误：最终 DMG 的 Finder 背景记录无效。"
    return 1
  fi

  background_width="$(/usr/bin/sips -g pixelWidth "$verify_mount/.background/bg.png" 2>/dev/null | /usr/bin/awk '/pixelWidth/ { print $2; exit }')"
  background_height="$(/usr/bin/sips -g pixelHeight "$verify_mount/.background/bg.png" 2>/dev/null | /usr/bin/awk '/pixelHeight/ { print $2; exit }')"
  if [[ "$background_width" != "$window_width" || "$background_height" != "$window_height" ]]; then
    print -u2 "错误：最终 DMG 背景尺寸错误。"
    return 1
  fi

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$verify_mount/$app_item_name"
  for hidden_name in "${hidden_app_names[@]}"; do
    [[ -n "$hidden_name" ]] || continue
    if [[ ! -d "$verify_mount/$hidden_name.app" ]]; then
      print -u2 "错误：最终 DMG 缺少隐藏兼容副本 $hidden_name.app。"
      return 1
    fi
    if [[ ! -f "$verify_mount/.hidden" ]] || \
       ! /usr/bin/grep -Fxq "$hidden_name.app" "$verify_mount/.hidden"; then
      print -u2 "错误：兼容副本 $hidden_name.app 未写入 Finder 隐藏清单。"
      return 1
    fi
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$verify_mount/$hidden_name.app"
  done

  /usr/bin/osascript - \
    "$verify_mount" \
    "$app_item_name" \
    "$app_icon_x" \
    "$applications_icon_x" <<'APPLESCRIPT'
on run arguments
  set mountPath to item 1 of arguments
  set appItemName to item 2 of arguments
  set appIconX to (item 3 of arguments) as integer
  set applicationsIconX to (item 4 of arguments) as integer
  set mountedAlias to POSIX file mountPath as alias

  tell application "Finder"
    set targetFolder to folder mountedAlias
    set targetDisk to disk of targetFolder
    tell targetDisk
      open
      delay 1
      if current view of container window is not icon view then error "最终 DMG 未使用图标视图。"
      set appPosition to position of item appItemName
      set applicationsPosition to position of item "Applications"
      if item 1 of appPosition is not appIconX then error "最终 DMG 的 App 图标横向位置错误。"
      if item 1 of applicationsPosition is not applicationsIconX then error "最终 DMG 的 Applications 图标横向位置错误。"
      if item 2 of appPosition is not item 2 of applicationsPosition then error "最终 DMG 的图标未保持水平对齐。"
      close container window
    end tell
  end tell
end run
APPLESCRIPT

  /usr/bin/hdiutil detach "$verify_mount" >/dev/null
  verify_mounted=0
  verify_mount=""
  verify_target=""
  typeset -g Y_DMG_CLEANUP_VERIFY_TARGET=""

  local staged_output="$output_dir/.${output_path:t}.new.$$"
  /bin/rm -f "$staged_output"
  /usr/bin/ditto "$compressed_dmg" "$staged_output"
  /bin/mv -f "$staged_output" "$output_path"

  print "已生成并验证：$output_path"
  /bin/ls -lh "$output_path"
  cleanup_y_dmg_work
}
