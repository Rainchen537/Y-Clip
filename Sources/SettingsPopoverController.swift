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

        popover.contentSize = NSSize(width: 432, height: 520)
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
    let previewView = ClipboardPreviewView()
    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "开机自启动", target: nil, action: nil)
    private let autoUpdateButton = NSButton(checkboxWithTitle: "自动检查更新", target: nil, action: nil)
    private let recordingHintLabel = NSTextField(labelWithString: "")
    private let scaleSlider = NSSlider()
    private let scaleValueLabel = NSTextField(labelWithString: "")
    private let widthSlider = NSSlider()
    private let widthValueLabel = NSTextField(labelWithString: "")
    private let lengthSlider = NSSlider()
    private let lengthValueLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let updateStatusLabel = NSTextField(labelWithString: " ")
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

        launchAtLoginButton.state = launchAtLoginEnabled ? .on : .off
        autoUpdateButton.state = autoUpdateEnabled ? .on : .off
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let rootView = SettingsRootView(frame: NSRect(x: 0, y: 0, width: 432, height: 520))
        rootView.material = .popover
        rootView.blendingMode = .withinWindow
        rootView.state = .active
        view = rootView

        let titleLabel = NSTextField(labelWithString: "全局剪切板")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: "调整呼出面板、快捷键和启动行为")
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        titleStack.alignment = .leading

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
        updatePanelMetrics(currentPanelMetrics)

        let resetDisplayButton = makeInlineCommandButton(title: "恢复默认", symbolName: "arrow.counterclockwise")
        resetDisplayButton.target = self
        resetDisplayButton.action = #selector(confirmResetPanelMetrics)

        let displaySection = makeSection(
            title: "显示",
            views: [
                makeSliderRow(title: "大小", slider: scaleSlider, valueLabel: scaleValueLabel),
                makeSliderRow(title: "宽度", slider: widthSlider, valueLabel: widthValueLabel),
                makeSliderRow(title: "长度", slider: lengthSlider, valueLabel: lengthValueLabel)
            ],
            trailingView: resetDisplayButton,
            onHoverChange: { [weak self] isHovering in
                self?.onDisplayHoverChange?(isHovering)
            }
        )

        let shortcutTitleLabel = NSTextField(labelWithString: "快捷键")
        shortcutTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        shortcutButton.bezelStyle = .rounded
        shortcutButton.target = self
        shortcutButton.action = #selector(startRecording)
        shortcutButton.setButtonType(.momentaryPushIn)
        shortcutButton.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        shortcutButton.contentTintColor = .controlAccentColor
        updateHotKey(currentHotKey)

        recordingHintLabel.font = .systemFont(ofSize: 11)
        recordingHintLabel.textColor = .secondaryLabelColor
        recordingHintLabel.stringValue = " "

        let shortcutRow = NSStackView(views: [shortcutTitleLabel, shortcutButton])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.distribution = .gravityAreas
        shortcutRow.spacing = 12

        historyLimitField.alignment = .right
        historyLimitField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        historyLimitField.target = self
        historyLimitField.action = #selector(commitHistoryLimit)

        historyLimitStepper.minValue = Double(SettingsStore.allowedHistoryRange.lowerBound)
        historyLimitStepper.maxValue = Double(SettingsStore.allowedHistoryRange.upperBound)
        historyLimitStepper.increment = 1
        historyLimitStepper.target = self
        historyLimitStepper.action = #selector(stepHistoryLimit)
        updateMaxHistoryItems(currentMaxHistoryItems)

        let historyLimitControls = NSStackView(views: [historyLimitField, historyLimitStepper])
        historyLimitControls.orientation = .horizontal
        historyLimitControls.alignment = .centerY
        historyLimitControls.spacing = 6

        let historyLimitRow = NSStackView(views: [
            label("历史上限", weight: .medium),
            historyLimitControls
        ])
        historyLimitRow.orientation = .horizontal
        historyLimitRow.alignment = .centerY
        historyLimitRow.distribution = .gravityAreas
        historyLimitRow.spacing = 12

        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin)

        autoUpdateButton.target = self
        autoUpdateButton.action = #selector(toggleAutoUpdate)

        let behaviorSection = makeSection(
            title: "行为",
            views: [
                launchAtLoginButton,
                autoUpdateButton,
                shortcutRow,
                recordingHintLabel,
                historyLimitRow
            ]
        )

        let clearButton = makeCommandButton(title: "清空历史", symbolName: "trash")
        clearButton.target = self
        clearButton.action = #selector(clearHistory)

        let permissionButton = makeCommandButton(title: "辅助功能", symbolName: "accessibility")
        permissionButton.target = self
        permissionButton.action = #selector(openAccessibility)

        let githubButton = makeCommandButton(title: "GitHub", symbolName: "link")
        githubButton.target = self
        githubButton.action = #selector(openGitHub)

        configureCommandButton(updateButton, title: "检查更新", symbolName: "arrow.triangle.2.circlepath")
        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)

        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.lineBreakMode = .byTruncatingTail
        updateStatusLabel.maximumNumberOfLines = 2

        let commandGrid = NSGridView(views: [
            [clearButton, permissionButton],
            [githubButton, updateButton]
        ])
        commandGrid.rowSpacing = 8
        commandGrid.columnSpacing = 8
        for columnIndex in 0..<2 {
            commandGrid.column(at: columnIndex).xPlacement = .fill
        }

        let actionsSection = makeSection(title: "操作", views: [commandGrid, updateStatusLabel])

        let controlsStack = NSStackView(views: [
            titleStack,
            displaySection,
            behaviorSection,
            actionsSection
        ])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 12

        let rootStack = NSStackView(views: [controlsStack])
        rootStack.orientation = .vertical
        rootStack.alignment = .top
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18),

            controlsStack.widthAnchor.constraint(equalToConstant: 396),
            displaySection.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            behaviorSection.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            actionsSection.widthAnchor.constraint(equalTo: controlsStack.widthAnchor),
            shortcutRow.widthAnchor.constraint(equalTo: behaviorSection.widthAnchor, constant: -28),
            shortcutButton.widthAnchor.constraint(equalToConstant: 122),
            historyLimitRow.widthAnchor.constraint(equalTo: behaviorSection.widthAnchor, constant: -28),
            historyLimitField.widthAnchor.constraint(equalToConstant: 58),
            commandGrid.widthAnchor.constraint(equalTo: actionsSection.widthAnchor, constant: -28)
        ])
    }

    func clearInitialFocus() {
        view.window?.makeFirstResponder(view)
        historyLimitField.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
    }

    func updateHotKey(_ hotKey: HotKey) {
        currentHotKey = hotKey
        shortcutButton.title = hotKey.displayName
        recordingHintLabel.stringValue = " "
    }

    func updatePanelMetrics(_ metrics: HistoryPanelMetrics) {
        currentPanelMetrics = metrics
        scaleSlider.doubleValue = Double(metrics.scale)
        widthSlider.doubleValue = Double(metrics.width)
        lengthSlider.doubleValue = Double(metrics.visibleRows)
        scaleValueLabel.stringValue = "\(Int(round(metrics.scale * 100)))%"
        widthValueLabel.stringValue = "\(Int(round(metrics.width)))"
        lengthValueLabel.stringValue = String(format: "%.1f 行", Double(metrics.visibleRows))
        previewView.metrics = metrics
    }

    func updateMaxHistoryItems(_ count: Int) {
        currentMaxHistoryItems = SettingsStore.clampedHistoryLimit(count)
        historyLimitField.stringValue = "\(currentMaxHistoryItems)"
        historyLimitStepper.integerValue = currentMaxHistoryItems
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginButton.state = enabled ? .on : .off
    }

    func updateUpdateStatus(_ status: SoftwareUpdateStatus) {
        currentUpdateStatus = status

        switch status {
        case .idle:
            updateButton.title = "检查更新"
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = " "
            updateStatusLabel.textColor = .secondaryLabelColor
        case .checking:
            updateButton.title = "检查中"
            updateButton.isEnabled = false
            updateStatusLabel.stringValue = "正在检查 GitHub Release…"
            updateStatusLabel.textColor = .secondaryLabelColor
        case let .upToDate(version):
            updateButton.title = "检查更新"
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = "已是最新版 \(version)"
            updateStatusLabel.textColor = .secondaryLabelColor
        case let .available(version, _, _):
            updateButton.title = "安装更新"
            updateButton.isEnabled = true
            updateStatusLabel.stringValue = "发现新版本 \(version)，点击安装更新。"
            updateStatusLabel.textColor = .controlAccentColor
        case let .installing(message):
            updateButton.title = "安装中"
            updateButton.isEnabled = false
            updateStatusLabel.stringValue = message
            updateStatusLabel.textColor = .secondaryLabelColor
        case let .failed(message):
            updateButton.title = "检查更新"
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
        recordingHintLabel.stringValue = " "
    }

    @objc private func toggleLaunchAtLogin() {
        onLaunchAtLoginChange(launchAtLoginButton.state == .on)
    }

    @objc private func toggleAutoUpdate() {
        onAutoUpdateChange(autoUpdateButton.state == .on)
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
        alert.informativeText = "大小、宽度和长度会恢复到默认值。"
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

        if localKeyMonitor != nil {
            return
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    @objc private func clearHistory() {
        onClearHistory()
    }

    @objc private func openAccessibility() {
        onOpenAccessibility()
    }

    @objc private func openGitHub() {
        onOpenGitHub()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        guard let hotKey = HotKey(event: event) else {
            recordingHintLabel.stringValue = "请至少包含一个修饰键"
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

    private func configureSlider(_ slider: NSSlider, min: Double, max: Double, action: Selector) {
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 185).isActive = true
    }

    private func makeSliderRow(title: String, slider: NSSlider, valueLabel: NSTextField) -> NSView {
        let titleLabel = label(title, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true

        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func makeSection(
        title: String,
        views: [NSView],
        trailingView: NSView? = nil,
        onHoverChange: ((Bool) -> Void)? = nil
    ) -> NSView {
        let titleLabel = label(title, weight: .semibold)
        titleLabel.textColor = .labelColor

        let headerRow = NSStackView(views: [titleLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        if let trailingView {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerRow.addArrangedSubview(spacer)
            headerRow.addArrangedSubview(trailingView)
        }

        let stack = NSStackView(views: [headerRow] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container: NSView
        if let onHoverChange {
            let hoverContainer = HoverTrackingView()
            hoverContainer.onHoverChange = onHoverChange
            container = hoverContainer
        } else {
            container = NSView()
        }
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.62).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return container
    }

    private func makeCommandButton(title: String, symbolName: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        configureCommandButton(button, title: title, symbolName: symbolName)
        return button
    }

    private func makeInlineCommandButton(title: String, symbolName: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func configureCommandButton(_ button: NSButton, title: String, symbolName: String) {
        button.title = title
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func label(_ title: String, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: weight)
        return label
    }
}

final class SettingsRootView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool {
        true
    }
}

final class HoverTrackingView: NSView {
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
