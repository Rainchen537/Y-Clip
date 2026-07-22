import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum HotKeyIdentifier: UInt32 {
        case history = 1
        case pinnedHistory = 2
    }

    private let settingsStore = SettingsStore()
    private lazy var historyStore = ClipboardHistoryStore(maxItems: settingsStore.maxHistoryItems)
    private let softwareUpdateController = SoftwareUpdateController()
    private let panelController = ClipboardPanelController()
    private lazy var permissionPromptCoordinator = YPermissionPromptCoordinator(
        configuration: YPermissionPromptConfiguration(
            appName: "Y-Clip",
            persistenceNamespace: YClipApplicationIdentity.bundleIdentifier
        )
    )
    private var hotKeyController: HotKeyController?
    private var pinnedHotKeyController: HotKeyController?
    private var hotKeysSuspendedForRecording = false
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
        registerPinnedHotKey(settingsStore.pinnedHotKey)
        scheduleAutomaticUpdateCheckIfNeeded()
        rememberAccessibilityTrustIfNeeded()
        let wasAccessibilityRepairPending = settingsStore.accessibilityRepairPending
        continuePendingAccessibilityRepairIfNeeded()
        if !wasAccessibilityRepairPending {
            permissionPromptCoordinator.presentInitialGuidanceIfNeeded(
                permissions: permissionDescriptors,
                runtime: permissionRuntimeDescriptor
            )
        }

        // 让面板能根据图片项找到磁盘上的全图，用于生成缩略图。
        panelController.imageURLProvider = { [weak self] payload in
            self?.historyStore.imageURL(for: payload) ?? URL(fileURLWithPath: "/dev/null")
        }
        panelController.onPinnedFrameChange = { [weak self] frame in
            self?.settingsStore.pinnedPanelFrame = frame
        }
        historyStore.observe { [weak self] items in
            self?.panelController.updatePinnedItems(items)
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
        UpdateLaunchReadiness.markApplicationReady()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if AccessibilityPermission.isTrusted(prompt: false) {
            settingsStore.accessibilityWasTrusted = true
        }
        permissionPromptCoordinator.presentMissingPermissionIfNeeded(
            permissions: permissionDescriptors,
            runtime: permissionRuntimeDescriptor
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController = nil
        pinnedHotKeyController = nil
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
            pinnedHotKey: settingsStore.pinnedHotKey,
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
            onPinnedHotKeyChange: { [weak self] hotKey in
                self?.setPinnedHotKey(hotKey)
            },
            onHotKeyRecordingChange: { [weak self] isRecording in
                self?.setHotKeyRecordingSuspended(isRecording)
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
            let hotKeyController = hotKeyController ?? HotKeyController(identifier: HotKeyIdentifier.history.rawValue) { [weak self] in
                self?.showClipboardHistory(pinned: false)
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
            let hotKeyController = hotKeyController ?? HotKeyController(identifier: HotKeyIdentifier.history.rawValue) { [weak self] in
                self?.showClipboardHistory(pinned: false)
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

    private func registerPinnedHotKey(_ hotKey: HotKey) {
        do {
            let controller = pinnedHotKeyController
                ?? HotKeyController(identifier: HotKeyIdentifier.pinnedHistory.rawValue) { [weak self] in
                    self?.showClipboardHistory(pinned: true)
                }
            try controller.register(hotKey: hotKey)
            pinnedHotKeyController = controller
        } catch {
            showAlert(
                title: "固定面板快捷键注册失败",
                message: error.localizedDescription
            )
        }
    }

    private func setPinnedHotKey(_ hotKey: HotKey) {
        let previousHotKey = settingsStore.pinnedHotKey

        do {
            let controller = pinnedHotKeyController
                ?? HotKeyController(identifier: HotKeyIdentifier.pinnedHistory.rawValue) { [weak self] in
                    self?.showClipboardHistory(pinned: true)
                }
            try controller.register(hotKey: hotKey)
            pinnedHotKeyController = controller
            settingsStore.pinnedHotKey = hotKey
            settingsWindowController?.updatePinnedHotKey(hotKey)
        } catch {
            registerPinnedHotKey(previousHotKey)
            settingsWindowController?.updatePinnedHotKey(previousHotKey)
            showAlert(
                title: "固定面板快捷键不可用",
                message: error.localizedDescription
            )
        }
    }

    private func setHotKeyRecordingSuspended(_ suspended: Bool) {
        guard hotKeysSuspendedForRecording != suspended else {
            return
        }

        hotKeysSuspendedForRecording = suspended
        if suspended {
            hotKeyController?.unregister()
            pinnedHotKeyController?.unregister()
        } else {
            registerHotKey(settingsStore.hotKey)
            registerPinnedHotKey(settingsStore.pinnedHotKey)
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

    private func showClipboardHistory(pinned: Bool) {
        focusContext = FocusContextReader.current()
        let anchorPoint = usableAnchorPoint(focusContext?.caretPoint)

        panelController.show(
            items: historyStore.items,
            metrics: settingsStore.panelMetrics,
            near: anchorPoint,
            pinned: pinned,
            pinnedFrame: settingsStore.pinnedPanelFrame,
            onChoose: { [weak self] item in
                guard let self else { return }
                if panelController.isPinned {
                    let currentContext = FocusContextReader.current()
                    if currentContext.application != nil {
                        focusContext = currentContext
                    }
                }
                paste(item)
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

    private var permissionDescriptors: [YPermissionPromptDescriptor] {
        [
            YPermissionPromptDescriptor(
                identifier: "accessibility",
                displayName: "辅助功能权限",
                explanation: "用于将已选择的剪贴板内容自动粘贴到当前 App。",
                settingsLocation: "System Settings → Privacy & Security → Accessibility",
                state: {
                    AccessibilityPermission.isTrusted(prompt: false)
                        ? .granted
                        : .missing
                },
                requestAction: YPermissionPromptAction(
                    title: "打开系统设置",
                    perform: {
                        AccessibilityPermission.requestPrompt()
                        AccessibilityPermission.openSettings()
                    }
                ),
                openSettingsAction: YPermissionPromptAction(
                    title: "打开系统设置",
                    perform: {
                        AccessibilityPermission.requestPrompt()
                        AccessibilityPermission.openSettings()
                    }
                ),
                repairAction: YPermissionPromptAction(
                    title: "刷新权限记录",
                    perform: { [weak self] in
                        self?.refreshAccessibilityAuthorization()
                    }
                ),
                prefersRepairWhenMissing: { [weak self] in
                    self?.settingsStore.accessibilityWasTrusted == true
                }
            )
        ]
    }

    private var permissionRuntimeDescriptor: YPermissionRuntimeDescriptor {
        YPermissionRuntimeDescriptor(
            installedApplicationPath: YClipApplicationIdentity.installedApplicationPath,
            isRunningPreferredCopy: {
                YSettingRuntimeIdentity.isSignedInstalledCopy(
                    expectedPath: YClipApplicationIdentity.installedApplicationPath,
                    expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier,
                    expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier
                )
            },
            hasPreferredCopy: {
                YSettingRuntimeIdentity.isValidSignedApplication(
                    atPath: YClipApplicationIdentity.installedApplicationPath,
                    expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
                    expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
                )
            },
            switchAction: YPermissionPromptAction(
                title: "切换到安装版",
                perform: { [weak self] in
                    self?.relaunchInstalledApplication(
                        errorTitle: "无法切换到正式安装版"
                    )
                }
            )
        )
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

        permissionPromptCoordinator.presentMissingPermissionIfNeeded(
            permissions: permissionDescriptors,
            runtime: permissionRuntimeDescriptor,
            reason: settingsStore.accessibilityWasTrusted
                ? "macOS 在应用更新后有时会保留旧的辅助功能记录，导致系统设置看起来已开启，但当前版本仍无法自动粘贴。"
                : "内容已经复制到剪贴板，但当前还不能自动粘贴。",
            force: true
        )
    }

    private func refreshAccessibilityAuthorization(completion: ((AccessibilityRepairResult) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try AccessibilityPermission.resetAuthorization()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.settingsStore.accessibilityWasTrusted = false
                    self.permissionPromptCoordinator.resetPresentationHistory()
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
        permissionPromptCoordinator.resetPresentationHistory()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.permissionPromptCoordinator.presentMissingPermissionIfNeeded(
                permissions: self.permissionDescriptors,
                runtime: self.permissionRuntimeDescriptor,
                reason: "Y-Clip 已从 /Applications 重新启动。请在系统设置中重新允许辅助功能权限。",
                force: true
            )
        }
    }

    private func relaunchInstalledApplication(errorTitle: String) {
        do {
            try YSettingRuntimeIdentity.relaunchInstalledApplication(
                atPath: YClipApplicationIdentity.installedApplicationPath,
                expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
                expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
            )
        } catch {
            showAlert(title: errorTitle, message: error.localizedDescription)
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
