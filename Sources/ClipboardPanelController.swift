import AppKit
import Carbon

final class ClipboardHistoryPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }

        super.keyDown(with: event)
    }
}

private final class TopAlignedStackView: NSStackView {
    override var isFlipped: Bool {
        true
    }
}

/// 历史弹窗显示参数：大小负责等比例缩放内容，宽度/长度只改变容器尺寸。
struct HistoryPanelMetrics: Codable, Equatable {
    static let `default` = HistoryPanelMetrics(scale: 1.0, width: 360, visibleRows: 4)
    static let scaleRange: ClosedRange<Double> = 0.80...1.35
    static let widthRange: ClosedRange<Double> = 280...560
    static let visibleRowsRange: ClosedRange<Double> = 3...10

    let scale: CGFloat
    let width: CGFloat
    let visibleRows: CGFloat

    init(scale: CGFloat, width: CGFloat, visibleRows: CGFloat) {
        self.scale = CGFloat(Self.clamp(Double(scale), to: Self.scaleRange))
        self.width = CGFloat(Self.clamp(Double(width), to: Self.widthRange))
        self.visibleRows = CGFloat(Self.clamp(Double(visibleRows), to: Self.visibleRowsRange))
    }

    var panelWidth: CGFloat {
        width
    }

    var rowHeight: CGFloat {
        76 * scale
    }

    var fontSize: CGFloat {
        13 * scale
    }

    var headerFontSize: CGFloat {
        14 * scale
    }

    var hintFontSize: CGFloat {
        11 * scale
    }

    var rowSpacing: CGFloat {
        6 * scale
    }

    var contentInset: CGFloat {
        12 * scale
    }

    var thumbSide: CGFloat {
        rowHeight - 20 * scale
    }

    var headerHeight: CGFloat {
        58 * scale
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

final class HistoryRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let thumbView = NSImageView()
    private let onChoose: () -> Void
    private var trackingAreaRef: NSTrackingArea?

    /// 鼠标进入/离开本行时回调，由 controller 按真实鼠标位置统一重算 hover，
    /// 避免滚动时 enter/exit 不配对导致多行同时高亮。
    var onHoverProbe: (() -> Void)?

    var isHovering = false {
        didSet {
            if oldValue != isHovering {
                updateAppearance()
            }
        }
    }

    var isSelected = false {
        didSet {
            updateAppearance()
        }
    }

    /// - Parameters:
    ///   - thumbnail: 图片项的缩略图（文本项传 nil）。
    ///   - metrics: 当前菜单尺寸档位。
    init(
        item: ClipboardItem,
        thumbnail: NSImage?,
        metrics: HistoryPanelMetrics,
        onChoose: @escaping () -> Void
    ) {
        self.onChoose = onChoose
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8

        heightAnchor.constraint(equalToConstant: metrics.rowHeight).isActive = true

        if let thumbnail {
            // 图片项：固定尺寸缩略图 + 右侧尺寸说明，块高度与文本项一致。
            thumbView.image = thumbnail
            thumbView.imageScaling = .scaleProportionallyUpOrDown
            thumbView.wantsLayer = true
            thumbView.layer?.cornerRadius = 5 * metrics.scale
            thumbView.layer?.masksToBounds = true
            thumbView.layer?.borderWidth = 1
            thumbView.layer?.borderColor = NSColor.separatorColor.cgColor
            thumbView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(thumbView)

            titleLabel.stringValue = item.previewText
            titleLabel.font = .systemFont(ofSize: metrics.fontSize, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.maximumNumberOfLines = 1
            addSubview(titleLabel)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let side = metrics.thumbSide
            NSLayoutConstraint.activate([
                thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.contentInset),
                thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
                thumbView.widthAnchor.constraint(equalToConstant: side),
                thumbView.heightAnchor.constraint(equalToConstant: side),
                titleLabel.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10 * metrics.scale),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.contentInset),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            // 文本项：最多三行预览。
            titleLabel.stringValue = item.previewText
            titleLabel.font = .systemFont(ofSize: metrics.fontSize, weight: .medium)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.maximumNumberOfLines = 3
            titleLabel.textColor = .labelColor
            titleLabel.usesSingleLineMode = false
            titleLabel.cell?.wraps = true
            titleLabel.cell?.isScrollable = false
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(titleLabel)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.contentInset),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.contentInset),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10 * metrics.scale),
                titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10 * metrics.scale)
            ])
        }

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

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
        onHoverProbe?()
    }

    override func mouseExited(with event: NSEvent) {
        onHoverProbe?()
    }

    override func mouseDown(with event: NSEvent) {
        onChoose()
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        } else {
            // 常驻一层极淡底色，让每个块自成一面，靠面与间距区分，无需分割线。
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        }
    }
}

