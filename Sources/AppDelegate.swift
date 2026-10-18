import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum HotKeyIdentifier: UInt32 {
        case history = 1
        case pinnedHistory = 2
        case copyList = 3
        case standalone = 4
    }

    private let settingsStore = SettingsStore()
    private lazy var historyStore = ClipboardHistoryStore(maxItems: settingsStore.maxHistoryItems)
    private let softwareUpdateController = SoftwareUpdateController()
    private let panelController = ClipboardPanelController()
    private var curatedStore: CuratedClipboardStore?
    private var curatedPanelController: CuratedClipboardPanelController?
    private var standalonePanels: [UUID: StandaloneSnippetController] = [:]
    private lazy var permissionPromptCoordinator = YPermissionPromptCoordinator(
        configuration: YPermissionPromptConfiguration(
            appName: "Y-Clip",
            persistenceNamespace: YClipApplicationIdentity.bundleIdentifier
        )
    )
    private var hotKeyController: HotKeyController?
    private var pinnedHotKeyController: HotKeyController?
    private var copyListHotKeyController: HotKeyController?
    private var standaloneHotKeyController: HotKeyController?
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
        registerCopyListHotKey(settingsStore.copyListHotKey)
        registerStandaloneHotKey(settingsStore.standaloneHotKey)
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
        panelController.onOpenSettings = { [weak self] in
            guard let self else {
                return
            }

            panelController.dismissForSettingsTransition()
            DispatchQueue.main.async { [weak self] in
                self?.openSettings()
            }
        }
        panelController.onOpenCuratedPanel = { [weak self] in
            guard let self else { return }
            if !panelController.isPinned {
                panelController.dismissForSettingsTransition()
            }
            DispatchQueue.main.async { [weak self] in
                self?.ensureCuratedPanel()?.show(returnToHistory: true)
            }
        }
        panelController.onAddToCurated = { [weak self] item in
            self?.addToCurated(item)
        }
        panelController.onStickOut = { [weak self] item in
            self?.stickOut(item)
        }
        panelController.addSelectedHotKey = settingsStore.addSelectedHotKey
        panelController.stickSelectedHotKey = settingsStore.stickSelectedHotKey

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
        copyListHotKeyController = nil
        standaloneHotKeyController = nil
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusBarIcon.makeImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Y-Clip"
        let menu = YProjectStatusMenu.make(
            target: self,
            openSettingsAction: #selector(openSettings),
            quitAction: #selector(quit),
            appName: "Y-Clip"
        )
        let curatedItem = NSMenuItem(
            title: "打开复制清单",
            action: #selector(openCuratedPanel),
            keyEquivalent: ""
        )
        curatedItem.target = self
        menu.insertItem(curatedItem, at: 0)
        let standaloneItem = NSMenuItem(
            title: "单独贴出当前内容",
            action: #selector(stickOutCurrentClipboard),
            keyEquivalent: ""
        )
        standaloneItem.target = self
        menu.insertItem(standaloneItem, at: 1)
        item.menu = menu

        statusItem = item
    }

    private func setupSettingsWindow() {
        settingsWindowController = SettingsWindowController(
            hotKey: settingsStore.hotKey,
            pinnedHotKey: settingsStore.pinnedHotKey,
            copyListHotKey: settingsStore.copyListHotKey,
            standaloneHotKey: settingsStore.standaloneHotKey,
            addSelectedHotKey: settingsStore.addSelectedHotKey,
            stickSelectedHotKey: settingsStore.stickSelectedHotKey,
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
            onCopyListHotKeyChange: { [weak self] hotKey in
                self?.setCopyListHotKey(hotKey)
            },
            onStandaloneHotKeyChange: { [weak self] hotKey in
                self?.setStandaloneHotKey(hotKey)
            },
            onAddSelectedHotKeyChange: { [weak self] hotKey in
                self?.settingsStore.addSelectedHotKey = hotKey
                self?.panelController.addSelectedHotKey = hotKey
                self?.settingsWindowController?.updateAddSelectedHotKey(hotKey)
            },
            onStickSelectedHotKeyChange: { [weak self] hotKey in
                self?.settingsStore.stickSelectedHotKey = hotKey
                self?.panelController.stickSelectedHotKey = hotKey
                self?.settingsWindowController?.updateStickSelectedHotKey(hotKey)
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

    @objc private func openCuratedPanel() {
        ensureCuratedPanel()?.show(returnToHistory: false)
    }

    private func toggleCuratedPanel() {
        ensureCuratedPanel()?.toggle()
    }

    private func ensureCuratedPanel() -> CuratedClipboardPanelController? {
        if let curatedPanelController {
            return curatedPanelController
        }
        do {
            let store = try CuratedClipboardStore()
            let controller = CuratedClipboardPanelController(store: store)
            controller.onError = { [weak self] message in
                self?.showAlert(title: "复制清单", message: message)
            }
            controller.onBackToHistory = { [weak self] in
                guard let self else { return }
                self.showClipboardHistory(
                    pinned: self.panelController.isPinned,
                    preserveFocusContext: true
                )
            }
            curatedStore = store
            curatedPanelController = controller
            return controller
        } catch {
            showAlert(title: "无法打开复制清单", message: error.localizedDescription)
            return nil
        }
    }

    private func addToCurated(_ item: ClipboardItem) {
        guard let controller = ensureCuratedPanel(), let store = curatedStore else { return }
        do {
            let imageURL = item.image.map { historyStore.imageURL(for: $0) }
            try store.addFromHistory(item, imageURL: imageURL)
            if !panelController.isPinned {
                panelController.dismissForSettingsTransition()
            }
            DispatchQueue.main.async {
                controller.show(returnToHistory: true)
            }
        } catch {
            showAlert(title: "加入复制清单失败", message: error.localizedDescription)
        }
    }

    private func stickOut(_ item: ClipboardItem) {
        let imageData: Data?
        if let payload = item.image {
            guard let data = try? Data(contentsOf: historyStore.imageURL(for: payload)) else {
                showAlert(title: "无法贴出", message: "原图片已不在剪贴板历史中。")
                return
            }
            imageData = data
        } else {
            imageData = nil
        }

        showStandalone(item: item, imageData: imageData)
    }

    @objc private func stickOutCurrentClipboard() {
        guard let snapshot = CurrentClipboardSnapshot.capture() else {
            showAlert(title: "无法单独贴出", message: "当前剪贴板没有可贴出的文字或图片。")
            return
        }
        showStandalone(item: snapshot.item, imageData: snapshot.imageData)
    }

    private func showStandalone(item: ClipboardItem, imageData: Data?) {
        let controller = StandaloneSnippetController(item: item, imageData: imageData)
        controller.onClose = { [weak self] id in
            self?.standalonePanels.removeValue(forKey: id)
        }
        standalonePanels[controller.id] = controller
        let point = NSEvent.mouseLocation
        if !panelController.isPinned {
            panelController.dismissForSettingsTransition()
        }
        DispatchQueue.main.async {
            controller.show(near: point)
        }
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

    private func registerCopyListHotKey(_ hotKey: HotKey) {
        do {
            let controller = copyListHotKeyController
                ?? HotKeyController(identifier: HotKeyIdentifier.copyList.rawValue) { [weak self] in
                    self?.toggleCuratedPanel()
                }
            try controller.register(hotKey: hotKey)
            copyListHotKeyController = controller
        } catch {
            showAlert(title: "复制清单快捷键注册失败", message: error.localizedDescription)
        }
    }

    private func setCopyListHotKey(_ hotKey: HotKey) {
        let previous = settingsStore.copyListHotKey
        do {
            let controller = copyListHotKeyController
                ?? HotKeyController(identifier: HotKeyIdentifier.copyList.rawValue) { [weak self] in
                    self?.toggleCuratedPanel()
                }
            try controller.register(hotKey: hotKey)
            copyListHotKeyController = controller
            settingsStore.copyListHotKey = hotKey
            settingsWindowController?.updateCopyListHotKey(hotKey)
        } catch {
            registerCopyListHotKey(previous)
            settingsWindowController?.updateCopyListHotKey(previous)
            showAlert(title: "复制清单快捷键不可用", message: error.localizedDescription)
        }
    }

    private func registerStandaloneHotKey(_ hotKey: HotKey) {
        do {
            let controller = standaloneHotKeyController
                ?? HotKeyController(identifier: HotKeyIdentifier.standalone.rawValue) { [weak self] in
                    self?.stickOutCurrentClipboard()
                }
            try controller.register(hotKey: hotKey)
            standaloneHotKeyController = controller
        } catch {
            showAlert(title: "单独贴出快捷键注册失败", message: error.localizedDescription)
        }
    }

    private func setStandaloneHotKey(_ hotKey: HotKey) {
        let previous = settingsStore.standaloneHotKey
        do {
            let controller = standaloneHotKeyController
                ?? HotKeyController(identifier: HotKeyIdentifier.standalone.rawValue) { [weak self] in
                    self?.stickOutCurrentClipboard()
                }
            try controller.register(hotKey: hotKey)
            standaloneHotKeyController = controller
            settingsStore.standaloneHotKey = hotKey
            settingsWindowController?.updateStandaloneHotKey(hotKey)
        } catch {
            registerStandaloneHotKey(previous)
            settingsWindowController?.updateStandaloneHotKey(previous)
            showAlert(title: "单独贴出快捷键不可用", message: error.localizedDescription)
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
            copyListHotKeyController?.unregister()
            standaloneHotKeyController?.unregister()
        } else {
            registerHotKey(settingsStore.hotKey)
            registerPinnedHotKey(settingsStore.pinnedHotKey)
            registerCopyListHotKey(settingsStore.copyListHotKey)
            registerStandaloneHotKey(settingsStore.standaloneHotKey)
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

    private func showClipboardHistory(pinned: Bool, preserveFocusContext: Bool = false) {
        if !preserveFocusContext {
            focusContext = FocusContextReader.current()
        }
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
