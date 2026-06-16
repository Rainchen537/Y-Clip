import AppKit
import Carbon

final class SettingsPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let settingsViewController: SettingsViewController

    init(
        hotKey: HotKey,
        panelMetrics: HistoryPanelMetrics,
        maxHistoryItems: Int,
        autoUpdateEnabled: Bool,
        launchAtLoginEnabled: Bool,
        onShowHistory: @escaping () -> Void,
        onClearHistory: @escaping () -> Void,
        onLaunchAtLoginChange: @escaping (Bool) -> Void,
        onHotKeyChange: @escaping (HotKey) -> Void,
        onPanelMetricsChange: @escaping (HistoryPanelMetrics) -> Void,
        onMaxHistoryItemsChange: @escaping (Int) -> Void,
        onAutoUpdateChange: @escaping (Bool) -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onOpenGitHub: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        settingsViewController = SettingsViewController(
            hotKey: hotKey,
            panelMetrics: panelMetrics,
            maxHistoryItems: maxHistoryItems,
            autoUpdateEnabled: autoUpdateEnabled,
            launchAtLoginEnabled: launchAtLoginEnabled,
            onShowHistory: onShowHistory,
            onClearHistory: onClearHistory,
            onLaunchAtLoginChange: onLaunchAtLoginChange,
            onHotKeyChange: onHotKeyChange,
            onPanelMetricsChange: onPanelMetricsChange,
            onMaxHistoryItemsChange: onMaxHistoryItemsChange,
            onAutoUpdateChange: onAutoUpdateChange,
            onCheckForUpdates: onCheckForUpdates,
            onOpenAccessibility: onOpenAccessibility,
            onOpenGitHub: onOpenGitHub,
            onQuit: onQuit
        )

        super.init()

        popover.contentSize = NSSize(width: 700, height: 520)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = settingsViewController
        popover.delegate = self
    }

    var isShown: Bool {
        popover.isShown
    }

    func show(relativeTo view: NSView, preferredEdge: NSRectEdge = .minY) {
        updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
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

    func popoverDidClose(_ notification: Notification) {
        settingsViewController.stopRecording()
    }
}

final class SettingsViewController: NSViewController {
    private let previewView = ClipboardPreviewView()
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
    private let historyLimitField = NSTextField(string: "")
    private let historyLimitStepper = NSStepper()
    private var localKeyMonitor: Any?
    private var currentHotKey: HotKey
    private var currentPanelMetrics: HistoryPanelMetrics
    private var currentMaxHistoryItems: Int
    private let onShowHistory: () -> Void
    private let onClearHistory: () -> Void
    private let onLaunchAtLoginChange: (Bool) -> Void
    private let onHotKeyChange: (HotKey) -> Void
    private let onPanelMetricsChange: (HistoryPanelMetrics) -> Void
    private let onMaxHistoryItemsChange: (Int) -> Void
    private let onAutoUpdateChange: (Bool) -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenAccessibility: () -> Void
    private let onOpenGitHub: () -> Void
    private let onQuit: () -> Void

    init(
        hotKey: HotKey,
        panelMetrics: HistoryPanelMetrics,
        maxHistoryItems: Int,
        autoUpdateEnabled: Bool,
        launchAtLoginEnabled: Bool,
        onShowHistory: @escaping () -> Void,
        onClearHistory: @escaping () -> Void,
        onLaunchAtLoginChange: @escaping (Bool) -> Void,
        onHotKeyChange: @escaping (HotKey) -> Void,
        onPanelMetricsChange: @escaping (HistoryPanelMetrics) -> Void,
        onMaxHistoryItemsChange: @escaping (Int) -> Void,
        onAutoUpdateChange: @escaping (Bool) -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onOpenGitHub: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        currentHotKey = hotKey
        currentPanelMetrics = panelMetrics
        currentMaxHistoryItems = SettingsStore.clampedHistoryLimit(maxHistoryItems)
        self.onShowHistory = onShowHistory
        self.onClearHistory = onClearHistory
        self.onLaunchAtLoginChange = onLaunchAtLoginChange
        self.onHotKeyChange = onHotKeyChange
        self.onPanelMetricsChange = onPanelMetricsChange
        self.onMaxHistoryItemsChange = onMaxHistoryItemsChange
        self.onAutoUpdateChange = onAutoUpdateChange
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenAccessibility = onOpenAccessibility
        self.onOpenGitHub = onOpenGitHub
        self.onQuit = onQuit

        super.init(nibName: nil, bundle: nil)

        launchAtLoginButton.state = launchAtLoginEnabled ? .on : .off
        autoUpdateButton.state = autoUpdateEnabled ? .on : .off
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let rootView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
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

        previewView.metrics = currentPanelMetrics
        previewView.translatesAutoresizingMaskIntoConstraints = false

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

        let displaySection = makeSection(
            title: "显示",
            views: [
                makeSliderRow(title: "大小", slider: scaleSlider, valueLabel: scaleValueLabel),
                makeSliderRow(title: "宽度", slider: widthSlider, valueLabel: widthValueLabel),
                makeSliderRow(title: "长度", slider: lengthSlider, valueLabel: lengthValueLabel)
            ]
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

        let checkUpdateButton = makeCommandButton(title: "检查更新", symbolName: "arrow.triangle.2.circlepath")
        checkUpdateButton.target = self
        checkUpdateButton.action = #selector(checkForUpdates)

        let behaviorSection = makeSection(
            title: "行为",
            views: [
                launchAtLoginButton,
                autoUpdateButton,
                checkUpdateButton,
                shortcutRow,
                recordingHintLabel,
                historyLimitRow
            ]
        )

        let showHistoryButton = makeCommandButton(title: "显示历史", symbolName: "list.bullet.clipboard")
        showHistoryButton.target = self
        showHistoryButton.action = #selector(showHistory)

        let clearButton = makeCommandButton(title: "清空历史", symbolName: "trash")
        clearButton.target = self
        clearButton.action = #selector(clearHistory)

        let permissionButton = makeCommandButton(title: "辅助功能", symbolName: "accessibility")
        permissionButton.target = self
        permissionButton.action = #selector(openAccessibility)

        let githubButton = makeCommandButton(title: "GitHub", symbolName: "link")
        githubButton.target = self
        githubButton.action = #selector(openGitHub)

        let quitButton = makeCommandButton(title: "退出", symbolName: "power")
        quitButton.target = self
        quitButton.action = #selector(quit)

        let commandGrid = NSGridView(views: [
            [showHistoryButton, clearButton],
            [permissionButton, githubButton],
            [quitButton, NSView()]
        ])
        commandGrid.rowSpacing = 8
        commandGrid.columnSpacing = 8
        for columnIndex in 0..<2 {
            commandGrid.column(at: columnIndex).xPlacement = .fill
        }

        let actionsSection = makeSection(title: "操作", views: [commandGrid])

        let controlsStack = NSStackView(views: [
            titleStack,
            displaySection,
            behaviorSection,
            actionsSection
        ])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 12

        let rootStack = NSStackView(views: [previewView, controlsStack])
        rootStack.orientation = .horizontal
        rootStack.alignment = .top
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18),

            previewView.widthAnchor.constraint(equalToConstant: 250),
            previewView.heightAnchor.constraint(equalToConstant: 480),

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
        onCheckForUpdates()
    }

