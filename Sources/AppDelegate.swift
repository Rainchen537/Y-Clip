import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let historyStore = ClipboardHistoryStore()
    private let settingsStore = SettingsStore()
    private let panelController = ClipboardPanelController()
    private var hotKeyController: HotKeyController?
    private var settingsPopoverController: SettingsPopoverController?
    private var statusItem: NSStatusItem?
    private var focusContext: FocusContext?
    private var hasShownAccessibilityWarning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        historyStore.startMonitoring()
        setupSettingsPopover()
        registerHotKey(settingsStore.hotKey)

        // 让面板能根据图片项找到磁盘上的全图，用于生成缩略图。
        panelController.imageURLProvider = { [weak self] payload in
            self?.historyStore.imageURL(for: payload) ?? URL(fileURLWithPath: "/dev/null")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController = nil
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "clipboard",
            accessibilityDescription: "剪贴板历史"
        )
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggleSettingsPopover)

        statusItem = item
    }

    private func setupSettingsPopover() {
        settingsPopoverController = SettingsPopoverController(
            hotKey: settingsStore.hotKey,
            menuSize: settingsStore.menuSize,
            launchAtLoginEnabled: LaunchAtLoginController.isEnabled,
            onShowHistory: { [weak self] in
                self?.settingsPopoverController?.close()
                self?.showClipboardHistory()
            },
            onClearHistory: { [weak self] in
                self?.historyStore.clear()
            },
            onLaunchAtLoginChange: { [weak self] enabled in
                self?.setLaunchAtLogin(enabled)
            },
            onHotKeyChange: { [weak self] hotKey in
                self?.setHotKey(hotKey)
            },
            onMenuSizeChange: { [weak self] size in
                self?.settingsStore.menuSize = size
            },
            onOpenAccessibility: {
                AccessibilityPermission.openSettings()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
    }

    @objc private func toggleSettingsPopover() {
        guard let button = statusItem?.button, let settingsPopoverController else {
            return
        }

        if settingsPopoverController.isShown {
            settingsPopoverController.close()
        } else {
            settingsPopoverController.show(relativeTo: button)
        }
    }

    private func registerHotKey(_ hotKey: HotKey) {
        do {
            let hotKeyController = hotKeyController ?? HotKeyController { [weak self] in
                self?.showClipboardHistory()
            }
            try hotKeyController.register(hotKey: hotKey)
            self.hotKeyController = hotKeyController
        } catch {
            showAlert(
                title: "快捷键注册失败",
                message: error.localizedDescription
            )
        }
    }

    private func setHotKey(_ hotKey: HotKey) {
        let previousHotKey = settingsStore.hotKey

        do {
            let hotKeyController = hotKeyController ?? HotKeyController { [weak self] in
                self?.showClipboardHistory()
            }
            try hotKeyController.register(hotKey: hotKey)
            self.hotKeyController = hotKeyController
            settingsStore.hotKey = hotKey
            settingsPopoverController?.updateHotKey(hotKey)
        } catch {
            registerHotKey(previousHotKey)
            settingsPopoverController?.updateHotKey(previousHotKey)
            showAlert(
                title: "快捷键不可用",
                message: error.localizedDescription
            )
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
            settingsPopoverController?.updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
        } catch {
            settingsPopoverController?.updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
            showAlert(
                title: "开机自启动设置失败",
                message: error.localizedDescription
            )
        }
    }

    private func showClipboardHistory() {
        focusContext = FocusContextReader.current()
        let anchorPoint = usableAnchorPoint(focusContext?.caretPoint)

        panelController.show(
            items: historyStore.items,
            menuSize: settingsStore.menuSize,
            near: anchorPoint,
            onChoose: { [weak self] item in
                self?.paste(item)
            },
            onClose: { [weak self] in
                self?.restoreFocus()
            }
        )
    }

    private func paste(_ item: ClipboardItem) {
        historyStore.writeToPasteboard(item)

        guard AccessibilityPermission.isTrusted(prompt: false) else {
            restoreFocus()
            showAccessibilityWarningIfNeeded()
            return
        }

        restoreFocus()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            PasteController.sendCommandV()
        }
    }

    private func restoreFocus() {
        FocusContextReader.restore(focusContext)
    }

    private func usableAnchorPoint(_ point: NSPoint?) -> NSPoint {
        guard let point else {
            return NSEvent.mouseLocation
        }

        let isOnScreen = NSScreen.screens.contains { screen in
            NSMouseInRect(point, screen.frame, false)
        }

        return isOnScreen ? point : NSEvent.mouseLocation
    }

    private func showAccessibilityWarningIfNeeded() {
        guard !hasShownAccessibilityWarning else {
            return
        }

        hasShownAccessibilityWarning = true

        let alert = NSAlert()
        alert.messageText = "已复制到剪贴板"
        alert.informativeText = "当前系统仍未把这个版本的应用识别为已授权，所以暂时不会自动粘贴。如果你已经打开过开关，请重置一次辅助功能权限后重新添加 Global Clipboard。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityPermission.openSettings()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
