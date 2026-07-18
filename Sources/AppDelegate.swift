import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private lazy var historyStore = ClipboardHistoryStore(maxItems: settingsStore.maxHistoryItems)
    private let softwareUpdateController = SoftwareUpdateController()
    private let panelController = ClipboardPanelController()
    private var hotKeyController: HotKeyController?
    private var settingsWindowController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var focusContext: FocusContext?
    private var hasShownAccessibilityWarning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        historyStore.startMonitoring()
        setupSettingsWindow()
        softwareUpdateController.onStatusChange = { [weak self] status in
            self?.settingsWindowController?.updateUpdateStatus(status)
        }
        registerHotKey(settingsStore.hotKey)
        scheduleAutomaticUpdateCheckIfNeeded()
        rememberAccessibilityTrustIfNeeded()
        continuePendingAccessibilityRepairIfNeeded()

        // 让面板能根据图片项找到磁盘上的全图，用于生成缩略图。
        panelController.imageURLProvider = { [weak self] payload in
            self?.historyStore.imageURL(for: payload) ?? URL(fileURLWithPath: "/dev/null")
        }
        panelController.onOpenSettings = { [weak self] sourceView in
            guard let self else {
                return
            }

            _ = sourceView
            panelController.close()
            openSettings()
        }

        showSettingsForPreviewIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController = nil
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusBarIcon.makeImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Y-Clip"
        item.menu = YProjectStatusMenu.make(
            target: self,
            openSettingsAction: #selector(openSettings),
            quitAction: #selector(quit),
            appName: "Y-Clip"
        )

        statusItem = item
    }

    private func setupSettingsWindow() {
        settingsWindowController = SettingsWindowController(
            hotKey: settingsStore.hotKey,
            panelMetrics: settingsStore.panelMetrics,
            maxHistoryItems: settingsStore.maxHistoryItems,
            autoUpdateEnabled: settingsStore.autoUpdateEnabled,
            launchAtLoginEnabled: LaunchAtLoginController.isEnabled,
            onClearHistory: { [weak self] in
                self?.historyStore.clear()
            },
            onLaunchAtLoginChange: { [weak self] enabled in
                self?.setLaunchAtLogin(enabled)
            },
            onHotKeyChange: { [weak self] hotKey in
                self?.setHotKey(hotKey)
            },
            onPanelMetricsChange: { [weak self] metrics in
                self?.settingsStore.panelMetrics = metrics
            },
            onMaxHistoryItemsChange: { [weak self] count in
                self?.setMaxHistoryItems(count)
            },
            onAutoUpdateChange: { [weak self] enabled in
                self?.settingsStore.autoUpdateEnabled = enabled
            },
            onCheckForUpdates: { [weak self] in
                self?.softwareUpdateController.checkForUpdates()
            },
            onInstallUpdate: { [weak self] in
                self?.softwareUpdateController.installAvailableUpdate()
            },
            onOpenAccessibility: { [weak self] in
                self?.showAccessibilityRepairOptions()
            },
            onResetAccessibility: { [weak self] completion in
                guard let self else {
                    completion(.failed("设置控制器已释放，请重新打开设置后再试。"))
                    return
                }
                self.refreshAccessibilityAuthorization(completion: completion)
            },
            onOpenGitHub: {
                if let url = URL(string: "https://github.com/Rainchen537/Y-Clip") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    @objc private func openSettings() {
        settingsWindowController?.show()
    }

    private func showSettingsForPreviewIfRequested() {
        guard ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW"] == "1" else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.openSettings()
            if let identifier = ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW_SECTION"] {
                self?.settingsWindowController?.selectItem(identifier)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
            settingsWindowController?.updateHotKey(hotKey)
        } catch {
            registerHotKey(previousHotKey)
            settingsWindowController?.updateHotKey(previousHotKey)
            showAlert(
                title: "快捷键不可用",
                message: error.localizedDescription
            )
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
            settingsWindowController?.updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
        } catch {
            settingsWindowController?.updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
            showAlert(
                title: "开机自启动设置失败",
                message: error.localizedDescription
            )
        }
    }

    private func setMaxHistoryItems(_ count: Int) {
        let clamped = SettingsStore.clampedHistoryLimit(count)
        settingsStore.maxHistoryItems = clamped
        historyStore.maxItems = clamped
        settingsWindowController?.updateMaxHistoryItems(clamped)
    }

    private func scheduleAutomaticUpdateCheckIfNeeded() {
        guard settingsStore.autoUpdateEnabled else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.softwareUpdateController.checkForUpdates()
        }
    }

    private func showClipboardHistory() {
        focusContext = FocusContextReader.current()
        let anchorPoint = usableAnchorPoint(focusContext?.caretPoint)

        panelController.show(
            items: historyStore.items,
            metrics: settingsStore.panelMetrics,
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

        guard isAccessibilityTrusted() else {
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

    private func isAccessibilityTrusted() -> Bool {
        let trusted = AccessibilityPermission.isTrusted(prompt: false)
        if trusted {
            settingsStore.accessibilityWasTrusted = true
        }

        return trusted
    }

    private func rememberAccessibilityTrustIfNeeded() {
        if AccessibilityPermission.isTrusted(prompt: false) {
            settingsStore.accessibilityWasTrusted = true
        }
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
        showAccessibilityRepairOptions()
    }

    private func showAccessibilityRepairOptions() {
        if AccessibilityPermission.isTrusted(prompt: false) {
            settingsStore.accessibilityWasTrusted = true
            AccessibilityPermission.openSettings()
            return
        }

        let alert = NSAlert()
        let wasTrustedBefore = settingsStore.accessibilityWasTrusted

        if wasTrustedBefore {
            alert.messageText = "辅助功能权限需要刷新"
            alert.informativeText = "macOS 在应用更新后有时会保留旧的辅助功能记录，导致系统设置里看起来已开启，但当前版本实际无法发送粘贴快捷键。可以先刷新这条记录，再重新勾选 Y-Clip。"
            alert.addButton(withTitle: "刷新权限记录")
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
        } else {
            alert.messageText = "已复制到剪贴板"
            alert.informativeText = "当前还没有授予辅助功能权限，所以暂时不会自动粘贴。若系统设置里看起来已经开启但仍不生效，可以先刷新权限记录。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "刷新权限记录")
            alert.addButton(withTitle: "稍后")
        }

        alert.alertStyle = .informational

        let response = alert.runModal()
        if wasTrustedBefore, response == .alertFirstButtonReturn {
            refreshAccessibilityAuthorization()
        } else if response == (wasTrustedBefore ? .alertSecondButtonReturn : .alertFirstButtonReturn) {
            AccessibilityPermission.requestPrompt()
            AccessibilityPermission.openSettings()
        } else if !wasTrustedBefore, response == .alertSecondButtonReturn {
            refreshAccessibilityAuthorization()
        }
    }

    private func refreshAccessibilityAuthorization(completion: ((AccessibilityRepairResult) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try AccessibilityPermission.resetAuthorization()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.settingsStore.accessibilityWasTrusted = false
                    self.finishAccessibilityRepair(completion: completion)
                }
            } catch {
                DispatchQueue.main.async {
                    if let completion {
                        completion(.failed(error.localizedDescription))
                    } else {
                        self?.showAlert(
                            title: "刷新辅助功能权限失败",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private func finishAccessibilityRepair(completion: ((AccessibilityRepairResult) -> Void)?) {
        let isInstalledCopy = YSettingRuntimeIdentity.isSignedInstalledCopy(
            expectedPath: YClipApplicationIdentity.installedApplicationPath,
            expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier,
            expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier
        )
        if isInstalledCopy {
            completion?(.authorizationRequested)
            AccessibilityPermission.requestPrompt()
            AccessibilityPermission.openSettings()
            return
        }

        let hasInstalledCopy = YSettingRuntimeIdentity.isValidSignedApplication(
            atPath: YClipApplicationIdentity.installedApplicationPath,
            expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
            expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
        )
        guard hasInstalledCopy else {
            if let completion {
                completion(.installedCopyRequired)
            } else {
                showAlert(
                    title: "请先安装正式版 Y-Clip",
                    message: "权限记录已定向刷新，但当前运行的是开发副本，且没有找到有效的 /Applications/Y-Clip.app。为避免把辅助功能权限重新绑定到开发副本，本次不会请求授权。请先安装正式版，再从应用程序文件夹启动并授权。"
                )
            }
            return
        }

        settingsStore.accessibilityRepairPending = true
        completion?(.switchingToInstalledCopy)
        do {
            try YSettingRuntimeIdentity.relaunchInstalledApplication(
                atPath: YClipApplicationIdentity.installedApplicationPath,
                expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
                expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
            )
        } catch {
            settingsStore.accessibilityRepairPending = false
            if let completion {
                completion(.failed(error.localizedDescription))
            } else {
                showAlert(title: "无法切换到正式安装版", message: error.localizedDescription)
            }
        }
    }

    private func continuePendingAccessibilityRepairIfNeeded() {
        guard settingsStore.accessibilityRepairPending else {
            return
        }

        let isInstalledCopy = YSettingRuntimeIdentity.isSignedInstalledCopy(
            expectedPath: YClipApplicationIdentity.installedApplicationPath,
            expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier,
            expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier
        )
        guard isInstalledCopy else {
            return
        }

        settingsStore.accessibilityRepairPending = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "已切换到正式安装版"
            alert.informativeText = "Y-Clip 已从 /Applications 重新启动。接下来请在系统设置中重新允许辅助功能权限。"
            alert.addButton(withTitle: "打开系统设置")
            alert.runModal()
            AccessibilityPermission.requestPrompt()
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