    @objc private func changePanelMetrics() {
        let metrics = HistoryPanelMetrics(
            scale: CGFloat(scaleSlider.doubleValue),
            width: CGFloat(widthSlider.doubleValue),
            visibleRows: CGFloat(lengthSlider.doubleValue)
        )
        updatePanelMetrics(metrics)
        onPanelMetricsChange(metrics)
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

    @objc private func showHistory() {
        onShowHistory()
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

    @objc private func quit() {
        onQuit()
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

    private func makeSection(title: String, views: [NSView]) -> NSView {
        let titleLabel = label(title, weight: .semibold)
        titleLabel.textColor = .labelColor

        let stack = NSStackView(views: [titleLabel] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
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
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        return container
    }

    private func makeCommandButton(title: String, symbolName: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func label(_ title: String, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: weight)
        return label
    }
}

final class ClipboardPreviewView: NSView {
    var metrics: HistoryPanelMetrics = .default {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.windowBackgroundColor.withAlphaComponent(0.34).setFill()
        bounds.fill()

        let title = NSAttributedString(
            string: "实时预览",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        title.draw(at: NSPoint(x: 16, y: bounds.maxY - 32))

        let panelHeight = metrics.headerHeight
            + metrics.visibleRows * metrics.rowHeight
            + max(0, metrics.visibleRows - 1) * metrics.rowSpacing
            + 12
        let modelSize = NSSize(width: metrics.panelWidth, height: panelHeight)
        let scale = min((bounds.width - 32) / modelSize.width, (bounds.height - 72) / modelSize.height)
        let drawSize = NSSize(width: modelSize.width * scale, height: modelSize.height * scale)
        let origin = NSPoint(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2 - 8
        )
        let panelRect = NSRect(origin: origin, size: drawSize)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.set()

        let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.withAlphaComponent(0.70).setFill()
        panelPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        let headerRect = NSRect(
            x: panelRect.minX + 14 * scale,
            y: panelRect.maxY - 34 * scale,
            width: panelRect.width - 48 * scale,
            height: 16 * scale
        )
        drawTextBlock(in: headerRect, widthRatio: 0.46, alpha: 0.42)
        drawGear(in: NSRect(
            x: panelRect.maxX - 30 * scale,
            y: panelRect.maxY - 32 * scale,
            width: 16 * scale,
            height: 16 * scale
        ))

        var rowY = panelRect.maxY - metrics.headerHeight * scale - metrics.rowHeight * scale
        for index in 0..<Int(round(metrics.visibleRows)) {
            let rowRect = NSRect(
                x: panelRect.minX + 8 * scale,
                y: rowY,
                width: panelRect.width - 16 * scale,
                height: metrics.rowHeight * scale
            )
            let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: 8 * scale, yRadius: 8 * scale)
            NSColor.labelColor.withAlphaComponent(index == 0 ? 0.10 : 0.055).setFill()
            rowPath.fill()

            let textRect = rowRect.insetBy(dx: metrics.contentInset * scale, dy: 12 * scale)
            drawTextBlock(in: textRect, widthRatio: index == 1 ? 0.72 : 0.88, alpha: 0.28)
            rowY -= (metrics.rowHeight + metrics.rowSpacing) * scale
        }
    }

    private func drawTextBlock(in rect: NSRect, widthRatio: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width * widthRatio, height: 6),
            xRadius: 3,
            yRadius: 3
        )
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    private func drawGear(in rect: NSRect) {
        guard let image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) else {
            return
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.28)
    }
}
