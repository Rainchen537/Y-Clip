#!/bin/zsh
set -euo pipefail

# 一次生成两个彼此隔离的正式发布包：
#   dist/Y-Clip-v$VERSION-arm64.dmg
#   dist/Y-Clip-v$VERSION-x86_64.dmg
# 每种架构都会独立构建、签名、公证、staple、挂载并验证，不复用 build/ 或 dist/ 中的旧产物。
# 公证凭据必须预先保存在钥匙串 profile 中；脚本不会把账号或密码写入文件或输出。

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Y-Clip"
EXECUTABLE_NAME="GlobalClipboard"
TEAM_ID="A94225N8T5"
BUNDLE_ID="com.lixingchen.GlobalClipboard"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Info.plist")"
DIST_DIR="$ROOT_DIR/dist"
ARCHITECTURES=(arm64 x86_64)
RELEASE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/Y-Clip-release.XXXXXX")"
PUBLISH_STATE_DIR="$RELEASE_WORK/publish-state"
RELEASE_LOCK_DIR="$DIST_DIR/.$APP_NAME-v$VERSION.release.lock"
NOTARY_PROFILE="${NOTARY_PROFILE:-GlobalClipboardNotary}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
CURRENT_MOUNT=""
RELEASE_SUCCEEDED=0
LOCK_ACQUIRED=0
SOURCE_FINGERPRINT=""
mkdir -p "$PUBLISH_STATE_DIR"

final_dmg_path() {
  local arch="$1"
  print -r -- "$DIST_DIR/$APP_NAME-v$VERSION-$arch.dmg"
}

new_dmg_path() {
  local arch="$1"
  print -r -- "$DIST_DIR/.$APP_NAME-v$VERSION-$arch.new.$$.dmg"
}

backup_dmg_path() {
  local arch="$1"
  print -r -- "$DIST_DIR/.$APP_NAME-v$VERSION-$arch.backup.$$.dmg"
}

cleanup() {
  if [[ -n "$CURRENT_MOUNT" ]]; then
    hdiutil detach "$CURRENT_MOUNT" >/dev/null 2>&1 \
      || hdiutil detach "$CURRENT_MOUNT" -force >/dev/null 2>&1 \
      || true
    rm -rf "$CURRENT_MOUNT"
  fi

  local arch final_dmg new_dmg backup_dmg
  for arch in "${ARCHITECTURES[@]}"; do
    final_dmg="$(final_dmg_path "$arch")"
    new_dmg="$(new_dmg_path "$arch")"
    backup_dmg="$(backup_dmg_path "$arch")"

    if [[ "$RELEASE_SUCCEEDED" != "1" ]]; then
      if [[ -f "$PUBLISH_STATE_DIR/$arch.published" ]]; then
        rm -f "$final_dmg"
      fi
      if [[ -f "$PUBLISH_STATE_DIR/$arch.backed-up" && -e "$backup_dmg" ]]; then
        mv -f "$backup_dmg" "$final_dmg" || echo "✗ 无法恢复原有 $arch DMG；备份保留在：$backup_dmg" >&2
      fi
      rm -f "$new_dmg"
    else
      rm -f "$new_dmg" "$backup_dmg"
    fi
  done

  if (( LOCK_ACQUIRED == 1 )); then
    rm -rf "$RELEASE_LOCK_DIR"
  fi
  rm -rf "$RELEASE_WORK"
}
trap cleanup EXIT

bold() { print -P "%B$1%b"; }

