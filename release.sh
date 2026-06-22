#!/bin/zsh
set -euo pipefail

# 一键发布：Developer ID 签名构建 → 打包 DMG → 公证 → 装订 → 验证
# 产出可双击直接打开的 dist/Y-Clip.dmg
#
# 前置（只需做一次）：把公证凭据存入钥匙串，存成一个 profile：
#
#   xcrun notarytool store-credentials "GlobalClipboardNotary" \
#     --apple-id "lixingchen0411@163.com" \
#     --team-id "A94225N8T5" \
#     --password "你的-App-专用密码"
#
# 之后每次发布只需：./release.sh
# 密码不会出现在本脚本或命令历史里。

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Y-Clip"
VOL_NAME="Y-Clip"
APP_PATH="$ROOT_DIR/build/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/$VOL_NAME.dmg"

# 公证凭据 profile 名（可用环境变量覆盖）
NOTARY_PROFILE="${NOTARY_PROFILE:-GlobalClipboardNotary}"

bold() { print -P "%B$1%b"; }

# ---- 0) 预检：凭据 profile 是否存在 ----
bold "▶ 0/6 检查公证凭据…"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
✗ 找不到公证凭据 profile：$NOTARY_PROFILE

请先执行一次（把密码替换成你的 App 专用密码）：

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
    --apple-id "lixingchen0411@163.com" \\
    --team-id "A94225N8T5" \\
    --password "xxxx-xxxx-xxxx-xxxx"

存好后重新运行 ./release.sh
EOF
  exit 1
fi
echo "  ✓ 凭据就绪：$NOTARY_PROFILE"

# ---- 1) 用 Developer ID + hardened runtime 构建签名 ----
bold "▶ 1/6 构建并签名（Developer ID + hardened runtime）…"
RELEASE=1 "$ROOT_DIR/build.sh"

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
bold "▶ 2/6 公证 app 本体…"
APP_ZIP="$(mktemp -d)/app.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
notarize "$APP_ZIP" || exit 1
rm -f "$APP_ZIP"
xcrun stapler staple "$APP_PATH"
echo "  ✓ app 已公证并装订票据"

# ---- 3) 用已装订的 app 打包 DMG ----
bold "▶ 3/6 打包 DMG…"
"$ROOT_DIR/make_dmg.sh"

# ---- 4) 公证 DMG ----
bold "▶ 4/6 公证 DMG…"
notarize "$DMG_PATH" || exit 1
echo "  ✓ DMG 已公证"

# ---- 5) 装订 DMG 票据（离线也能验证）----
bold "▶ 5/6 装订 DMG 票据…"
xcrun stapler staple "$DMG_PATH"
echo "  ✓ 已装订"

# ---- 6) 最终验证：挂载并以用户真实场景检验 app ----
bold "▶ 6/6 验证最终产物…"
echo "  · DMG 装订校验："
xcrun stapler validate "$DMG_PATH"

MOUNT="/Volumes/$VOL_NAME"
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
hdiutil attach "$DMG_PATH" -nobrowse -noautoopen >/dev/null
echo "  · 挂载后 app 的 Gatekeeper 判定（应为 accepted / Notarized Developer ID）："
spctl -a -t exec -vvv "$MOUNT/$APP_NAME.app" 2>&1 || true
hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true

echo ""
bold "✅ 发布完成！"
echo "可分发文件：$DMG_PATH"
echo "别人下载后双击即可打开，无安全拦截。"
ls -lh "$DMG_PATH"
