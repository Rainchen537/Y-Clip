# Y-Clip Agent 规范

本项目遵守父目录 `../AGENTS.md` 和 `../Y_PROJECT_APP_STANDARD.me`。开始任务前阅读本文件、`AI_CONTEXT.me`、`CHANGELOG.me` 和 `README.md`。

## 项目身份

- GitHub：`https://github.com/Rainchen537/Y-Clip`
- 默认分支：`main`
- Bundle ID：`com.lixingchen.GlobalClipboard`
- 可执行文件：`GlobalClipboard`
- 安装路径：`/Applications/Y-Clip.app`
- 版本位置：`Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`
- 正式 DMG：`dist/Y-Clip-vX.Y.Z-arm64.dmg` 与 `dist/Y-Clip-vX.Y.Z-x86_64.dmg`；自动更新按编译架构精确匹配完整资产名
- 当前版本：`1.0.18 (19)`；正式 Release 同时提供两个架构的独立 thin DMG

内部名称、Bundle ID、旧数据路径和 DMG 内隐藏的 `Global Clipboard.app` 兼容副本不得因对外名称 Y-Clip 而修改。

## 构建、验证与发布

- 只在 Y-Clip 实际被修改时处理本项目；其他 App 或未同步进本仓库的共享框架变化不触发 Y-Clip 构建和发布。
- 本地构建使用 `./build.sh`，默认 `TARGET_ARCH=arm64`；只允许 `arm64` 或 `x86_64`，并必须验证产物为对应 thin binary。需要隔离时覆盖 `BUILD_DIR` 或 `APP_PATH`。
- 需要正式分发时递增版本和构建号，更新 README 与 changelog，并以 `./release.sh` 从独立 build/stage 一次生成、签名、公证、staple 和验证两个架构的全新 DMG；不得复用旧产物。
- 首次双资产迁移 `v1.0.18` 只发布 arm64 与 x86_64 两个 thin DMG，不新增 universal 包；GitHub 必须先上传 arm64、再上传 x86_64，并在发布后确认 latest API 的首个 `.dmg` 为 arm64，以兼容 `v1.0.17` 旧更新器。
- 正式发布产物必须完成 Developer ID 签名、公证、staple 和 Gatekeeper 验证；从最终 DMG 覆盖安装后，仅对本次改动和必要核心入口做冒烟检查。
