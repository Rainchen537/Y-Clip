#!/bin/zsh
set -euo pipefail

# 一键发布：Developer ID 签名构建 → 打包 DMG → 公证 → 装订 → 验证
# 产出可双击直接打开的 dist/Y-Clip.dmg
#
# 前置（只需做一次）：把公证凭据存入钥匙串 profile。
# 可先通过环境变量提供 profile 名、Apple ID、Team ID 和 App 专用密码，再执行：
#
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#     --apple-id "$NOTARY_APPLE_ID" \
#     --team-id "$NOTARY_TEAM_ID" \
#     --password "$NOTARY_PASSWORD"
#
# 后续发布只需提供 NOTARY_PROFILE（默认 GlobalClipboardNotary）并运行 ./release.sh。
# 不要把账号或密码字面量写入脚本。

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Y-Clip"
VOL_NAME="Y-Clip"
BUILD_APP_PATH="$ROOT_DIR/build/$APP_NAME.app"
RELEASE_WORK="$(mktemp -d /tmp/Y-Clip-release.XXXXXX)"
APP_PATH="$RELEASE_WORK/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/$VOL_NAME.dmg"

# 公证凭据 profile 名（可用环境变量覆盖）
NOTARY_PROFILE="${NOTARY_PROFILE:-GlobalClipboardNotary}"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
VERIFY_MOUNT=""

cleanup() {
  if [[ -n "$VERIFY_MOUNT" ]]; then
    hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || hdiutil detach "$VERIFY_MOUNT" -force >/dev/null 2>&1 || true
    rm -rf "$VERIFY_MOUNT"
  fi
  rm -rf "$RELEASE_WORK"
}
trap cleanup EXIT

bold() { print -P "%B$1%b"; }

# ---- 0) 预检：凭据 profile 和签名证书是否存在 ----
bold "▶ 0/7 检查公证凭据和签名证书…"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
✗ 找不到公证凭据 profile：$NOTARY_PROFILE

请先通过环境变量准备 NOTARY_APPLE_ID、NOTARY_TEAM_ID、NOTARY_PASSWORD，
然后把凭据写入该钥匙串 profile：

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
    --apple-id "\$NOTARY_APPLE_ID" \\
    --team-id "\$NOTARY_TEAM_ID" \\
    --password "\$NOTARY_PASSWORD"

存好后仅需保留 profile，并重新运行 ./release.sh。
EOF
  exit 1
fi
echo "  ✓ 凭据就绪：$NOTARY_PROFILE"

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/Developer ID Application.*\(A94225N8T5\)/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "✗ 找不到 Developer ID Application 证书。" >&2
  exit 1
fi
echo "  ✓ 签名证书就绪：$SIGN_IDENTITY"

# ---- 1) 用 Developer ID + hardened runtime 构建签名 ----
bold "▶ 1/7 构建并签名（Developer ID + hardened runtime）…"
CODE_SIGN_IDENTITY="$SIGN_IDENTITY" RELEASE=1 "$ROOT_DIR/build.sh"
rm -rf "$APP_PATH"
ditto --noextattr --noqtn "$BUILD_APP_PATH" "$APP_PATH"
xattr -cr "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# 验证签名确实是 Developer ID + runtime
# 先把签名信息捕获到变量再匹配，避免 `codesign | grep -q` 因 grep 提前关闭管道
# 触发 codesign 的 SIGPIPE，在 pipefail 下污染退出码导致误判。
SIG_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
if ! grep -q "Developer ID Application" <<< "$SIG_INFO"; then
  echo "✗ app 未用 Developer ID 签名，终止。" >&2
  exit 1
fi
if ! grep -q "flags=.*runtime" <<< "$SIG_INFO"; then
  echo "✗ app 未启用 hardened runtime，终止。" >&2
  exit 1
fi
if ! grep -q "TeamIdentifier=A94225N8T5" <<< "$SIG_INFO"; then
  echo "✗ app 签名团队不是 A94225N8T5，终止。" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "  ✓ 签名校验通过"

# 公证提交 + 等待 + 结果解析的公共函数。参数：$1=要公证的文件路径
notarize() {
  local target="$1"
  local log
  log="$(mktemp)"
  if ! xcrun notarytool submit "$target" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$log"; then
    echo "✗ 公证提交失败：$target" >&2
    rm -f "$log"
    return 1
  fi
  local sid
  sid="$(grep -m1 -E "^[[:space:]]*id:" "$log" | awk '{print $2}')"
  if ! grep -q "status: Accepted" "$log"; then
    echo "" >&2
    echo "✗ 公证未通过（status 非 Accepted）：$target，拉取日志：" >&2
    [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  return 0
}

# ---- 2) 公证 app 本体并装订（zip 仅用于上传，装订回 .app）----
bold "▶ 2/7 公证 app 本体…"
APP_ZIP="$(mktemp -d)/app.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
notarize "$APP_ZIP" || exit 1
rm -f "$APP_ZIP"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
echo "  ✓ app 已公证、装订并通过票据校验"

# ---- 3) 用已装订的 app 打包 DMG ----
bold "▶ 3/7 打包 DMG…"
APP_PATH_OVERRIDE="$APP_PATH" "$ROOT_DIR/make_dmg.sh"

# ---- 4) 签名 DMG ----
bold "▶ 4/7 签名 DMG…"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=4 "$DMG_PATH"
echo "  ✓ DMG 签名校验通过"

# ---- 5) 公证 DMG ----
bold "▶ 5/7 公证 DMG…"
notarize "$DMG_PATH" || exit 1
echo "  ✓ DMG 已公证"

# ---- 6) 装订 DMG 票据（离线也能验证）----
bold "▶ 6/7 装订 DMG 票据…"
xcrun stapler staple "$DMG_PATH"
echo "  ✓ 已装订"

# ---- 7) 最终验证：挂载并以用户真实场景检验 app ----
bold "▶ 7/7 验证最终产物…"
echo "  · DMG 签名、装订和 Gatekeeper 校验："
codesign --verify --verbose=4 "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"

validate_final_app() {
  local app_path="$1"
  local label="$2"
  if [[ ! -d "$app_path" || -L "$app_path" ]]; then
    echo "✗ 最终 DMG 中缺少有效的 $label：$app_path" >&2
    return 1
  fi
  echo "  · $label 的签名、装订和 Gatekeeper 校验："
  codesign --verify --deep --strict --verbose=2 "$app_path"
  xcrun stapler validate "$app_path"
  spctl -a -t exec -vvv "$app_path"
}

VERIFY_MOUNT="$(mktemp -d /tmp/Y-Clip-verify.XXXXXX)"
hdiutil attach "$DMG_PATH" -mountpoint "$VERIFY_MOUNT" -nobrowse -noautoopen -readonly >/dev/null
validate_final_app "$VERIFY_MOUNT/$APP_NAME.app" "$APP_NAME.app"
validate_final_app "$VERIFY_MOUNT/Global Clipboard.app" "隐藏兼容副本 Global Clipboard.app"
hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || hdiutil detach "$VERIFY_MOUNT" -force >/dev/null 2>&1
rm -rf "$VERIFY_MOUNT"
VERIFY_MOUNT=""

echo ""
bold "✅ 发布完成！"
echo "可分发文件：$DMG_PATH"
echo "别人下载后双击即可打开，无安全拦截。"
ls -lh "$DMG_PATH"