release_source_fingerprint() {
  local file
  (
    cd "$ROOT_DIR"
    while IFS= read -r file; do
      case "$file" in
        .claude/*|dist/*|build/*|build-*/*|.DS_Store) continue ;;
      esac
      if [[ ! -e "$file" && ! -L "$file" ]]; then
        echo "✗ 发布源码文件在指纹计算期间消失：$file" >&2
        return 1
      fi
      /usr/bin/printf '%s\0' "$file"
      if [[ -L "$file" ]]; then
        /usr/bin/printf 'symlink:%s\0' "$(/usr/bin/readlink "$file")"
      else
        /usr/bin/shasum -a 256 "$file"
      fi
    done < <(
      {
        /usr/bin/git ls-files
        /usr/bin/git ls-files --others --exclude-standard
      } | LC_ALL=C /usr/bin/sort -u
    )
  ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

assert_release_source_unchanged() {
  local phase="$1"
  local current_fingerprint
  current_fingerprint="$(release_source_fingerprint)" || {
    echo "✗ 无法在 $phase 复核发布源码指纹。" >&2
    return 1
  }
  if [[ "$current_fingerprint" != "$SOURCE_FINGERPRINT" ]]; then
    echo "✗ $phase 检测到仓库源码发生变化，拒绝混合不同源码生成双架构发布包。" >&2
    return 1
  fi
}

assert_thin_app() {
  local app_path="$1"
  local expected_arch="$2"
  local label="$3"
  local binary_path="$app_path/Contents/MacOS/$EXECUTABLE_NAME"
  local actual_archs

  if [[ ! -f "$binary_path" ]]; then
    echo "✗ $label 缺少可执行文件：$binary_path" >&2
    return 1
  fi
  actual_archs="$(/usr/bin/lipo -archs "$binary_path" 2>/dev/null)" || {
    echo "✗ 无法读取 $label 的可执行文件架构。" >&2
    return 1
  }
  if [[ "$actual_archs" != "$expected_arch" ]]; then
    echo "✗ $label 必须是 $expected_arch thin binary，实际架构：$actual_archs" >&2
    return 1
  fi
}

validate_app_identity() {
  local app_path="$1"
  local label="$2"
  local plist="$app_path/Contents/Info.plist"
  local actual_version actual_build signature_info

  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
  if [[ "$actual_version" != "$VERSION" || "$actual_build" != "$BUILD_NUMBER" ]]; then
    echo "✗ $label 版本错误：实际 $actual_version ($actual_build)，要求 $VERSION ($BUILD_NUMBER)。" >&2
    return 1
  fi

  codesign --verify --deep --strict --verbose=2 "$app_path"
  signature_info="$(codesign -dvvv "$app_path" 2>&1)"
  if ! grep -Fqx "Identifier=$BUNDLE_ID" <<< "$signature_info"; then
    echo "✗ $label Bundle 签名标识错误。" >&2
    return 1
  fi
  if ! grep -Fqx "TeamIdentifier=$TEAM_ID" <<< "$signature_info"; then
    echo "✗ $label 签名团队错误。" >&2
    return 1
  fi
  if ! grep -Fq "Authority=Developer ID Application:" <<< "$signature_info"; then
    echo "✗ $label 未使用 Developer ID Application 签名。" >&2
    return 1
  fi
  if ! grep -q "flags=.*runtime" <<< "$signature_info"; then
    echo "✗ $label 未启用 hardened runtime。" >&2
    return 1
  fi
}

validate_notarized_app() {
  local app_path="$1"
  local expected_arch="$2"
  local label="$3"

  if [[ ! -d "$app_path" || -L "$app_path" ]]; then
    echo "✗ 缺少有效的 $label：$app_path" >&2
    return 1
  fi
  validate_app_identity "$app_path" "$label"
  assert_thin_app "$app_path" "$expected_arch" "$label"
  xcrun stapler validate "$app_path"
  spctl -a -t exec -vvv "$app_path"
}

notarize() {
  local target="$1"
  local output submission_id

  if ! output="$(xcrun notarytool submit "$target" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1)"; then
    echo "✗ 公证提交失败：${target:t}" >&2
    return 1
  fi

  submission_id="$(grep -m1 -E '^[[:space:]]*id:' <<< "$output" | awk '{print $2}' || true)"
  if ! grep -q "status: Accepted" <<< "$output"; then
    echo "✗ 公证未通过：${target:t}" >&2
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    return 1
  fi
  echo "  ✓ 公证通过：${target:t}"
}

bold "▶ 无凭据预检自动更新资产与架构逻辑…"
"$ROOT_DIR/test_asset_selection.sh"
echo "  ✓ 无凭据预检通过"

bold "▶ 预检签名证书与公证 profile…"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ 找不到可用的公证 profile。请先按本机安全流程配置后重试。" >&2
  exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application.*\(A94225N8T5\)/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "✗ 找不到要求团队的 Developer ID Application 证书。" >&2
  exit 1
fi
echo "  ✓ 发布前置条件已满足"

mkdir -p "$DIST_DIR"
if ! mkdir "$RELEASE_LOCK_DIR" 2>/dev/null; then
  echo "✗ 已有同版本 Y-Clip 发布流程或上次异常退出留下的锁：$RELEASE_LOCK_DIR" >&2
  echo "  请先确认没有 release.sh 正在运行，并检查 dist 中的 .backup/.new 文件后再移除该锁。" >&2
  exit 1
fi
LOCK_ACQUIRED=1
SOURCE_FINGERPRINT="$(release_source_fingerprint)" || {
  echo "✗ 无法记录发布源码指纹。" >&2
  exit 1
}
echo "  ✓ 已锁定本轮发布源码指纹"

for arch in "${ARCHITECTURES[@]}"; do
  assert_release_source_unchanged "$arch 架构构建前"
  ARCH_WORK="$RELEASE_WORK/$arch"
  ARCH_BUILD_DIR="$ARCH_WORK/build"
  ARCH_STAGE_DIR="$ARCH_WORK/stage"
  BUILT_APP="$ARCH_BUILD_DIR/$APP_NAME.app"
  STAGED_APP="$ARCH_STAGE_DIR/$APP_NAME.app"
  STAGED_DMG="$ARCH_WORK/$APP_NAME-v$VERSION-$arch.dmg"
  APP_ZIP="$ARCH_WORK/$APP_NAME-v$VERSION-$arch.zip"
  VERIFY_MOUNT="$ARCH_WORK/mount"

  mkdir -p "$ARCH_BUILD_DIR" "$ARCH_STAGE_DIR"

  bold "▶ [$arch] 独立构建并签名 App…"
  TARGET_ARCH="$arch" \
    BUILD_DIR="$ARCH_BUILD_DIR" \
    APP_PATH="$BUILT_APP" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    RELEASE=1 \
    "$ROOT_DIR/build.sh"

  validate_app_identity "$BUILT_APP" "$arch 构建 App"
  assert_thin_app "$BUILT_APP" "$arch" "$arch 构建 App"

  rm -rf "$STAGED_APP"
  ditto --noextattr --noqtn "$BUILT_APP" "$STAGED_APP"
  xattr -cr "$STAGED_APP"
  validate_app_identity "$STAGED_APP" "$arch staging App"
  assert_thin_app "$STAGED_APP" "$arch" "$arch staging App"
  echo "  ✓ App 签名后 thin 架构验证通过"

  bold "▶ [$arch] 公证并 staple App…"
  ditto -c -k --keepParent "$STAGED_APP" "$APP_ZIP"
  notarize "$APP_ZIP"
  rm -f "$APP_ZIP"
  xcrun stapler staple "$STAGED_APP"
  validate_notarized_app "$STAGED_APP" "$arch" "$arch staging App"

  bold "▶ [$arch] 生成独立 DMG…"
  APP_NAME_OVERRIDE="$APP_NAME" \
    APP_PATH_OVERRIDE="$STAGED_APP" \
    VOLUME_NAME_OVERRIDE="$APP_NAME-$arch" \
    DMG_OUTPUT_PATH_OVERRIDE="$STAGED_DMG" \
    "$ROOT_DIR/make_dmg.sh"

  bold "▶ [$arch] 签名、公证并 staple DMG…"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$STAGED_DMG"
  codesign --verify --verbose=4 "$STAGED_DMG"
  notarize "$STAGED_DMG"
  xcrun stapler staple "$STAGED_DMG"
  codesign --verify --verbose=4 "$STAGED_DMG"
  xcrun stapler validate "$STAGED_DMG"
  spctl -a -vvv -t open --context context:primary-signature "$STAGED_DMG"
  hdiutil verify "$STAGED_DMG" >/dev/null

  bold "▶ [$arch] 挂载并验证 DMG 内两个 App…"
  rm -rf "$VERIFY_MOUNT"
  mkdir -p "$VERIFY_MOUNT"
  CURRENT_MOUNT="$VERIFY_MOUNT"
  hdiutil attach "$STAGED_DMG" \
    -mountpoint "$VERIFY_MOUNT" \
    -nobrowse \
    -noautoopen \
    -readonly >/dev/null

  validate_notarized_app "$VERIFY_MOUNT/$APP_NAME.app" "$arch" "$arch DMG 可见 App"
  validate_notarized_app "$VERIFY_MOUNT/Global Clipboard.app" "$arch" "$arch DMG 隐藏兼容 App"
  if [[ "$(stat -f '%Sf' "$VERIFY_MOUNT/Global Clipboard.app")" != *hidden* ]]; then
    echo "✗ $arch DMG 隐藏兼容 App 未保留 BSD hidden 标志。" >&2
    exit 1
  fi

  hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 \
    || hdiutil detach "$VERIFY_MOUNT" -force >/dev/null 2>&1
  rm -rf "$VERIFY_MOUNT"
  CURRENT_MOUNT=""
  echo "  ✓ $arch DMG 挂载后 thin 架构、签名、公证票据与 Gatekeeper 验证通过"
  assert_release_source_unchanged "$arch 架构完整产物生成后"
done

assert_release_source_unchanged "双架构最终文件准备前"
bold "▶ 准备两个最终文件，旧 dist 成套保留到新文件全部验证完成…"
for arch in "${ARCHITECTURES[@]}"; do
  STAGED_DMG="$RELEASE_WORK/$arch/$APP_NAME-v$VERSION-$arch.dmg"
  NEW_DMG="$(new_dmg_path "$arch")"

  rm -f "$NEW_DMG"
  ditto "$STAGED_DMG" "$NEW_DMG"
  codesign --verify --verbose=4 "$NEW_DMG"
  xcrun stapler validate "$NEW_DMG"
  spctl -a -vvv -t open --context context:primary-signature "$NEW_DMG"
  hdiutil verify "$NEW_DMG" >/dev/null
  echo "  ✓ 已准备：$NEW_DMG"
done

bold "▶ 成套切换两个最终发布文件…"
for arch in "${ARCHITECTURES[@]}"; do
  FINAL_DMG="$(final_dmg_path "$arch")"
  BACKUP_DMG="$(backup_dmg_path "$arch")"
  rm -f "$BACKUP_DMG"
  if [[ -e "$FINAL_DMG" || -L "$FINAL_DMG" ]]; then
    touch "$PUBLISH_STATE_DIR/$arch.backed-up"
    mv "$FINAL_DMG" "$BACKUP_DMG"
  fi
done

for arch in "${ARCHITECTURES[@]}"; do
  FINAL_DMG="$(final_dmg_path "$arch")"
  NEW_DMG="$(new_dmg_path "$arch")"
  touch "$PUBLISH_STATE_DIR/$arch.published"
  mv "$NEW_DMG" "$FINAL_DMG"
done

for arch in "${ARCHITECTURES[@]}"; do
  FINAL_DMG="$(final_dmg_path "$arch")"
  codesign --verify --verbose=4 "$FINAL_DMG"
  xcrun stapler validate "$FINAL_DMG"
  spctl -a -vvv -t open --context context:primary-signature "$FINAL_DMG"
  hdiutil verify "$FINAL_DMG" >/dev/null
  echo "  ✓ $FINAL_DMG"
done

RELEASE_SUCCEEDED=1
bold "✅ 双架构发布产物已完成"
echo "可分发文件："
echo "  $(final_dmg_path arm64)"
echo "  $(final_dmg_path x86_64)"
echo "上传要求：只上传这两个 thin DMG，arm64 必须先于 x86_64；发布后确认 latest API 的首个 .dmg 为 arm64。"
