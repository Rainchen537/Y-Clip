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
  local background_scale="${Y_DMG_BACKGROUND_SCALE:-2}"
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
  if [[ "$background_scale" != <1-4> ]]; then
    print -u2 "错误：Y_DMG_BACKGROUND_SCALE 必须是 1 到 4 的整数。"
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

  y_dmg_detach_with_retry() {
    local target="$1"
    local attempt
    for attempt in {1..5}; do
      if /usr/bin/hdiutil detach "$target" >/dev/null 2>&1; then
        return 0
      fi
      /bin/sleep 1
    done
    /usr/bin/hdiutil detach "$target" -force >/dev/null
  }

  cleanup_y_dmg_work() {
    if [[ -n "${Y_DMG_CLEANUP_VERIFY_TARGET:-}" ]]; then
      y_dmg_detach_with_retry "$Y_DMG_CLEANUP_VERIFY_TARGET" >/dev/null 2>&1 || true
    fi
    if [[ -n "${Y_DMG_CLEANUP_MOUNT_TARGET:-}" ]]; then
      y_dmg_detach_with_retry "$Y_DMG_CLEANUP_MOUNT_TARGET" >/dev/null 2>&1 || true
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

  /bin/mkdir -p "$stage_dir/.Trashes" "$stage_dir/.fseventsd"
  : > "$stage_dir/.fseventsd/no_log"
  : > "$stage_dir/.metadata_never_index"

  /usr/bin/xcrun swift "$background_generator" \
    "$background_path" \
    "$background_title" \
    "$window_width" \
    "$window_height" \
    "$app_icon_x" \
    "$app_icon_y" \
    "$applications_icon_x" \
    "$applications_icon_y" \
    "$icon_size" \
    "$background_scale"

  local expected_background_width=$((window_width * background_scale))
  local expected_background_height=$((window_height * background_scale))
  local expected_background_dpi=$((72 * background_scale))
  local background_width background_height background_dpi
  background_width="$(/usr/bin/sips -g pixelWidth "$background_path" 2>/dev/null | /usr/bin/awk '/pixelWidth/ { print $2; exit }')"
  background_height="$(/usr/bin/sips -g pixelHeight "$background_path" 2>/dev/null | /usr/bin/awk '/pixelHeight/ { print $2; exit }')"
  background_dpi="$(/usr/bin/sips -g dpiWidth "$background_path" 2>/dev/null | /usr/bin/awk '/dpiWidth/ { print int($2 + 0.5); exit }')"
  if [[ "$background_width" != "$expected_background_width" || \
        "$background_height" != "$expected_background_height" || \
        "$background_dpi" != "$expected_background_dpi" ]]; then
    print -u2 "错误：DMG 背景必须为 ${expected_background_width}×${expected_background_height}、${expected_background_dpi} DPI，实际为 ${background_width}×${background_height}、${background_dpi} DPI。"
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
    /usr/bin/chflags hidden "$stage_dir/$hidden_name.app"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$stage_dir/$hidden_name.app"
  done

  /bin/ln -s /Applications "$stage_dir/Applications"
  /bin/cp "$background_path" "$stage_dir/.Trashes/bg.png"
  /usr/bin/chflags hidden \
    "$stage_dir/.Trashes" \
    "$stage_dir/.fseventsd" \
    "$stage_dir/.metadata_never_index"

  /usr/bin/hdiutil create \
    -srcfolder "$stage_dir" \
    -volname "$volume_name" \
    -fs APFS \
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
  typeset -g Y_DMG_CLEANUP_MOUNT_TARGET="$mounted_target"
  /usr/bin/chflags hidden \
    "$mount_dir/.Trashes" \
    "$mount_dir/.fseventsd" \
    "$mount_dir/.metadata_never_index"

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
    "$applications_icon_y" \
    "${hidden_app_names[@]}" <<'APPLESCRIPT'
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
  set backgroundAlias to POSIX file (mountPath & "/.Trashes/bg.png") as alias

  tell application "Finder"
    set targetFolder to folder mountedAlias
    set targetDisk to disk of targetFolder
    tell targetDisk
      open
      delay 1
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set pathbar visible of container window to false
      tell application "Finder" to activate
      tell application "System Events"
        tell process "Finder"
          if exists (first UI element of front window whose role is "AXTabGroup") then
            keystroke "t" using {command down, shift down}
            delay 1
          end if
          if exists (first UI element of front window whose role is "AXTabGroup") then
            error "Finder 未隐藏标签页栏。"
          end if
        end tell
      end tell
      set the bounds of container window to {windowLeft, windowTop, windowRight, windowBottom}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to configuredIconSize
      set text size of viewOptions to 12
      set background picture of viewOptions to backgroundAlias
      set position of item appItemName to {appIconX, appIconY}
      set position of item "Applications" to {applicationsIconX, applicationsIconY}
      if (count of arguments) is greater than 11 then
        repeat with argumentIndex from 12 to count of arguments
          set hiddenItemName to ((item argumentIndex of arguments) as text) & ".app"
          set hiddenIconX to (windowRight - windowLeft) + configuredIconSize * 2 + (argumentIndex - 12) * configuredIconSize
          set hiddenIconY to appIconY
          set position of item hiddenItemName to {hiddenIconX, hiddenIconY}
        end repeat
      end if
      update without registering applications
      delay 2

      if position of item appItemName is not {appIconX, appIconY} then error "Finder 未保存 App 图标位置。"
      if position of item "Applications" is not {applicationsIconX, applicationsIconY} then error "Finder 未保存 Applications 图标位置。"
      if (count of arguments) is greater than 11 then
        repeat with argumentIndex from 12 to count of arguments
          set hiddenItemName to ((item argumentIndex of arguments) as text) & ".app"
          set hiddenIconX to (windowRight - windowLeft) + configuredIconSize * 2 + (argumentIndex - 12) * configuredIconSize
          set hiddenPosition to position of item hiddenItemName
          if item 1 of hiddenPosition is not hiddenIconX or item 2 of hiddenPosition is not appIconY then error "Finder 未保存兼容 App 的画外位置。"
        end repeat
      end if
      close container window
    end tell
  end tell
end run
APPLESCRIPT

  if [[ ! -f "$mount_dir/.DS_Store" ]]; then
    print -u2 "错误：Finder 未生成 .DS_Store，DMG 布局无法持久化。"
    return 1
  fi
  if ! /usr/bin/strings "$mount_dir/.DS_Store" | /usr/bin/grep -Fq '/.Trashes/bg.png'; then
    print -u2 "错误：Finder 未把背景图写入 DMG 布局。"
    return 1
  fi

  /usr/bin/xattr -cr "$mount_dir/$app_item_name"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/$app_item_name"
  for hidden_name in "${hidden_app_names[@]}"; do
    [[ -n "$hidden_name" ]] || continue
    /usr/bin/xattr -cr "$mount_dir/$hidden_name.app"
    /usr/bin/chflags nohidden "$mount_dir/$hidden_name.app"
    /usr/bin/chflags hidden "$mount_dir/$hidden_name.app"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/$hidden_name.app"
    if [[ "$(/usr/bin/stat -f '%Sf' "$mount_dir/$hidden_name.app")" != *hidden* ]]; then
      print -u2 "错误：兼容副本 $hidden_name.app 未保留 BSD hidden 标志。"
      return 1
    fi
  done
  /bin/rm -rf \
    "$mount_dir/.fseventsd" \
    "$mount_dir/.metadata_never_index" \
    "$mount_dir/.Spotlight-V100" \
    "$mount_dir/.TemporaryItems" \
    "$mount_dir/.DocumentRevisions-V100"
  /bin/sync
  y_dmg_detach_with_retry "$mounted_target"
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
  typeset -g Y_DMG_CLEANUP_VERIFY_TARGET="$verify_target"

  if [[ ! -d "$verify_mount/$app_item_name" || -L "$verify_mount/$app_item_name" ]]; then
    print -u2 "错误：最终 DMG 缺少有效的 $app_item_name。"
    return 1
  fi
  if [[ ! -L "$verify_mount/Applications" || "$(/usr/bin/readlink "$verify_mount/Applications")" != "/Applications" ]]; then
    print -u2 "错误：最终 DMG 的 Applications 链接无效。"
    return 1
  fi
  if [[ ! -f "$verify_mount/.Trashes/bg.png" || ! -f "$verify_mount/.DS_Store" ]]; then
    print -u2 "错误：最终 DMG 缺少背景图或 Finder 布局。"
    return 1
  fi
  if ! /usr/bin/strings "$verify_mount/.DS_Store" | /usr/bin/grep -Fq '/.Trashes/bg.png'; then
    print -u2 "错误：最终 DMG 的 Finder 背景记录无效。"
    return 1
  fi

  local unwanted_metadata
  for unwanted_metadata in \
    .background \
    .fseventsd \
    .hidden \
    .metadata_never_index \
    .Spotlight-V100 \
    .TemporaryItems \
    .DocumentRevisions-V100; do
    if [[ -e "$verify_mount/$unwanted_metadata" ]]; then
      print -u2 "错误：最终 DMG 含有不应出现的元数据项 $unwanted_metadata。"
      return 1
    fi
  done

  background_width="$(/usr/bin/sips -g pixelWidth "$verify_mount/.Trashes/bg.png" 2>/dev/null | /usr/bin/awk '/pixelWidth/ { print $2; exit }')"
  background_height="$(/usr/bin/sips -g pixelHeight "$verify_mount/.Trashes/bg.png" 2>/dev/null | /usr/bin/awk '/pixelHeight/ { print $2; exit }')"
  background_dpi="$(/usr/bin/sips -g dpiWidth "$verify_mount/.Trashes/bg.png" 2>/dev/null | /usr/bin/awk '/dpiWidth/ { print int($2 + 0.5); exit }')"
  if [[ "$background_width" != "$expected_background_width" || \
        "$background_height" != "$expected_background_height" || \
        "$background_dpi" != "$expected_background_dpi" ]]; then
    print -u2 "错误：最终 DMG 背景分辨率或 DPI 错误。"
    return 1
  fi

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$verify_mount/$app_item_name"
  for hidden_name in "${hidden_app_names[@]}"; do
    [[ -n "$hidden_name" ]] || continue
    if [[ ! -d "$verify_mount/$hidden_name.app" ]]; then
      print -u2 "错误：最终 DMG 缺少隐藏兼容副本 $hidden_name.app。"
      return 1
    fi
    if [[ "$(/usr/bin/stat -f '%Sf' "$verify_mount/$hidden_name.app")" != *hidden* ]]; then
      print -u2 "错误：兼容副本 $hidden_name.app 未保留 BSD hidden 标志。"
      return 1
    fi
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$verify_mount/$hidden_name.app"
  done

  /usr/bin/osascript - \
    "$verify_mount" \
    "$app_item_name" \
    "$app_icon_x" \
    "$app_icon_y" \
    "$applications_icon_x" \
    "$applications_icon_y" \
    "$window_width" \
    "$icon_size" \
    "${hidden_app_names[@]}" <<'APPLESCRIPT'
on run arguments
  set mountPath to item 1 of arguments
  set appItemName to item 2 of arguments
  set appIconX to (item 3 of arguments) as integer
  set appIconY to (item 4 of arguments) as integer
  set applicationsIconX to (item 5 of arguments) as integer
  set applicationsIconY to (item 6 of arguments) as integer
  set windowWidth to (item 7 of arguments) as integer
  set configuredIconSize to (item 8 of arguments) as integer
  set mountedAlias to POSIX file mountPath as alias

  tell application "Finder"
    set targetFolder to folder mountedAlias
    set targetDisk to disk of targetFolder
    tell targetDisk
      open
      delay 1
      tell application "Finder" to activate
      tell application "System Events"
        tell process "Finder"
          if exists (first UI element of front window whose role is "AXTabGroup") then
            error "最终 DMG 未隐藏标签页栏。"
          end if
        end tell
      end tell
      if current view of container window is not icon view then error "最终 DMG 未使用图标视图。"
      if toolbar visible of container window then error "最终 DMG 未隐藏工具栏。"
      if statusbar visible of container window then error "最终 DMG 未隐藏状态栏。"
      if pathbar visible of container window then error "最终 DMG 未隐藏路径栏。"

      set appPosition to position of item appItemName
      set applicationsPosition to position of item "Applications"
      if item 1 of appPosition is not appIconX or item 2 of appPosition is not appIconY then error "最终 DMG 的 App 图标位置错误。"
      if item 1 of applicationsPosition is not applicationsIconX or item 2 of applicationsPosition is not applicationsIconY then error "最终 DMG 的 Applications 图标位置错误。"
      if (count of arguments) is greater than 8 then
        repeat with argumentIndex from 9 to count of arguments
          set hiddenItemName to ((item argumentIndex of arguments) as text) & ".app"
          set hiddenIconX to windowWidth + configuredIconSize * 2 + (argumentIndex - 9) * configuredIconSize
          set hiddenPosition to position of item hiddenItemName
          if item 1 of hiddenPosition is not hiddenIconX or item 2 of hiddenPosition is not appIconY then error "最终 DMG 的兼容 App 画外位置错误。"
        end repeat
      end if
      close container window
    end tell
  end tell
end run
APPLESCRIPT

  y_dmg_detach_with_retry "$verify_target"
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
