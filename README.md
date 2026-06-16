<div align="center">

<img src="docs/icon-256.png" width="128" alt="全局剪切板 图标" />

# 全局剪切板 · Global Clipboard

**把 Windows `Win + V` 的剪贴板历史体验，原生搬到 macOS。**

一个轻量、常驻菜单栏的剪贴板历史工具 —— 在任意输入光标旁按下快捷键，即可翻看、选择并自动粘贴最近复制过的文字与图片。

[![平台](https://img.shields.io/badge/macOS-13.0+-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![语言](https://img.shields.io/badge/Swift-5-orange?logo=swift&logoColor=white)](https://www.swift.org/)
[![签名](https://img.shields.io/badge/已签名-Developer%20ID%20%2B%20公证-success)](#-安装)
[![下载](https://img.shields.io/badge/下载-DMG-blue)](../../releases/latest)

<img src="docs/hero.png" width="420" alt="历史面板预览" />

</div>

---

## ✨ 功能

- 📋 **自动记录** 最近复制过的剪贴板内容，默认保留 50 条，数量可在设置里调整
- 🖼️ **文字 + 图片** 都能记录，图片以统一大小的缩略图展示，列表整齐不跳动
- ⌨️ **随手呼出**：默认 `⌥ + ⌘ + V`，在输入光标附近弹出，靠近屏幕边缘自动避让
- 🎯 **多种选择方式**：鼠标点击、`↑↓` 方向键、`Enter` 粘贴、`Esc` 关闭
- ⚡ **选中即置顶**：选用某条历史后，它会自动成为当前剪贴板内容并排到最前
- 📐 **显示可调**：设置里用滑杆调整历史面板大小、宽度和长度，左侧预览会实时反馈效果
- 🔢 **历史上限可调**：可设置最多记录多少条历史，默认 50 条
- 🔄 **自动更新**：可自动检查 GitHub Release，新版本可直接下载并安装
- 🪶 **不抢焦点**：弹窗不会激活应用，尽量保留你原本的输入框焦点
- 🍎 **原生体验**：菜单栏常驻图标，深色 / 浅色模式自适应，无 Dock 图标打扰

## 📦 安装

### 方式一：下载安装包（推荐）

1. 前往 [**Releases**](../../releases/latest) 下载最新的 `全局剪切板.dmg`
2. 双击打开，把 **Global Clipboard** 拖进 **应用程序** 文件夹
3. 从启动台或应用程序文件夹打开即可

> ✅ 本应用已使用 Apple **Developer ID 签名并公证（notarized）**，下载后双击即可打开，**不会出现「无法验证开发者」或「已损坏」的拦截**。

### 方式二：从源码构建

需要安装 Xcode 命令行工具。

```zsh
git clone https://github.com/Rainchen537/global-clipboard.git
cd global-clipboard
./build.sh                 # 构建到 build/Global Clipboard.app
./install_app.sh           # 安装到 /Applications
```

## 🔐 权限说明

首次选择历史记录自动粘贴时，macOS 会要求开启 **「辅助功能」** 权限 —— 这是模拟 `⌘ + V` 粘贴所必需的，所有同类工具都一样。

> 系统设置 → 隐私与安全性 → 辅助功能 → 勾选 **Global Clipboard**

- 如果没有自动弹出，可从菜单栏图标的设置里点 **「辅助功能」** 按钮打开。
- 没有授予权限时，应用仍会把选中内容复制回系统剪贴板，只是不会替你自动粘贴（需要你手动 `⌘V`）。
- 若系统设置里看起来已开启但仍不生效（常见于重新构建后签名变化），运行 `./reset_accessibility.sh` 重置后重新添加。

## ⌨️ 使用

| 操作 | 快捷键 |
|------|--------|
| 打开历史面板 | `⌥ + ⌘ + V`（可在设置里自定义） |
| 上 / 下选择 | `↑` / `↓` |
| 粘贴选中项 | `Enter` |
| 关闭面板 | `Esc` |
| 打开设置 | 点击菜单栏的剪贴板图标 |

历史面板右上角也有齿轮按钮，可直接打开设置，适合菜单栏图标被系统隐藏时使用。

在设置面板里可以：自定义快捷键、调节历史面板大小/宽度/长度、设置历史上限、开关开机自启、自动检查更新、显示 / 清空历史、打开辅助功能权限、打开 GitHub 页面。

## 🛠️ 技术

- 纯 **Swift + AppKit**，无第三方依赖
- 全局热键：Carbon `RegisterEventHotKey`
- 自动粘贴：`CGEvent` 键盘事件注入
- 开机自启：`SMAppService`
- 数据：文字与图片元数据存于 `~/Library/Application Support/GlobalClipboard/`，图片原图单独落盘并按内容去重

## 📄 许可

MIT License

---

<div align="center">
<sub>用 ❤️ 为 macOS 打造</sub>
</div>