private final class ClipboardPanelBackgroundView: NSVisualEffectView {
    var allowsWindowDrag = false

    override var mouseDownCanMoveWindow: Bool {
        allowsWindowDrag
    }
}

private final class ClipboardPanelDragHandleView: NSView {
    var isDragEnabled = false

    override func mouseDown(with event: NSEvent) {
        if isDragEnabled {
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

final class ClipboardPanelController {
    private static let scrollMemoryDuration: TimeInterval = 180

    private let panel: ClipboardHistoryPanel
    private let rootView = ClipboardPanelBackgroundView()
    private let dragHandleView = ClipboardPanelDragHandleView()
    private let scrollView = NSScrollView()
    private let stackView = TopAlignedStackView()
    private let headerLabel = NSTextField(labelWithString: "剪贴板历史")
    private let hintLabel = NSTextField(labelWithString: "↑↓ 选择 · Enter 粘贴 · Esc 关闭")
    private let pinButton = NSButton()
    private let settingsButton = NSButton()
    private var rowViews: [HistoryRowView] = []
    private var items: [ClipboardItem] = []
    private var selectedIndex = 0
    private var onChoose: ((ClipboardItem) -> Void)?
    private var onClose: (() -> Void)?
    private var outsideClickMonitor: Any?
    private var scrollObserver: Any?
    private var panelMoveObserver: NSObjectProtocol?
    private var metrics: HistoryPanelMetrics = .default
    private(set) var isPinned = false
    private var lastItemsSignature: [String] = []
    private var lastScrollMemoryDate: Date?
    /// 由外部注入：给定图片项，返回其全图文件 URL（用于生成缩略图）。
    var imageURLProvider: ((ImagePayload) -> URL)?
    var onOpenSettings: ((NSView) -> Void)?
    var onPinnedFrameChange: ((NSRect) -> Void)?

    init() {
        panel = ClipboardHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovable = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        rootView.material = .popover
        rootView.blendingMode = .withinWindow
        rootView.state = .active
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 10
        rootView.layer?.masksToBounds = true

        let headerStack = NSStackView(views: [headerLabel, hintLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 2
        headerStack.alignment = .leading
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = .systemFont(ofSize: metrics.headerFontSize, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: metrics.hintFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        pinButton.bezelStyle = .regularSquare
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.target = self
        pinButton.action = #selector(togglePinned)
        pinButton.translatesAutoresizingMaskIntoConstraints = false

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        settingsButton.bezelStyle = .regularSquare
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.toolTip = "打开设置"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        dragHandleView.translatesAutoresizingMaskIntoConstraints = false
        dragHandleView.isHidden = true

        stackView.orientation = .vertical
        stackView.spacing = metrics.rowSpacing
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        rootView.addSubview(headerStack)
        rootView.addSubview(dragHandleView)
        rootView.addSubview(pinButton)
        rootView.addSubview(settingsButton)
        rootView.addSubview(scrollView)
        panel.contentView = rootView

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -10),

            dragHandleView.topAnchor.constraint(equalTo: rootView.topAnchor),
            dragHandleView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            dragHandleView.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -4),
            dragHandleView.bottomAnchor.constraint(equalTo: scrollView.topAnchor),

            pinButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -4),
            pinButton.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 26),
            pinButton.heightAnchor.constraint(equalToConstant: 26),

            settingsButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -10),
            settingsButton.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -8),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        panel.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        updatePinnedAppearance()
        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isPinned, self.panel.isVisible else { return }
            self.onPinnedFrameChange?(self.panel.frame)
        }
    }

    deinit {
        if let panelMoveObserver {
            NotificationCenter.default.removeObserver(panelMoveObserver)
        }
    }

    func show(
        items: [ClipboardItem],
        metrics: HistoryPanelMetrics,
        near point: NSPoint,
        pinned: Bool,
        pinnedFrame: NSRect?,
        onChoose: @escaping (ClipboardItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        let itemsSignature = Self.signature(for: items)
        let shouldResetScroll = shouldResetScroll(for: itemsSignature)

        self.items = items
        self.metrics = metrics
        self.onChoose = onChoose
        self.onClose = onClose
        selectedIndex = items.isEmpty ? -1 : 0
        lastItemsSignature = itemsSignature
        applyPinnedState(pinned)

        updateMetrics()
        renderRows()

        let panelSize = fittedPanelSize(for: items.count, near: point)
        let regularFrame = positionedFrame(size: panelSize, near: point)
        let targetFrame = pinned
            ? positionedPinnedFrame(size: panelSize, savedFrame: pinnedFrame, fallback: regularFrame, near: point)
            : regularFrame
        panel.setFrame(targetFrame, display: true)

        panel.makeKeyAndOrderFront(nil)
        if shouldResetScroll {
            scrollToTop()
        }
        if pinned {
            endOutsideClickMonitoring()
            onPinnedFrameChange?(panel.frame)
        } else {
            beginOutsideClickMonitoring()
        }
        beginHoverTracking()
    }

    func updatePinnedItems(_ items: [ClipboardItem]) {
        guard panel.isVisible, isPinned else {
            return
        }

        let nextSignature = Self.signature(for: items)
        guard nextSignature != lastItemsSignature else {
            return
        }

        let selectedItem = self.items.indices.contains(selectedIndex)
            ? self.items[selectedIndex]
            : nil
        let scrollOrigin = scrollView.contentView.bounds.origin
        let oldFrame = panel.frame

        self.items = items
        lastItemsSignature = nextSignature
        if let selectedItem {
            let selectedID = selectedItem.id
            let selectedKey = selectedItem.dedupeKey
            let matchingIndex = items.firstIndex {
                $0.id == selectedID
            } ?? items.firstIndex {
                $0.dedupeKey == selectedKey
            }
            selectedIndex = matchingIndex
                ?? (items.isEmpty ? -1 : 0)
        } else {
            selectedIndex = items.isEmpty ? -1 : 0
        }

        renderRows()

        let referencePoint = NSPoint(
            x: oldFrame.midX,
            y: oldFrame.midY
        )
        let panelSize = fittedPanelSize(
            for: items.count,
            near: referencePoint
        )
        let visibleFrame = screen(containing: referencePoint)
            .visibleFrame
            .insetBy(dx: 12, dy: 12)
        let targetFrame = NSRect(
            x: clamp(
                oldFrame.minX,
                lower: visibleFrame.minX,
                upper: visibleFrame.maxX - panelSize.width
            ),
            y: clamp(
                oldFrame.maxY - panelSize.height,
                lower: visibleFrame.minY,
                upper: visibleFrame.maxY - panelSize.height
            ),
            width: panelSize.width,
            height: panelSize.height
        )
        panel.setFrame(targetFrame, display: true)
        restoreScrollOrigin(scrollOrigin)
        onPinnedFrameChange?(panel.frame)
        updateHover()
    }

    @objc private func openSettings() {
        endOutsideClickMonitoring()
        onOpenSettings?(settingsButton)
    }

    @objc private func togglePinned() {
        applyPinnedState(!isPinned)
        if isPinned {
            endOutsideClickMonitoring()
            onPinnedFrameChange?(panel.frame)
        } else {
            beginOutsideClickMonitoring()
        }
    }

    private func applyPinnedState(_ pinned: Bool) {
        isPinned = pinned
        rootView.allowsWindowDrag = pinned
        dragHandleView.isDragEnabled = pinned
        dragHandleView.isHidden = !pinned
        panel.isMovableByWindowBackground = pinned
        panel.level = .floating
        panel.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        updatePinnedAppearance()
    }

    private func updatePinnedAppearance() {
        let symbolName = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isPinned ? "取消固定剪贴板" : "固定剪贴板"
        )
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = isPinned ? "取消固定" : "固定在屏幕最上方"
    }

    private func updateMetrics() {
        headerLabel.font = .systemFont(ofSize: metrics.headerFontSize, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: metrics.hintFontSize)
        stackView.spacing = metrics.rowSpacing
    }

    func close() {
        rememberScrollPosition()
        endOutsideClickMonitoring()
        endHoverTracking()
        panel.orderOut(nil)
        onClose?()
    }

    private func beginOutsideClickMonitoring() {
        endOutsideClickMonitoring()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeIfClickOutside()
            }
        }
    }

    private func endOutsideClickMonitoring() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }

        outsideClickMonitor = nil
    }

    private func beginHoverTracking() {
        endHoverTracking()

        // 滚动时鼠标位置不变、不会触发 row 的 enter/exit，
        // 因此用 clip view 的 bounds 变化兜底，按真实鼠标位置重算唯一 hover。
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateHover()
        }
    }

    private func endHoverTracking() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollObserver = nil

        rowViews.forEach { $0.isHovering = false }
    }

    private func updateHover() {
        guard panel.isVisible else {
            return
        }

        let mouseInWindow = panel.mouseLocationOutsideOfEventStream
        let clip = scrollView.contentView
        let pointInClip = clip.convert(mouseInWindow, from: nil)
        let insideContent = clip.bounds.contains(pointInClip)

        for row in rowViews {
            if insideContent {
                let pointInRow = row.convert(mouseInWindow, from: nil)
                row.isHovering = row.bounds.contains(pointInRow)
            } else {
                row.isHovering = false
            }
        }
    }

    private func closeIfClickOutside() {
        guard !isPinned, panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else {
            return
        }

        close()
    }

    private func renderRows() {
        rowViews.removeAll()
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if items.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "复制一些文字或图片后再打开")
            emptyLabel.font = .systemFont(ofSize: metrics.fontSize)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.alignment = .center
            stackView.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            emptyLabel.heightAnchor.constraint(equalToConstant: metrics.rowHeight).isActive = true
            return
        }

        for (index, item) in items.enumerated() {
            let thumbnail = thumbnail(for: item)
            let row = HistoryRowView(item: item, thumbnail: thumbnail, metrics: metrics) { [weak self] in
                self?.chooseItem(at: index)
            }
            row.onHoverProbe = { [weak self] in
                self?.updateHover()
            }
            row.isSelected = index == selectedIndex
            rowViews.append(row)
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
    }

    /// 为图片项生成（缩放后的）缩略图；文本项返回 nil。
    private func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard let payload = item.image, let url = imageURLProvider?(payload) else {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }
        // 直接交给 NSImageView 按比例缩放显示，这里只做尺寸标注以便内存友好。
        let side = metrics.thumbSide * 2  // @2x，保证高清
        let target = NSImage(size: NSSize(width: side, height: side))
        target.lockFocus()
        NSColor.clear.set()
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        rect.fill()
        // 等比缩放并居中（aspect fit）
        let imgSize = image.size
        let scale = min(side / imgSize.width, side / imgSize.height)
        let drawSize = NSSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let origin = NSPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        image.draw(in: NSRect(origin: origin, size: drawSize))
        target.unlockFocus()
        return target
    }

    private func updateSelection() {
        for (index, row) in rowViews.enumerated() {
            row.isSelected = index == selectedIndex
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
            return true
        case kVK_UpArrow:
            moveSelection(by: -1)
            return true
        case kVK_DownArrow:
            moveSelection(by: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            chooseItem(at: selectedIndex)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else {
            return
        }

        selectedIndex = (selectedIndex + delta + items.count) % items.count
        updateSelection()
    }

    private func chooseItem(at index: Int) {
        guard items.indices.contains(index) else {
            return
        }

        let item = items[index]
        rememberScrollPosition()

        if isPinned {
            onChoose?(item)
            return
        }

        endOutsideClickMonitoring()
        endHoverTracking()
        panel.orderOut(nil)
        onChoose?(item)
    }

    private func shouldResetScroll(for itemsSignature: [String]) -> Bool {
        guard itemsSignature == lastItemsSignature else {
            return true
        }

        guard let lastScrollMemoryDate else {
            return true
        }

        return Date().timeIntervalSince(lastScrollMemoryDate) > Self.scrollMemoryDuration
    }

    private func rememberScrollPosition() {
        lastScrollMemoryDate = Date()
    }

    private func scrollToTop() {
        performScrollToTop()

        // NSScrollView 在 panel 刚显示时还可能有一轮延迟布局；下一轮主队列再校准一次，
        // 避免把文档视图的临时空白区域当成顶部。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else {
                return
            }

            self.performScrollToTop()
        }
    }

    private func performScrollToTop() {
        rootView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        stackView.layoutSubtreeIfNeeded()

        guard let documentView = scrollView.documentView else {
            return
        }

        let clipView = scrollView.contentView
        let y = topContentScrollOrigin(documentView: documentView, clipView: clipView)
        clipView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func restoreScrollOrigin(_ origin: NSPoint) {
        rootView.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        stackView.layoutSubtreeIfNeeded()

        guard let documentView = scrollView.documentView else {
            return
        }

        let clipView = scrollView.contentView
        let maxY = max(
            0,
            documentView.bounds.height - clipView.bounds.height
        )
        let y = clamp(origin.y, lower: 0, upper: maxY)
        clipView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func topContentScrollOrigin(documentView: NSView, clipView: NSClipView) -> CGFloat {
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        guard let firstContentView = stackView.arrangedSubviews.first(where: { !$0.isHidden }) else {
            return documentView.isFlipped ? 0 : maxY
        }

        let contentFrame = firstContentView.convert(firstContentView.bounds, to: documentView)
        let rawY = documentView.isFlipped
            ? contentFrame.minY
            : contentFrame.maxY - clipView.bounds.height
        return clamp(rawY, lower: 0, upper: maxY)
    }

    private static func signature(for items: [ClipboardItem]) -> [String] {
        items.map { item in
            "\(item.id.uuidString)|\(item.dedupeKey)"
        }
    }

    private func fittedPanelSize(for itemCount: Int, near point: NSPoint) -> NSSize {
        let width = metrics.panelWidth
        let headerHeight: CGFloat = 58
        let rowHeight = metrics.rowHeight
        let rowSpacing = metrics.rowSpacing
        let emptyHeight: CGFloat = 96 * metrics.scale
        let screen = screen(containing: point)
        let maxHeight = max(260, min(560, screen.visibleFrame.height - 24))

        if itemCount == 0 {
            return NSSize(width: width, height: headerHeight + emptyHeight)
        }

        let visibleCount = min(CGFloat(itemCount), metrics.visibleRows)
        let contentHeight = visibleCount * rowHeight
            + max(0, visibleCount - 1) * rowSpacing
        let height = min(headerHeight + contentHeight + 12, maxHeight)
        return NSSize(width: width, height: height)
    }

    private func positionedPinnedFrame(
        size: NSSize,
        savedFrame: NSRect?,
        fallback: NSRect,
        near point: NSPoint
    ) -> NSRect {
        let targetScreen = savedFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame.intersects(frame) }
        } ?? screen(containing: point)
        let visibleFrame = targetScreen.visibleFrame.insetBy(dx: 12, dy: 12)
        let preferredOrigin = savedFrame?.origin ?? fallback.origin
        let x = clamp(
            preferredOrigin.x,
            lower: visibleFrame.minX,
            upper: visibleFrame.maxX - size.width
        )
        let y = clamp(
            preferredOrigin.y,
            lower: visibleFrame.minY,
            upper: visibleFrame.maxY - size.height
        )
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func positionedFrame(size: NSSize, near point: NSPoint) -> NSRect {
        let screen = screen(containing: point)
        let visibleFrame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let gap: CGFloat = 10
        let anchorInset: CGFloat = 30

        var x = point.x - anchorInset
        if x + size.width > visibleFrame.maxX {
            x = point.x - size.width + anchorInset
        }
        x = clamp(x, lower: visibleFrame.minX, upper: visibleFrame.maxX - size.width)

        let belowY = point.y - size.height - gap
        let aboveY = point.y + gap
        let hasRoomBelow = belowY >= visibleFrame.minY
        let hasRoomAbove = aboveY + size.height <= visibleFrame.maxY
        let y: CGFloat

        if hasRoomBelow {
            y = belowY
        } else if hasRoomAbove {
            y = aboveY
        } else {
            let clampedBelow = clamp(
                belowY,
                lower: visibleFrame.minY,
                upper: visibleFrame.maxY - size.height
            )
            y = clampedBelow
        }

        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first { screen in
            NSMouseInRect(point, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
