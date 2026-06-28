import AppKit
import Carbon

final class SettingsWindowController: NSObject {
    private let settingsContentController: SettingsContentController
    private let windowController: YSettingWindowController
    private let previewPanel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }()
    private var previewHideWorkItem: DispatchWorkItem?
    private var isPreviewHeldByHover = false
    private var escapeMonitor: Any?
    private var windowMoveObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?

    init(
        hotKey: HotKey,
        panelMetrics: HistoryPanelMetrics,
        maxHistoryItems: Int,
        autoUpdateEnabled: Bool,
        launchAtLoginEnabled: Bool,
        onClearHistory: @escaping () -> Void,
        onLaunchAtLoginChange: @escaping (Bool) -> Void,
        onHotKeyChange: @escaping (HotKey) -> Void,
        onPanelMetricsChange: @escaping (HistoryPanelMetrics) -> Void,
        onMaxHistoryItemsChange: @escaping (Int) -> Void,
        onAutoUpdateChange: @escaping (Bool) -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onInstallUpdate: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onOpenGitHub: @escaping () -> Void
    ) {
        settingsContentController = SettingsContentController(
            hotKey: hotKey,
            panelMetrics: panelMetrics,
            maxHistoryItems: maxHistoryItems,
            autoUpdateEnabled: autoUpdateEnabled,
            launchAtLoginEnabled: launchAtLoginEnabled,
            onClearHistory: onClearHistory,
            onLaunchAtLoginChange: onLaunchAtLoginChange,
            onHotKeyChange: onHotKeyChange,
            onPanelMetricsChange: onPanelMetricsChange,
            onMaxHistoryItemsChange: onMaxHistoryItemsChange,
            onAutoUpdateChange: onAutoUpdateChange,
            onCheckForUpdates: onCheckForUpdates,
            onInstallUpdate: onInstallUpdate,
            onOpenAccessibility: onOpenAccessibility,
            onOpenGitHub: onOpenGitHub
        )

        let descriptor = YSettingAppDescriptor(
            displayName: "Y-Clip",
            subtitle: "全局剪贴板历史",
            version: YSettingUI.appVersionString(),
            icon: YSettingUI.bundledAppIcon()
        )
        let items = [
            YSettingSidebarItem("clipboard", title: "剪贴板", symbolName: "clipboard"),
            YSettingSidebarItem("behavior", title: "行为", symbolName: "switch.2"),
            YSettingSidebarItem("actions", title: "操作", symbolName: "slider.horizontal.3"),
            YSettingSidebarItem("about", title: "关于", symbolName: "info.circle")
        ]
        let contentController = settingsContentController
        windowController = YSettingWindowController(
            descriptor: descriptor,
            sidebarItems: items,
            initialIdentifier: "clipboard"
        ) { identifier in
            contentController.makeContent(for: identifier)
        }

        super.init()

        previewPanel.contentView = settingsContentController.previewView
        settingsContentController.onPreviewAdjustment = { [weak self] in
            self?.showPreviewPanelTemporarily()
        }
        settingsContentController.onDisplayHoverChange = { [weak self] isHovering in
            self?.setPreviewHovering(isHovering)
        }
        windowController.onClose = { [weak self] in
            self?.handleWindowClosed()
        }
    }

    deinit {
        endEscapeMonitoring()
        removeWindowObservers()
    }

    var isShown: Bool {
        windowController.isVisible
    }

    func show() {
        updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
        windowController.showAndActivate()
        settingsContentController.clearInitialFocus(in: windowController.window)
        beginEscapeMonitoring()
        installWindowObserversIfNeeded()
    }

    func close() {
        windowController.close()
    }

    func updateHotKey(_ hotKey: HotKey) {
        settingsContentController.updateHotKey(hotKey)
    }

    func updatePanelMetrics(_ metrics: HistoryPanelMetrics) {
        settingsContentController.updatePanelMetrics(metrics)
    }

    func updateMaxHistoryItems(_ count: Int) {
        settingsContentController.updateMaxHistoryItems(count)
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        settingsContentController.updateLaunchAtLogin(enabled)
    }

    func updateUpdateStatus(_ status: SoftwareUpdateStatus) {
        settingsContentController.updateUpdateStatus(status)
    }

    private func handleWindowClosed() {
        endEscapeMonitoring()
        removeWindowObservers()
        isPreviewHeldByHover = false
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
        previewPanel.orderOut(nil)
        settingsContentController.stopRecording()
    }

    private func beginEscapeMonitoring() {
        endEscapeMonitoring()

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else {
                return event
            }

            if self?.settingsContentController.isRecordingHotKey == true {
                return event
            }

            self?.close()
            return nil
        }
    }

    private func endEscapeMonitoring() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }

        escapeMonitor = nil
    }

    private func installWindowObserversIfNeeded() {
        guard let window = windowController.window else {
            return
        }

        removeWindowObservers()
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.positionPreviewPanelIfVisible()
        }
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.positionPreviewPanelIfVisible()
        }
    }

    private func removeWindowObservers() {
        if let windowMoveObserver {
            NotificationCenter.default.removeObserver(windowMoveObserver)
        }
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
        }
        windowMoveObserver = nil
        windowResizeObserver = nil
    }

    private func showPreviewPanelTemporarily() {
        guard windowController.isVisible else {
            return
        }

        showPreviewPanel()

        guard !isPreviewHeldByHover else {
            return
        }

        previewHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard self?.isPreviewHeldByHover == false else {
                return
            }

            self?.hidePreviewPanel()
        }
        previewHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func setPreviewHovering(_ isHovering: Bool) {
        isPreviewHeldByHover = isHovering

        if isHovering {
            previewHideWorkItem?.cancel()
            previewHideWorkItem = nil
            showPreviewPanel()
        } else {
            previewHideWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard self?.isPreviewHeldByHover == false else {
                    return
                }

                self?.hidePreviewPanel()
            }
            previewHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }
    }

    private func showPreviewPanel() {
        guard windowController.isVisible else {
            return
        }

        positionPreviewPanel()
        previewPanel.orderFront(nil)
    }

    private func hidePreviewPanel() {
        previewPanel.orderOut(nil)
        previewHideWorkItem = nil
    }

    private func positionPreviewPanelIfVisible() {
        guard previewPanel.isVisible else {
            return
        }

        positionPreviewPanel()
    }

    private func positionPreviewPanel() {
        guard let settingsWindow = windowController.window else {
            return
        }

        let previewSize = ClipboardPreviewView.previewSize(for: settingsContentController.panelMetrics)
        settingsContentController.previewView.frame = NSRect(origin: .zero, size: previewSize)

        let settingsFrame = settingsWindow.frame
        let screen = settingsWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let gap: CGFloat = 12

        let rightX = settingsFrame.maxX + gap
        let leftX = settingsFrame.minX - previewSize.width - gap
        let x: CGFloat

        if rightX + previewSize.width <= visibleFrame.maxX {
            x = rightX
        } else if leftX >= visibleFrame.minX {
            x = leftX
        } else {
            x = clamp(leftX, lower: visibleFrame.minX, upper: visibleFrame.maxX - previewSize.width)
        }

        let y = clamp(
            settingsFrame.maxY - previewSize.height,
            lower: visibleFrame.minY,
            upper: visibleFrame.maxY - previewSize.height
        )
        previewPanel.setFrame(NSRect(x: x, y: y, width: previewSize.width, height: previewSize.height), display: true)
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

private final class SettingsContentController {
    let previewView = ClipboardPreviewView()
    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private let launchAtLoginSwitch = NSSwitch(frame: .zero)
    private let launchAtLoginStatusPill = YSettingPill()
    private let autoUpdateSwitch = NSSwitch(frame: .zero)
    private let autoUpdateStatusPill = YSettingPill()
    private let recordingHintLabel = NSTextField(labelWithString: "")
    private let scaleSlider = NSSlider()
    private let scaleValuePill = YSettingPill()
    private let widthSlider = NSSlider()
    private let widthValuePill = YSettingPill()
    private let lengthSlider = NSSlider()
    private let lengthValuePill = YSettingPill()
    private let updateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let updateStatusLabel = NSTextField(labelWithString: "尚未检查更新。")
    private let versionPill = YSettingPill()
    private let historyLimitField = NSTextField(string: "")
    private let historyLimitStepper = NSStepper()
    private var localKeyMonitor: Any?
    private var currentHotKey: HotKey
    private var currentPanelMetrics: HistoryPanelMetrics
    private var currentMaxHistoryItems: Int
    private var currentUpdateStatus: SoftwareUpdateStatus = .idle
    private let onClearHistory: () -> Void
    private let onLaunchAtLoginChange: (Bool) -> Void
    private let onHotKeyChange: (HotKey) -> Void
    private let onPanelMetricsChange: (HistoryPanelMetrics) -> Void
    private let onMaxHistoryItemsChange: (Int) -> Void
    private let onAutoUpdateChange: (Bool) -> Void
    private let onCheckForUpdates: () -> Void
    private let onInstallUpdate: () -> Void
    private let onOpenAccessibility: () -> Void
    private let onOpenGitHub: () -> Void
    var onPreviewAdjustment: (() -> Void)?
    var onDisplayHoverChange: ((Bool) -> Void)?
    var panelMetrics: HistoryPanelMetrics {
        currentPanelMetrics
    }
    var isRecordingHotKey: Bool {
        localKeyMonitor != nil
    }

    init(
        hotKey: HotKey,
        panelMetrics: HistoryPanelMetrics,
        maxHistoryItems: Int,
        autoUpdateEnabled: Bool,
        launchAtLoginEnabled: Bool,
        onClearHistory: @escaping () -> Void,
        onLaunchAtLoginChange: @escaping (Bool) -> Void,
        onHotKeyChange: @escaping (HotKey) -> Void,
        onPanelMetricsChange: @escaping (HistoryPanelMetrics) -> Void,
        onMaxHistoryItemsChange: @escaping (Int) -> Void,
        onAutoUpdateChange: @escaping (Bool) -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onInstallUpdate: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onOpenGitHub: @escaping () -> Void
    ) {
        currentHotKey = hotKey
        currentPanelMetrics = panelMetrics
        currentMaxHistoryItems = SettingsStore.clampedHistoryLimit(maxHistoryItems)
        self.onClearHistory = onClearHistory
        self.onLaunchAtLoginChange = onLaunchAtLoginChange
        self.onHotKeyChange = onHotKeyChange
        self.onPanelMetricsChange = onPanelMetricsChange
        self.onMaxHistoryItemsChange = onMaxHistoryItemsChange
        self.onAutoUpdateChange = onAutoUpdateChange
        self.onCheckForUpdates = onCheckForUpdates
        self.onInstallUpdate = onInstallUpdate
        self.onOpenAccessibility = onOpenAccessibility
        self.onOpenGitHub = onOpenGitHub

        launchAtLoginSwitch.state = launchAtLoginEnabled ? .on : .off
        autoUpdateSwitch.state = autoUpdateEnabled ? .on : .off
        configureControls()
        updatePanelMetrics(panelMetrics)
        updateHotKey(hotKey)
        updateMaxHistoryItems(currentMaxHistoryItems)
        updateLaunchAtLogin(launchAtLoginEnabled)
        updateAutoUpdateState(autoUpdateEnabled)
        updateUpdateStatus(currentUpdateStatus)
    }

    func makeContent(for identifier: String) -> NSView {
        switch identifier {
        case "behavior":
            return behaviorContent()
        case "actions":
            return actionsContent()
        case "about":
            return aboutContent()
        default:
            return clipboardContent()
        }
    }

    func clearInitialFocus(in window: NSWindow?) {
        window?.makeFirstResponder(window?.contentView)
        historyLimitField.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
    }

    func updateHotKey(_ hotKey: HotKey) {
        currentHotKey = hotKey
        shortcutButton.title = hotKey.displayName
        recordingHintLabel.stringValue = ""
        recordingHintLabel.isHidden = true
    }

    func updatePanelMetrics(_ metrics: HistoryPanelMetrics) {
        currentPanelMetrics = metrics
        scaleSlider.doubleValue = Double(metrics.scale)
        widthSlider.doubleValue = Double(metrics.width)
        lengthSlider.doubleValue = Double(metrics.visibleRows)
        scaleValuePill.setText("\(Int(round(metrics.scale * 100)))%", tone: .accent)
        widthValuePill.setText("\(Int(round(metrics.width))) px", tone: .neutral)
        lengthValuePill.setText(String(format: "%.1f 行", Double(metrics.visibleRows)), tone: .neutral)
        previewView.metrics = metrics
    }

    func updateMaxHistoryItems(_ count: Int) {
        currentMaxHistoryItems = SettingsStore.clampedHistoryLimit(count)
        historyLimitField.stringValue = "\(currentMaxHistoryItems)"
        historyLimitStepper.integerValue = currentMaxHistoryItems
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginSwitch.state = enabled ? .on : .off
        launchAtLoginStatusPill.setText(enabled ? "已开启" : "未开启", tone: enabled ? .success : .disabled)
    }

    func updateUpdateStatus(_ status: SoftwareUpdateStatus) {
        currentUpdateStatus = status

        switch status {
        case .idle:
            configureUpdateButton(title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary)
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = "尚未检查更新。"
            updateStatusLabel.textColor = .secondaryLabelColor
        case .checking:
            configureUpdateButton(title: "检查中", symbolName: "arrow.triangle.2.circlepath", role: .secondary)
            updateButton.isEnabled = false
            updateStatusLabel.stringValue = "正在检查 GitHub Release..."
            updateStatusLabel.textColor = .secondaryLabelColor
        case let .upToDate(version):
            configureUpdateButton(title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary)
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = "已是最新版 \(version)。"
            updateStatusLabel.textColor = .systemGreen
        case let .available(version, _, _):
            configureUpdateButton(title: "安装更新", symbolName: "arrow.down.circle", role: .primary)
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = "发现新版本 \(version)，点击安装更新。"
            updateStatusLabel.textColor = .controlAccentColor
        case let .installing(message):
            configureUpdateButton(title: "安装中", symbolName: "arrow.down.circle", role: .secondary)
            updateButton.isEnabled = false
            updateStatusLabel.stringValue = message
            updateStatusLabel.textColor = .secondaryLabelColor
        case let .failed(message):
            configureUpdateButton(title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary)
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = message
            updateStatusLabel.textColor = .systemRed
        }
    }

    func stopRecording() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }

        localKeyMonitor = nil
        shortcutButton.title = currentHotKey.displayName
        recordingHintLabel.stringValue = ""
        recordingHintLabel.isHidden = true
    }

    private func clipboardContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "剪贴板",
            symbolName: "clipboard",
            subtitle: "调整历史面板尺寸、展示行数和历史保留数量。"
        )

        let resetButton = YSettingUI.makeButton(
            title: "恢复默认",
            symbolName: "arrow.counterclockwise",
            role: .secondary,
            target: self,
            action: #selector(confirmResetPanelMetrics)
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "历史面板",
            symbolName: "rectangle.on.rectangle",
            views: [
                YSettingUI.sliderRow(title: "面板大小", slider: scaleSlider, valueView: scaleValuePill),
                YSettingUI.sliderRow(title: "面板宽度", slider: widthSlider, valueView: widthValuePill),
                YSettingUI.sliderRow(title: "显示行数", slider: lengthSlider, valueView: lengthValuePill),
                makeHistoryLimitRow()
            ],
            trailingView: resetButton,
            onHoverChange: { [weak self] isHovering in
                self?.onDisplayHoverChange?(isHovering)
            }
        ))

        return stack
    }

    private func behaviorContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "行为",
            symbolName: "switch.2",
            subtitle: "设置呼出方式、开机启动和自动检查更新。"
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "快捷操作",
            symbolName: "keyboard",
            views: [
                YSettingUI.row(title: "快捷键", trailingView: shortcutButton),
                YSettingUI.row(title: "开机启动", trailingView: YSettingUI.horizontal([launchAtLoginStatusPill, launchAtLoginSwitch])),
                YSettingUI.row(title: "自动检查更新", trailingView: YSettingUI.horizontal([autoUpdateStatusPill, autoUpdateSwitch])),
                recordingHintLabel
            ]
        ))

        return stack
    }

    private func actionsContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "操作",
            symbolName: "slider.horizontal.3",
            subtitle: "管理历史数据和系统权限。"
        )

        let clearButton = YSettingUI.makeButton(
            title: "清空...",
            symbolName: "trash",
            role: .danger,
            target: self,
            action: #selector(confirmClearHistory)
        )
        let permissionButton = YSettingUI.makeButton(
            title: "辅助功能",
            symbolName: "accessibility",
            role: .secondary,
            target: self,
            action: #selector(openAccessibility)
        )

        let permissionHint = YSettingUI.secondaryLabel("自动粘贴需要辅助功能权限。若系统设置显示已开启但仍无法粘贴，可进入权限修复流程刷新记录。")

        stack.addArrangedSubview(YSettingSectionView(
            title: "维护",
            symbolName: "wrench.and.screwdriver",
            views: [
                YSettingUI.row(title: "清空历史", trailingView: clearButton),
                YSettingUI.row(title: "系统权限", trailingView: permissionButton),
                permissionHint
            ]
        ))

        return stack
    }

    private func aboutContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "关于",
            symbolName: "info.circle",
            subtitle: "版本、更新和项目主页。"
        )

        versionPill.setText(YSettingUI.appVersionString(), tone: .neutral)
        let githubButton = YSettingUI.makeButton(
            title: "GitHub",
            symbolName: "arrow.up.right.square",
            role: .link,
            target: self,
            action: #selector(openGitHub)
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "版本",
            symbolName: "sparkles",
            views: [
                YSettingUI.row(title: "当前版本", trailingView: YSettingUI.horizontal([versionPill, updateButton])),
                YSettingUI.row(title: "项目主页", trailingView: githubButton),
                updateStatusLabel
            ]
        ))

        return stack
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = launchAtLoginSwitch.state == .on
        updateLaunchAtLogin(enabled)
        onLaunchAtLoginChange(enabled)
    }

    @objc private func toggleAutoUpdate() {
        let enabled = autoUpdateSwitch.state == .on
        updateAutoUpdateState(enabled)
        onAutoUpdateChange(enabled)
    }

    @objc private func checkForUpdates() {
        if case .available = currentUpdateStatus {
            onInstallUpdate()
        } else {
            onCheckForUpdates()
        }
    }

    @objc private func changePanelMetrics() {
        let metrics = HistoryPanelMetrics(
            scale: CGFloat(scaleSlider.doubleValue),
            width: CGFloat(widthSlider.doubleValue),
            visibleRows: CGFloat(lengthSlider.doubleValue)
        )
        updatePanelMetrics(metrics)
        onPanelMetricsChange(metrics)
        onPreviewAdjustment?()
    }

    @objc private func confirmResetPanelMetrics() {
        let alert = NSAlert()
        alert.messageText = "恢复默认显示设置？"
        alert.informativeText = "大小、宽度和显示行数会恢复到默认值。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let metrics = HistoryPanelMetrics.default
        updatePanelMetrics(metrics)
        onPanelMetricsChange(metrics)
        onPreviewAdjustment?()
    }

    @objc private func stepHistoryLimit() {
        applyHistoryLimit(historyLimitStepper.integerValue)
    }

    @objc private func commitHistoryLimit() {
        applyHistoryLimit(historyLimitField.integerValue)
    }

    @objc private func startRecording() {
        shortcutButton.title = "录制中"
        recordingHintLabel.stringValue = "按下新的组合键，Esc 取消"
        recordingHintLabel.textColor = .secondaryLabelColor
        recordingHintLabel.isHidden = false

        if localKeyMonitor != nil {
            return
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    @objc private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "已记录的文字和图片历史会被删除，当前系统剪贴板内容不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        onClearHistory()
    }

    @objc private func openAccessibility() {
        onOpenAccessibility()
    }

    @objc private func openGitHub() {
        onOpenGitHub()
    }

    private func configureControls() {
        configureSlider(
            scaleSlider,
            min: HistoryPanelMetrics.scaleRange.lowerBound,
            max: HistoryPanelMetrics.scaleRange.upperBound,
            action: #selector(changePanelMetrics)
        )
        configureSlider(
            widthSlider,
            min: HistoryPanelMetrics.widthRange.lowerBound,
            max: HistoryPanelMetrics.widthRange.upperBound,
            action: #selector(changePanelMetrics)
        )
        configureSlider(
            lengthSlider,
            min: HistoryPanelMetrics.visibleRowsRange.lowerBound,
            max: HistoryPanelMetrics.visibleRowsRange.upperBound,
            action: #selector(changePanelMetrics)
        )

        [scaleValuePill, widthValuePill, lengthValuePill].forEach { pill in
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true
        }

        shortcutButton.bezelStyle = .rounded
        shortcutButton.controlSize = .regular
        shortcutButton.target = self
        shortcutButton.action = #selector(startRecording)
        shortcutButton.setButtonType(.momentaryPushIn)
        shortcutButton.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        shortcutButton.contentTintColor = .controlAccentColor
        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        shortcutButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        recordingHintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        recordingHintLabel.textColor = .secondaryLabelColor
        recordingHintLabel.lineBreakMode = .byTruncatingTail
        recordingHintLabel.isHidden = true

        historyLimitField.alignment = .right
        historyLimitField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        historyLimitField.controlSize = .small
        historyLimitField.focusRingType = .none
        historyLimitField.target = self
        historyLimitField.action = #selector(commitHistoryLimit)
        historyLimitField.translatesAutoresizingMaskIntoConstraints = false
        historyLimitField.widthAnchor.constraint(equalToConstant: 66).isActive = true

        historyLimitStepper.minValue = Double(SettingsStore.allowedHistoryRange.lowerBound)
        historyLimitStepper.maxValue = Double(SettingsStore.allowedHistoryRange.upperBound)
        historyLimitStepper.increment = 1
        historyLimitStepper.controlSize = .small
        historyLimitStepper.target = self
        historyLimitStepper.action = #selector(stepHistoryLimit)

        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(toggleLaunchAtLogin)
        autoUpdateSwitch.target = self
        autoUpdateSwitch.action = #selector(toggleAutoUpdate)

        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)
        configureUpdateButton(title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary)

        updateStatusLabel.font = .systemFont(ofSize: 12, weight: .regular)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.lineBreakMode = .byWordWrapping
        updateStatusLabel.maximumNumberOfLines = 3
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        guard let hotKey = HotKey(event: event) else {
            recordingHintLabel.stringValue = "请至少包含一个修饰键"
            recordingHintLabel.textColor = .systemOrange
            recordingHintLabel.isHidden = false
            return
        }

        stopRecording()
        onHotKeyChange(hotKey)
    }

    private func applyHistoryLimit(_ count: Int) {
        let clamped = SettingsStore.clampedHistoryLimit(count)
        updateMaxHistoryItems(clamped)
        onMaxHistoryItemsChange(clamped)
    }

    private func updateAutoUpdateState(_ enabled: Bool) {
        autoUpdateSwitch.state = enabled ? .on : .off
        autoUpdateStatusPill.setText(enabled ? "已开启" : "未开启", tone: enabled ? .success : .disabled)
    }

    private func configureSlider(_ slider: NSSlider, min: Double, max: Double, action: Selector) {
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.controlSize = .small
    }

    private func configureUpdateButton(title: String, symbolName: String, role: YSettingButtonRole) {
        updateButton.title = title
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.font = .systemFont(ofSize: 12, weight: role == .primary ? .semibold : .regular)
        updateButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        updateButton.imagePosition = .imageLeading
        updateButton.alignment = .center
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        if !updateButton.constraints.contains(where: { $0.firstAttribute == .height }) {
            updateButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        switch role {
        case .primary:
            updateButton.contentTintColor = .controlAccentColor
        case .secondary:
            updateButton.contentTintColor = .secondaryLabelColor
        case .link:
            updateButton.contentTintColor = .controlAccentColor.withAlphaComponent(0.9)
        case .danger:
            updateButton.contentTintColor = .systemRed
        }
    }

    private func makeHistoryLimitRow() -> NSView {
        let unitLabel = YSettingUI.secondaryLabel("条")
        unitLabel.maximumNumberOfLines = 1
        let controls = YSettingUI.horizontal([historyLimitField, unitLabel, historyLimitStepper], spacing: 6)
        return YSettingUI.row(title: "历史上限", trailingView: controls)
    }
}
