import AppKit
import Carbon

final class SettingsWindowController: NSObject {
    private enum PreviewPlacement {
        case left
        case right
        case above
        case below
    }

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
        if ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW"] == "1" {
            panel.sharingType = .readOnly
        }
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }()
    private var previewHideWorkItem: DispatchWorkItem?
    private var isPreviewHeldByHover = false
    private var isFeaturesSelected = false
    private var escapeMonitor: Any?
    private var windowMoveObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var settingsMinimumSizeBeforePreview: NSSize?
    private var settingsMaximumSizeBeforePreview: NSSize?
    private var hasAutomaticallyArrangedPreviewPair = false

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
        onResetAccessibility: @escaping (@escaping (AccessibilityRepairResult) -> Void) -> Void,
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
            onResetAccessibility: onResetAccessibility,
            onOpenGitHub: onOpenGitHub
        )

        let descriptor = YSettingAppDescriptor(
            displayName: "Y-Clip",
            subtitle: "全局剪贴板历史",
            version: YSettingUI.appVersionString(),
            icon: YSettingUI.bundledAppIcon()
        )
        let items = YSettingStandardSidebar.all
        let contentController = settingsContentController
        windowController = YSettingWindowController(
            descriptor: descriptor,
            sidebarItems: items,
            initialIdentifier: "general"
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
        settingsContentController.onContentSelection = { [weak self] identifier in
            guard let self else { return }
            isFeaturesSelected = identifier == YSettingStandardSidebar.features.identifier
            if isFeaturesSelected {
                showPreviewPanel()
            } else {
                previewHideWorkItem?.cancel()
                previewHideWorkItem = nil
                hidePreviewPanel()
                restoreSettingsSizingAfterPreview()
            }
        }
        windowController.onClose = { [weak self] in
            self?.handleWindowClosed()
        }
    }

    deinit {
        endEscapeMonitoring()
        removeWindowObservers()
        removeApplicationActivationObserver()
    }

    var isShown: Bool {
        windowController.isVisible
    }

    func show() {
        settingsContentController.refreshForPresentation()
        updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
        windowController.showAndActivate()
        settingsContentController.clearInitialFocus(in: windowController.window)
        beginEscapeMonitoring()
        installWindowObserversIfNeeded()
        installApplicationActivationObserverIfNeeded()
        if isFeaturesSelected {
            showPreviewPanel()
        }
    }

    func selectItem(_ identifier: String) {
        windowController.selectItem(identifier)
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
        removeApplicationActivationObserver()
        isPreviewHeldByHover = false
        previewHideWorkItem?.cancel()
        previewHideWorkItem = nil
        previewPanel.orderOut(nil)
        restoreSettingsSizingAfterPreview()
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

    private func installApplicationActivationObserverIfNeeded() {
        guard applicationActivationObserver == nil else {
            return
        }

        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, windowController.isVisible else {
                return
            }

            settingsContentController.refreshForPresentation()
            if isFeaturesSelected {
                showPreviewPanel()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        if let applicationActivationObserver {
            NotificationCenter.default.removeObserver(applicationActivationObserver)
        }
        applicationActivationObserver = nil
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
            guard let self, !isPreviewHeldByHover, !isFeaturesSelected else {
                return
            }

            hidePreviewPanel()
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
                guard let self, !isPreviewHeldByHover, !isFeaturesSelected else {
                    return
                }

                hidePreviewPanel()
            }
            previewHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }
    }

    private func showPreviewPanel() {
        guard windowController.isVisible else {
            return
        }

        prepareSettingsWindowForPreview()
        guard positionPreviewPanel() else {
            return
        }
        previewPanel.orderFront(nil)
        capturePreviewPanelIfRequested()
    }

    private func capturePreviewPanelIfRequested() {
        guard
            let outputPath = ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW_OUTPUT"],
            !outputPath.isEmpty
        else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let view = self?.previewPanel.contentView else { return }
            let bounds = view.bounds
            guard let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                return
            }
            view.cacheDisplay(in: bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                return
            }
            let outputURL = URL(fileURLWithPath: outputPath)
            let sidecarURL = outputURL.deletingPathExtension()
                .appendingPathExtension("sidecar.png")
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }

    private func hidePreviewPanel() {
        previewPanel.orderOut(nil)
        previewHideWorkItem = nil
    }

    private func positionPreviewPanelIfVisible() {
        guard previewPanel.isVisible else {
            return
        }

        _ = positionPreviewPanel()
    }

    private func prepareSettingsWindowForPreview() {
        guard let settingsWindow = windowController.window else {
            return
        }

        let screen = settingsWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let gap: CGFloat = 12
        let modelSize = ClipboardPreviewView.previewSize(for: settingsContentController.panelMetrics)
        let targetSettingsWidth = min(700, visibleFrame.width * 0.72)
        let maximumPreviewSize = NSSize(
            width: max(1, visibleFrame.width - targetSettingsWidth - gap),
            height: max(1, visibleFrame.height)
        )
        let previewScale = max(0.01, min(
            1,
            maximumPreviewSize.width / modelSize.width,
            maximumPreviewSize.height / modelSize.height
        ))
        let reservedPreviewWidth = floor(modelSize.width * previewScale)
        let maximumSettingsSize = NSSize(
            width: max(1, visibleFrame.width - reservedPreviewWidth - gap),
            height: max(1, visibleFrame.height)
        )

        if settingsMinimumSizeBeforePreview == nil {
            settingsMinimumSizeBeforePreview = settingsWindow.minSize
            settingsMaximumSizeBeforePreview = settingsWindow.maxSize
        }

        let originalMinimumSize = settingsMinimumSizeBeforePreview ?? settingsWindow.minSize
        let originalMaximumSize = settingsMaximumSizeBeforePreview ?? settingsWindow.maxSize
        settingsWindow.minSize = NSSize(
            width: min(originalMinimumSize.width, maximumSettingsSize.width),
            height: min(originalMinimumSize.height, maximumSettingsSize.height)
        )
        settingsWindow.maxSize = NSSize(
            width: min(originalMaximumSize.width, maximumSettingsSize.width),
            height: min(originalMaximumSize.height, maximumSettingsSize.height)
        )

        var settingsFrame = settingsWindow.frame
        let originalCenter = NSPoint(x: settingsFrame.midX, y: settingsFrame.midY)
        settingsFrame.size.width = min(settingsFrame.width, maximumSettingsSize.width)
        settingsFrame.size.height = min(settingsFrame.height, maximumSettingsSize.height)

        if hasAutomaticallyArrangedPreviewPair {
            settingsFrame.origin = NSPoint(
                x: originalCenter.x - settingsFrame.width / 2,
                y: originalCenter.y - settingsFrame.height / 2
            )
            settingsFrame.origin.x = clamp(
                settingsFrame.origin.x,
                lower: visibleFrame.minX,
                upper: visibleFrame.maxX - settingsFrame.width
            )
        } else {
            let combinedWidth = settingsFrame.width + gap + reservedPreviewWidth
            settingsFrame.origin.x = clamp(
                visibleFrame.midX - combinedWidth / 2,
                lower: visibleFrame.minX,
                upper: visibleFrame.maxX - combinedWidth
            )
            hasAutomaticallyArrangedPreviewPair = true
        }
        settingsFrame.origin.y = clamp(
            settingsFrame.origin.y,
            lower: visibleFrame.minY,
            upper: visibleFrame.maxY - settingsFrame.height
        )

        if settingsFrame != settingsWindow.frame {
            settingsWindow.setFrame(settingsFrame, display: true, animate: false)
        }
    }

    @discardableResult
    private func positionPreviewPanel() -> Bool {
        guard let settingsWindow = windowController.window else {
            return false
        }

        let screen = settingsWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let settingsFrame = settingsWindow.frame
        let gap: CGFloat = 12
        let modelSize = ClipboardPreviewView.previewSize(for: settingsContentController.panelMetrics)
        var bestPlacement = PreviewPlacement.right
        var bestScale: CGFloat = 0

        func consider(_ placement: PreviewPlacement, availableWidth: CGFloat, availableHeight: CGFloat) {
            guard availableWidth > 0, availableHeight > 0 else {
                return
            }

            let scale = min(1, availableWidth / modelSize.width, availableHeight / modelSize.height)
            if scale > bestScale {
                bestScale = scale
                bestPlacement = placement
            }
        }

        consider(
            .right,
            availableWidth: visibleFrame.maxX - settingsFrame.maxX - gap,
            availableHeight: visibleFrame.height
        )
        consider(
            .left,
            availableWidth: settingsFrame.minX - visibleFrame.minX - gap,
            availableHeight: visibleFrame.height
        )
        consider(
            .above,
            availableWidth: visibleFrame.width,
            availableHeight: visibleFrame.maxY - settingsFrame.maxY - gap
        )
        consider(
            .below,
            availableWidth: visibleFrame.width,
            availableHeight: settingsFrame.minY - visibleFrame.minY - gap
        )

        guard bestScale > 0 else {
            previewPanel.orderOut(nil)
            return false
        }

        let previewSize = NSSize(
            width: max(1, floor(modelSize.width * bestScale)),
            height: max(1, floor(modelSize.height * bestScale))
        )
        settingsContentController.previewView.frame = NSRect(origin: .zero, size: previewSize)

        let previewOrigin: NSPoint
        switch bestPlacement {
        case .right:
            previewOrigin = NSPoint(
                x: settingsFrame.maxX + gap,
                y: clamp(
                    settingsFrame.maxY - previewSize.height,
                    lower: visibleFrame.minY,
                    upper: visibleFrame.maxY - previewSize.height
                )
            )
        case .left:
            previewOrigin = NSPoint(
                x: settingsFrame.minX - gap - previewSize.width,
                y: clamp(
                    settingsFrame.maxY - previewSize.height,
                    lower: visibleFrame.minY,
                    upper: visibleFrame.maxY - previewSize.height
                )
            )
        case .above:
            previewOrigin = NSPoint(
                x: clamp(
                    settingsFrame.midX - previewSize.width / 2,
                    lower: visibleFrame.minX,
                    upper: visibleFrame.maxX - previewSize.width
                ),
                y: settingsFrame.maxY + gap
            )
        case .below:
            previewOrigin = NSPoint(
                x: clamp(
                    settingsFrame.midX - previewSize.width / 2,
                    lower: visibleFrame.minX,
                    upper: visibleFrame.maxX - previewSize.width
                ),
                y: settingsFrame.minY - gap - previewSize.height
            )
        }

        previewPanel.setFrame(NSRect(origin: previewOrigin, size: previewSize), display: true)
        return true
    }

    private func restoreSettingsSizingAfterPreview() {
        guard let settingsWindow = windowController.window else {
            settingsMinimumSizeBeforePreview = nil
            settingsMaximumSizeBeforePreview = nil
            return
        }

        if let settingsMinimumSizeBeforePreview {
            settingsWindow.minSize = settingsMinimumSizeBeforePreview
        }
        if let settingsMaximumSizeBeforePreview {
            settingsWindow.maxSize = settingsMaximumSizeBeforePreview
        }
        settingsMinimumSizeBeforePreview = nil
        settingsMaximumSizeBeforePreview = nil
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper >= lower else {
            return lower
        }
        return min(max(value, lower), upper)
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
    private let accessibilityStatusPill = YSettingPill(text: "检测中", tone: .neutral)
    private let runtimeIdentityPill = YSettingPill(text: "检测中", tone: .neutral)
    private lazy var requestAccessibilityButton = YSettingUI.makeButton(title: "请求", symbolName: "hand.raised", target: self, action: #selector(requestAccessibility))
    private lazy var openAccessibilityButton = YSettingUI.makeButton(title: "打开", symbolName: "gearshape", target: self, action: #selector(openAccessibility))
    private lazy var switchToInstalledButton = YSettingUI.makeButton(title: "切换到安装版", symbolName: "arrow.right.app", role: .primary, target: self, action: #selector(switchToInstalledCopy))
    private lazy var resetAccessibilityButton = YSettingUI.makeButton(title: "刷新记录", symbolName: "arrow.counterclockwise", target: self, action: #selector(resetAccessibility))
    private lazy var recheckAccessibilityButton = YSettingUI.makeButton(title: "重新检测", symbolName: "checkmark.shield", target: self, action: #selector(refreshAccessibilityStatus))
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
    private let onResetAccessibility: (@escaping (AccessibilityRepairResult) -> Void) -> Void
    private let onOpenGitHub: () -> Void
    var onPreviewAdjustment: (() -> Void)?
    var onDisplayHoverChange: ((Bool) -> Void)?
    var onContentSelection: ((String) -> Void)?
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
        onResetAccessibility: @escaping (@escaping (AccessibilityRepairResult) -> Void) -> Void,
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
        self.onResetAccessibility = onResetAccessibility
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
        refreshAccessibilityStatus()
    }

    func makeContent(for identifier: String) -> NSView {
        onContentSelection?(identifier)

        switch identifier {
        case "features":
            return featuresContent()
        case "permissions":
            return permissionsContent()
        case "updates":
            return updatesContent()
        case "about":
            return aboutContent()
        default:
            return generalContent()
        }
    }

    func refreshForPresentation() {
        refreshAccessibilityStatus()
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

    private func generalContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "通用",
            symbolName: "gearshape"
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "启动与快捷键",
            symbolName: "keyboard",
            views: [
                YSettingUI.row(title: "快捷键", trailingView: shortcutButton),
                YSettingUI.row(title: "开机启动", trailingView: YSettingUI.horizontal([launchAtLoginStatusPill, launchAtLoginSwitch])),
                recordingHintLabel
            ]
        ))

        return stack
    }

    private func featuresContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "功能",
            symbolName: "slider.horizontal.3"
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
                makeHistoryLimitRow(),
                YSettingUI.divider(),
                YSettingUI.row(title: "清空历史", trailingView: YSettingUI.makeButton(
                    title: "清空...",
                    symbolName: "trash",
                    role: .danger,
                    target: self,
                    action: #selector(confirmClearHistory)
                ))
            ],
            trailingView: resetButton,
            onHoverChange: { [weak self] isHovering in
                self?.onDisplayHoverChange?(isHovering)
            }
        ))

        return stack
    }

    private func permissionsContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "权限",
            symbolName: "lock.shield"
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "辅助功能",
            symbolName: "accessibility",
            views: [
                YSettingUI.row(
                    title: "当前副本",
                    trailingView: YSettingUI.horizontal([runtimeIdentityPill, switchToInstalledButton])
                ),
                YSettingUI.row(
                    title: "权限状态",
                    trailingView: YSettingUI.horizontal([accessibilityStatusPill, requestAccessibilityButton, openAccessibilityButton])
                ),
                YSettingUI.row(
                    title: "权限修复",
                    trailingView: YSettingUI.horizontal([resetAccessibilityButton, recheckAccessibilityButton])
                )
            ]
        ))

        return stack
    }

    private func updatesContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "更新",
            symbolName: "arrow.triangle.2.circlepath"
        )

        versionPill.setText(YSettingUI.appVersionString(), tone: .neutral)
        stack.addArrangedSubview(YSettingSectionView(
            title: "版本更新",
            symbolName: "sparkles",
            views: [
                YSettingUI.row(title: "当前版本", trailingView: YSettingUI.horizontal([versionPill, updateButton])),
                YSettingUI.row(title: "发布渠道", trailingView: YSettingPill(text: "GitHub Release", tone: .accent)),
                YSettingUI.row(title: "自动检查更新", trailingView: YSettingUI.horizontal([autoUpdateStatusPill, autoUpdateSwitch])),
                updateStatusLabel
            ]
        ))

        return stack
    }

    private func aboutContent() -> NSView {
        let stack = YSettingUI.makeContentStack(
            title: "关于",
            symbolName: "info.circle"
        )

        let githubButton = YSettingUI.makeButton(
            title: "GitHub",
            symbolName: "arrow.up.right.square",
            role: .link,
            target: self,
            action: #selector(openGitHub)
        )

        stack.addArrangedSubview(YSettingSectionView(
            title: "Y-Project",
            symbolName: "app.connected.to.app.below.fill",
            views: [
                YSettingUI.row(title: "产品定位", trailingView: YSettingPill(text: "全局剪贴板历史", tone: .accent)),
                YSettingUI.row(title: "项目主页", trailingView: githubButton)
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
        refreshAccessibilityStatus()
    }

    @objc private func requestAccessibility() {
        AccessibilityPermission.requestPrompt()
        refreshAccessibilityStatus()
    }

    @objc private func switchToInstalledCopy() {
        do {
            try YSettingRuntimeIdentity.relaunchInstalledApplication(
                atPath: YClipApplicationIdentity.installedApplicationPath,
                expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
                expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
            )
        } catch {
            showAlert(title: "无法切换到正式安装版", message: error.localizedDescription)
        }
    }

    @objc private func resetAccessibility() {
        resetAccessibilityButton.isEnabled = false
        onResetAccessibility { [weak self] result in
            guard let self else { return }
            resetAccessibilityButton.isEnabled = true
            refreshAccessibilityStatus()

            switch result {
            case .authorizationRequested:
                break
            case .switchingToInstalledCopy:
                resetAccessibilityButton.isEnabled = false
            case .installedCopyRequired:
                showAlert(
                    title: "请先安装正式版 Y-Clip",
                    message: "权限记录已定向刷新，但不会为当前开发副本重新请求授权。请先安装有效的 /Applications/Y-Clip.app，再从应用程序文件夹启动并授权。"
                )
            case let .failed(message):
                showAlert(title: "刷新失败", message: message)
            }
        }
    }

    @objc private func refreshAccessibilityStatus() {
        let isInstalledCopy = YSettingRuntimeIdentity.isSignedInstalledCopy(
            expectedPath: YClipApplicationIdentity.installedApplicationPath,
            expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier,
            expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier
        )
        let hasInstalledCopy = YSettingRuntimeIdentity.isValidSignedApplication(
            atPath: YClipApplicationIdentity.installedApplicationPath,
            expectedBundleIdentifier: YClipApplicationIdentity.bundleIdentifier,
            expectedTeamIdentifier: YClipApplicationIdentity.teamIdentifier
        )
        runtimeIdentityPill.setText(isInstalledCopy ? "正式安装版" : "开发副本", tone: isInstalledCopy ? .success : .warning)
        switchToInstalledButton.isHidden = isInstalledCopy
        switchToInstalledButton.isEnabled = hasInstalledCopy

        let trusted = AccessibilityPermission.isTrusted(prompt: false)
        if trusted {
            accessibilityStatusPill.setText("已开启", tone: .success)
        } else if !isInstalledCopy, hasInstalledCopy {
            accessibilityStatusPill.setText("当前副本未授权", tone: .warning)
        } else {
            accessibilityStatusPill.setText("未开启", tone: .warning)
        }
        requestAccessibilityButton.isEnabled = !trusted
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

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
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
        let unitLabel = YSettingUI.rowTitle("条")
        unitLabel.maximumNumberOfLines = 1
        let controls = YSettingUI.horizontal([historyLimitField, unitLabel, historyLimitStepper], spacing: 6)
        return YSettingUI.row(title: "历史上限", trailingView: controls)
    }
}
