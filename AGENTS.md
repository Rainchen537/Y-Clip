# Y-Clip Agent 规范

本项目遵守父目录 `../AGENTS.md` 和 `../Y_PROJECT_APP_STANDARD.me`。开始任务前必须阅读本文件、`AI_CONTEXT.me`、`CHANGELOG.me` 和 `README.md`。

## 项目身份

- GitHub：`https://github.com/Rainchen537/Y-Clip`
- 默认分支：`main`
- Bundle ID：`com.lixingchen.GlobalClipboard`
- 可执行文件：`GlobalClipboard`
- 安装路径：`/Applications/Y-Clip.app`
- 版本位置：`Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`
- 正式 DMG：`dist/Y-Clip.dmg`；上传 Release 时使用版本化名称 `Y-Clip-vX.Y.Z.dmg`

内部名称和旧数据兼容路径不得因对外名称 Y-Clip 而修改。

## 每次任务的发布闭环

1. 运行 `./build.sh` 并完成相关功能验证。
2. 更新版本、构建号、README 和两个 changelog。
3. 运行 `./release.sh`，确认 App/DMG 已签名、公证、staple 且 Gatekeeper 验证通过。
4. 提交源码，创建并推送 `vX.Y.Z` tag，在 `Rainchen537/Y-Clip` 创建 Release 并上传版本化 DMG。
5. 退出 `GlobalClipboard`，从最终 DMG 覆盖安装 `/Applications/Y-Clip.app`，验证签名和版本后启动。
6. 验证菜单栏、`Option + Command + V`、文字/图片历史、自动粘贴、设置页、辅助功能权限及更新入口。

不得删除 DMG 内隐藏的 `Global Clipboard.app` 兼容副本。
