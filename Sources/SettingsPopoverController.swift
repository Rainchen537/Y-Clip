import AppKit
import Carbon

final class SettingsPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let settingsViewController: SettingsViewController
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let anchorPanel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
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
    var onClose: (() -> Void)?

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
        settingsViewController = SettingsViewController(
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

        super.init()

        popover.contentSize = NSSize(width: 420, height: 640)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = settingsViewController
        popover.delegate = self
        anchorPanel.contentView = anchorView
        previewPanel.contentView = settingsViewController.previewView
        settingsViewController.onPreviewAdjustment = { [weak self] in
            self?.showPreviewPanelTemporarily()
        }
        settingsViewController.onDisplayHoverChange = { [weak self] isHovering in
            self?.setPreviewHovering(isHovering)
        }
    }

    var isShown: Bool {
        popover.isShown
    }

    func show(relativeTo view: NSView, preferredEdge: NSRectEdge = .minY) {
        updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
        DispatchQueue.main.async { [weak self] in
            self?.settingsViewController.clearInitialFocus()
        }
        beginEscapeMonitoring()
    }

    func show(near screenRect: NSRect, preferredEdge: NSRectEdge = .maxX) {
        updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
        anchorPanel.setFrame(
            NSRect(x: screenRect.midX, y: screenRect.midY, width: 1, height: 1),
            display: false
        )
        anchorPanel.orderFront(nil)
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: preferredEdge)
        DispatchQueue.main.async { [weak self] in
            self?.settingsViewController.clearInitialFocus()
        }
        beginEscapeMonitoring()
    }

    func close() {
        popover.performClose(nil)
    }

    func updateHotKey(_ hotKey: HotKey) {
        settingsViewController.updateHotKey(hotKey)
    }

    func updatePanelMetrics(_ metrics: HistoryPanelMetrics) {
        settingsViewController.updatePanelMetrics(metrics)
    }

    func updateMaxHistoryItems(_ count: Int) {
        settingsViewController.updateMaxHistoryItems(count)
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        settingsViewController.updateLaunchAtLogin(enabled)
    }

    func updateUpdateStatus(_ status: SoftwareUpdateStatus) {
        settingsViewController.updateUpdateStatus(status)
    }

    func popoverDidShow(_ notification: Notification) {
        settingsViewController.clearInitialFocus()
    }

    func popoverDidClose(_ notification: Notification) {
        endEscapeMonitoring()
        isPreviewHeldByHover = false
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
        previewPanel.orderOut(nil)
        anchorPanel.orderOut(nil)
        settingsViewController.stopRecording()
        onClose?()
    }

    private func beginEscapeMonitoring() {
        endEscapeMonitoring()

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else {
                return event
            }

            if self?.settingsViewController.isRecordingHotKey == true {
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

    private func showPreviewPanelTemporarily() {
        guard popover.isShown else {
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
        guard popover.isShown else {
            return
        }

        positionPreviewPanel()
        previewPanel.orderFront(nil)
    }

    private func hidePreviewPanel() {
        previewPanel.orderOut(nil)
        previewHideWorkItem = nil
    }

    private func positionPreviewPanel() {
        guard
            popover.isShown,
            let settingsWindow = settingsViewController.view.window
        else {
            return
        }

        let previewSize = ClipboardPreviewView.previewSize(for: settingsViewController.panelMetrics)
        settingsViewController.previewView.frame = NSRect(origin: .zero, size: previewSize)

        let settingsFrame = settingsWindow.frame
        let screen = settingsWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame.insetBy(dx: 8, dy: 8)

        let leftX = settingsFrame.minX - previewSize.width
        let rightX = settingsFrame.maxX
        let x: CGFloat

        if leftX >= visibleFrame.minX {
            x = leftX
        } else if rightX + previewSize.width <= visibleFrame.maxX {
            x = rightX
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

final class SettingsViewController: NSViewController {
    private enum ButtonRole {
        case primary
        case secondary
        case link
        case danger
    }

    let previewView = ClipboardPreviewView()
    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private let launchAtLoginSwitch = NSSwitch(frame: .zero)
    private let launchAtLoginStatusPill = SettingsPillView()
    private let autoUpdateSwitch = NSSwitch(frame: .zero)
    private let autoUpdateStatusPill = SettingsPillView()
    private let recordingHintLabel = NSTextField(labelWithString: "")
    private let scaleSlider = NSSlider()
    private let scaleValuePill = SettingsPillView()
    private let widthSlider = NSSlider()
    private let widthValuePill = SettingsPillView()
    private let lengthSlider = NSSlider()
    private let lengthValuePill = SettingsPillView()
    private let updateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let updateStatusLabel = NSTextField(labelWithString: "尚未检查更新。")
    private let versionPill = SettingsPillView()
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

        super.init(nibName: nil, bundle: nil)

        launchAtLoginSwitch.state = launchAtLoginEnabled ? .on : .off
        autoUpdateSwitch.state = autoUpdateEnabled ? .on : .off
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let rootView = SettingsRootView(frame: NSRect(x: 0, y: 0, width: 420, height: 640))
        rootView.material = .hudWindow
        rootView.blendingMode = .withinWindow
        rootView.state = .active
        rootView.appearance = NSAppearance(named: .darkAqua)
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 22
        rootView.layer?.masksToBounds = true
        view = rootView

        configureControls()

        let resetDisplayButton = makeActionButton(title: "恢复默认", symbolName: "arrow.counterclockwise", role: .secondary)
        resetDisplayButton.target = self
        resetDisplayButton.action = #selector(confirmResetPanelMetrics)

        let clipboardSection = makeSection(
            title: "剪贴板",
            symbolName: "clipboard",
            views: [
                makeSliderRow(title: "面板大小", slider: scaleSlider, valuePill: scaleValuePill),
                makeSliderRow(title: "面板宽度", slider: widthSlider, valuePill: widthValuePill),
                makeSliderRow(title: "显示行数", slider: lengthSlider, valuePill: lengthValuePill),
                makeHistoryLimitRow()
            ],
            trailingView: resetDisplayButton,
            onHoverChange: { [weak self] isHovering in
                self?.onDisplayHoverChange?(isHovering)
            }
        )

        let behaviorSection = makeSection(
            title: "行为",
            symbolName: "switch.2",
            views: [
                makeSettingsRow(title: "快捷键", control: shortcutButton),
                makeSettingsRow(title: "开机启动", control: makeHorizontalControls([launchAtLoginStatusPill, launchAtLoginSwitch])),
                makeSettingsRow(title: "自动检查更新", control: makeHorizontalControls([autoUpdateStatusPill, autoUpdateSwitch])),
                recordingHintLabel
            ]
        )

        let clearButton = makeActionButton(title: "清空...", symbolName: "trash", role: .danger)
        clearButton.target = self
        clearButton.action = #selector(confirmClearHistory)

        let actionsSection = makeSection(
            title: "操作",
            symbolName: "slider.horizontal.3",
            views: [
                makeSettingsRow(title: "清空历史", control: clearButton)
            ]
        )

        versionPill.setText(appVersionString, style: .neutral)

        let githubButton = makeActionButton(title: "GitHub", symbolName: "arrow.up.right.square", role: .link)
        githubButton.target = self
        githubButton.action = #selector(openGitHub)

        let permissionButton = makeActionButton(title: "辅助功能", symbolName: "accessibility", role: .secondary)
        permissionButton.target = self
        permissionButton.action = #selector(openAccessibility)

        configureActionButton(updateButton, title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary)
        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)

        let aboutSection = makeSection(
            title: "关于",
            symbolName: "info.circle",
            views: [
                makeSettingsRow(title: "当前版本", control: makeHorizontalControls([versionPill, updateButton])),
                makeSettingsRow(title: "项目主页", control: githubButton),
                makeSettingsRow(title: "系统权限", control: permissionButton),
                updateStatusLabel
            ]
        )

        let contentStack = NSStackView(views: [
            makeHeaderView(),
            clipboardSection,
            behaviorSection,
            actionsSection,
            aboutSection
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentStack)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = contentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),

            clipboardSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            behaviorSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            actionsSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            aboutSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])

        updatePanelMetrics(currentPanelMetrics)
        updateHotKey(currentHotKey)
        updateMaxHistoryItems(currentMaxHistoryItems)
        updateLaunchAtLogin(launchAtLoginSwitch.state == .on)
        updateAutoUpdateState(autoUpdateSwitch.state == .on)
        updateUpdateStatus(currentUpdateStatus)
    }

    func clearInitialFocus() {
        view.window?.makeFirstResponder(view)
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
        scaleValuePill.setText("\(Int(round(metrics.scale * 100)))%", style: .accent)
        widthValuePill.setText("\(Int(round(metrics.width))) px", style: .neutral)
        lengthValuePill.setText(String(format: "%.1f 行", Double(metrics.visibleRows)), style: .neutral)
        previewView.metrics = metrics
    }

    func updateMaxHistoryItems(_ count: Int) {
        currentMaxHistoryItems = SettingsStore.clampedHistoryLimit(count)
        historyLimitField.stringValue = "\(currentMaxHistoryItems)"
        historyLimitStepper.integerValue = currentMaxHistoryItems
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginSwitch.state = enabled ? .on : .off
        launchAtLoginStatusPill.setText(enabled ? "已开启" : "未开启", style: enabled ? .success : .disabled)
    }

    func updateUpdateStatus(_ status: SoftwareUpdateStatus) {
        currentUpdateStatus = status

        switch status {
        case .idle:
            configureActionButton(updateButton, title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary)
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = "尚未检查更新。"
            updateStatusLabel.textColor = .secondaryLabelColor
        case .checking:
            configureActionButton(updateButton, title: "检查中", symbolName: "arrow.triangle.2.circlepath", role: .secondary)
            updateButton.isEnabled = false
            updateStatusLabel.stringValue = "正在检查 GitHub Release..."
            updateStatusLabel.textColor = .secondaryLabelColor
        case let .upToDate(version):
            configureActionButton(updateButton, title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary)
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = "已是最新版 \(version)。"
            updateStatusLabel.textColor = .systemGreen
        case let .available(version, _, _):
            configureActionButton(updateButton, title: "安装更新", symbolName: "arrow.down.circle", role: .primary)
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = "发现新版本 \(version)，点击安装更新。"
            updateStatusLabel.textColor = .controlAccentColor
        case let .installing(message):
            configureActionButton(updateButton, title: "安装中", symbolName: "arrow.down.circle", role: .secondary)
            updateButton.isEnabled = false
            updateStatusLabel.stringValue = message
            updateStatusLabel.textColor = .secondaryLabelColor
        case let .failed(message):
            configureActionButton(updateButton, title: "检查更新", symbolName: "arrow.triangle.2.circlepath", role: .primary)
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
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        }

        shortcutButton.bezelStyle = .rounded
        shortcutButton.controlSize = .regular
        shortcutButton.target = self
        shortcutButton.action = #selector(startRecording)
        shortcutButton.setButtonType(.momentaryPushIn)
        shortcutButton.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        shortcutButton.contentTintColor = .controlAccentColor
        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 102).isActive = true
        shortcutButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        recordingHintLabel.font = .systemFont(ofSize: 11, weight: .regular)
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
        historyLimitField.widthAnchor.constraint(equalToConstant: 62).isActive = true

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

        updateStatusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.lineBreakMode = .byWordWrapping
        updateStatusLabel.maximumNumberOfLines = 2
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
        autoUpdateStatusPill.setText(enabled ? "已开启" : "未开启", style: enabled ? .success : .disabled)
    }

    private func configureSlider(_ slider: NSSlider, min: Double, max: Double, action: Selector) {
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 156).isActive = true
    }

    private func makeHeaderView() -> NSView {
        let iconView = NSImageView(image: appIconImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.shadowColor = NSColor.black.cgColor
        iconView.layer?.shadowOpacity = 0.22
        iconView.layer?.shadowRadius = 8
        iconView.layer?.shadowOffset = CGSize(width: 0, height: -2)

        let titleLabel = label("GlobalClipboard", size: 18, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subtitleLabel = label("全局剪贴板历史 · \(appVersionString)", size: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let header = NSStackView(views: [iconView, textStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        header.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 58)
        ])

        return header
    }

    private func makeSliderRow(title: String, slider: NSSlider, valuePill: SettingsPillView) -> NSView {
        let controls = makeHorizontalControls([slider, valuePill], spacing: 10)
        return makeSettingsRow(title: title, control: controls)
    }

    private func makeHistoryLimitRow() -> NSView {
        let unitLabel = label("条", size: 12, weight: .regular)
        unitLabel.textColor = .secondaryLabelColor
        let controls = makeHorizontalControls([historyLimitField, unitLabel, historyLimitStepper], spacing: 6)
        return makeSettingsRow(title: "历史上限", control: controls)
    }

    private func makeSettingsRow(title: String, control: NSView) -> NSView {
        let titleLabel = label(title, size: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [titleLabel, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        return row
    }

    private func makeHorizontalControls(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    private func makeSection(
        title: String,
        symbolName: String,
        views: [NSView],
        trailingView: NSView? = nil,
        onHoverChange: ((Bool) -> Void)? = nil
    ) -> SettingsSectionView {
        SettingsSectionView(
            title: title,
            symbolName: symbolName,
            views: views,
            trailingView: trailingView,
            onHoverChange: onHoverChange
        )
    }

    private func makeActionButton(title: String, symbolName: String, role: ButtonRole) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        configureActionButton(button, title: title, symbolName: symbolName, role: role)
        return button
    }

    private func configureActionButton(_ button: NSButton, title: String, symbolName: String, role: ButtonRole) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: role == .primary ? .semibold : .regular)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false
        if !button.constraints.contains(where: { $0.firstAttribute == .height }) {
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }

        switch role {
        case .primary:
            button.contentTintColor = .controlAccentColor
        case .secondary:
            button.contentTintColor = .secondaryLabelColor
        case .link:
            button.contentTintColor = .controlAccentColor.withAlphaComponent(0.9)
        case .danger:
            button.contentTintColor = .systemRed
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }

    private func appIconImage() -> NSImage {
        if
            let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
            let image = NSImage(contentsOfFile: path)
        {
            return image
        }

        return NSApp.applicationIconImage
    }

    private func label(_ title: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

final class SettingsSectionView: HoverTrackingView {
    init(
        title: String,
        symbolName: String,
        views: [NSView],
        trailingView: NSView?,
        onHoverChange: ((Bool) -> Void)?
    ) {
        super.init(frame: .zero)

        self.onHoverChange = onHoverChange
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.075).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor

        let symbol = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: title) ?? NSImage())
        symbol.imageScaling = .scaleProportionallyDown
        symbol.contentTintColor = .secondaryLabelColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerViews: [NSView] = trailingView == nil
            ? [symbol, titleLabel, headerSpacer]
            : [symbol, titleLabel, headerSpacer, trailingView!]
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false

        let bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 9
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        views.forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            bodyStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: [header, bodyStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 15),
            symbol.heightAnchor.constraint(equalToConstant: 15),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class SettingsPillView: NSView {
    enum Style {
        case neutral
        case accent
        case success
        case disabled
    }

    private let textLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true

        textLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        textLabel.alignment = .center
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 22)
        ])

        setText("", style: .neutral)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = textLabel.intrinsicContentSize
        return NSSize(width: max(48, labelSize.width + 16), height: 22)
    }

    func setText(_ text: String, style: Style) {
        textLabel.stringValue = text

        switch style {
        case .neutral:
            textLabel.textColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        case .accent:
            textLabel.textColor = .controlAccentColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        case .success:
            textLabel.textColor = .systemGreen
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
        case .disabled:
            textLabel.textColor = .tertiaryLabelColor
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        }

        invalidateIntrinsicContentSize()
    }
}

