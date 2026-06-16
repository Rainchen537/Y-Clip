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

/// 菜单尺寸档位（小/中/大），驱动面板宽度、行高、字号、缩略图大小。
enum MenuSize: String, Codable, CaseIterable {
    case small, medium, large

    static let `default` = MenuSize.medium

    var displayName: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    var panelWidth: CGFloat {
        switch self {
        case .small: return 300
        case .medium: return 360
        case .large: return 430
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .small: return 62
        case .medium: return 76
        case .large: return 92
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: return 12
        case .medium: return 13
        case .large: return 15
        }
    }

    /// 缩略图正方形边长（略小于行高，留出上下边距）。
    var thumbSide: CGFloat {
        rowHeight - 20
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
        metrics: MenuSize,
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
            thumbView.layer?.cornerRadius = 5
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
                thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
                thumbView.widthAnchor.constraint(equalToConstant: side),
                thumbView.heightAnchor.constraint(equalToConstant: side),
                titleLabel.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
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
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
                titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
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

final class ClipboardPanelController {
    private let panel: ClipboardHistoryPanel
    private let rootView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "剪贴板历史")
    private let hintLabel = NSTextField(labelWithString: "↑↓ 选择 · Enter 粘贴 · Esc 关闭")
    private var rowViews: [HistoryRowView] = []
    private var items: [ClipboardItem] = []
    private var selectedIndex = 0
    private var onChoose: ((ClipboardItem) -> Void)?
    private var onClose: (() -> Void)?
    private var outsideClickMonitor: Any?
    private var scrollObserver: Any?
    private var metrics: MenuSize = .default
    /// 由外部注入：给定图片项，返回其全图文件 URL（用于生成缩略图）。
    var imageURLProvider: ((ImagePayload) -> URL)?

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

        headerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        stackView.orientation = .vertical
        stackView.spacing = 6
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        rootView.addSubview(headerStack)
        rootView.addSubview(scrollView)
        panel.contentView = rootView

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -14),

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
    }

    func show(
        items: [ClipboardItem],
        menuSize: MenuSize,
        near point: NSPoint,
        onChoose: @escaping (ClipboardItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.items = items
        self.metrics = menuSize
        self.onChoose = onChoose
        self.onClose = onClose
        selectedIndex = items.isEmpty ? -1 : 0

        renderRows()

        let panelSize = fittedPanelSize(for: items.count, near: point)
        panel.setFrame(positionedFrame(size: panelSize, near: point), display: true)

        panel.makeKeyAndOrderFront(nil)
        beginOutsideClickMonitoring()
        beginHoverTracking()
    }

    func close() {
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
        guard panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else {
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
        endOutsideClickMonitoring()
        endHoverTracking()
        panel.orderOut(nil)
        onChoose?(item)
    }

    private func fittedPanelSize(for itemCount: Int, near point: NSPoint) -> NSSize {
        let width = metrics.panelWidth
        let headerHeight: CGFloat = 58
        let rowHeight = metrics.rowHeight
        let rowSpacing: CGFloat = 6
        let emptyHeight: CGFloat = 96
        let screen = screen(containing: point)
        let maxHeight = max(260, min(560, screen.visibleFrame.height - 24))

        if itemCount == 0 {
            return NSSize(width: width, height: headerHeight + emptyHeight)
        }

        let contentHeight = CGFloat(itemCount) * rowHeight
            + CGFloat(max(0, itemCount - 1)) * rowSpacing
        let height = min(headerHeight + contentHeight + 12, maxHeight)
        return NSSize(width: width, height: height)
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