final class SettingsRootView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool {
        true
    }
}

class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            setHovering(false)
        }
    }

    private func setHovering(_ value: Bool) {
        guard isHovering != value else {
            return
        }

        isHovering = value
        onHoverChange?(value)
    }
}

final class ClipboardPreviewView: NSView {
    private struct PreviewSample {
        let item: ClipboardItem
        let thumbnail: NSImage?
    }

    var metrics: HistoryPanelMetrics = .default {
        didSet {
            updatePreview()
        }
    }

    private let previewHost = NSView()
    private let panelView = NSVisualEffectView()
    private let headerStack = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "剪贴板历史")
    private let hintLabel = NSTextField(labelWithString: "↑↓ 选择 · Enter 粘贴 · Esc 关闭")
    private let settingsButton = NSButton()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewHost.wantsLayer = true
        previewHost.layer?.masksToBounds = true

        panelView.material = .popover
        panelView.blendingMode = .withinWindow
        panelView.state = .active
        panelView.wantsLayer = true
        panelView.alphaValue = 0.85
        panelView.layer?.cornerRadius = 10
        panelView.layer?.masksToBounds = true
        panelView.layer?.borderWidth = 1
        panelView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor

        headerStack.orientation = .vertical
        headerStack.spacing = 2
        headerStack.alignment = .leading
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        headerStack.addArrangedSubview(headerLabel)
        headerStack.addArrangedSubview(hintLabel)

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        settingsButton.bezelStyle = .regularSquare
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        previewHost.addSubview(panelView)
        panelView.addSubview(headerStack)
        panelView.addSubview(settingsButton)
        panelView.addSubview(scrollView)
        addSubview(previewHost)

        NSLayoutConstraint.activate([
            previewHost.topAnchor.constraint(equalTo: topAnchor),
            previewHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewHost.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -10),

            settingsButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -10),
            settingsButton.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -8),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        updatePreview()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layoutPreviewPanel()
    }

    static func previewSize(for metrics: HistoryPanelMetrics) -> NSSize {
        let contentHeight = metrics.visibleRows * metrics.rowHeight
            + max(0, metrics.visibleRows - 1) * metrics.rowSpacing
        return NSSize(width: metrics.panelWidth, height: 58 + contentHeight + 12)
    }

    private func updatePreview() {
        headerLabel.font = .systemFont(ofSize: metrics.headerFontSize, weight: .semibold)
        headerLabel.textColor = .labelColor
        hintLabel.font = .systemFont(ofSize: metrics.hintFontSize)
        hintLabel.textColor = .secondaryLabelColor
        stackView.spacing = metrics.rowSpacing
        renderRows()
        layoutPreviewPanel()
    }

    private func layoutPreviewPanel() {
        guard previewHost.bounds.width > 0, previewHost.bounds.height > 0 else {
            return
        }

        let modelSize = Self.previewSize(for: metrics)
        let scale = min(previewHost.bounds.width / modelSize.width, previewHost.bounds.height / modelSize.height)
        let drawSize = NSSize(width: modelSize.width * scale, height: modelSize.height * scale)
        panelView.frame = NSRect(
            x: (previewHost.bounds.width - drawSize.width) / 2,
            y: (previewHost.bounds.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        panelView.bounds = NSRect(origin: .zero, size: modelSize)
        panelView.layer?.cornerRadius = max(5, 10 * scale)
        panelView.layoutSubtreeIfNeeded()
    }

    private func renderRows() {
        let rowCount = max(1, Int(ceil(metrics.visibleRows)))
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let samples = previewSamples(rowCount: rowCount)
        for (index, sample) in samples.enumerated() {
            let row = HistoryRowView(item: sample.item, thumbnail: sample.thumbnail, metrics: metrics) {}
            row.isSelected = index == 0
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
    }

    private func previewSamples(rowCount: Int) -> [PreviewSample] {
        let imagePayload = ImagePayload(
            fileName: "preview.png",
            pixelWidth: 1440,
            pixelHeight: 900,
            digest: "preview"
        )
        let baseSamples = [
            PreviewSample(
                item: ClipboardItem(text: "刚复制的一段比较长的文字会在这里展示，最多三行，超出的部分会自然省略。"),
                thumbnail: nil
            ),
            PreviewSample(
                item: ClipboardItem(text: "https://github.com/Rainchen537/global-clipboard"),
                thumbnail: nil
            ),
            PreviewSample(
                item: ClipboardItem(kind: .image(imagePayload), createdAt: Date()),
                thumbnail: Self.previewThumbnail()
            ),
            PreviewSample(
                item: ClipboardItem(text: "会议记录：确认快捷键、历史数量上限和自动更新状态展示。"),
                thumbnail: nil
            )
        ]

        return (0..<rowCount).map { baseSamples[$0 % baseSamples.count] }
    }

    private static func previewThumbnail() -> NSImage {
        let size = NSSize(width: 180, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).fill()
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        let border = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1), xRadius: 14, yRadius: 14)
        border.lineWidth = 1
        border.stroke()
        if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) {
            symbol.draw(
                in: NSRect(x: 66, y: 36, width: 48, height: 48),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.55
            )
        }
        image.unlockFocus()
        return image
    }
}
