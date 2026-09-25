import AppKit
import Carbon

private final class BorderlessSnippetPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

private final class SnippetSelectableTextView: NSTextView {
    var onContextMenu: ((NSPoint) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(superview?.convert(event.locationInWindow, from: nil) ?? .zero)
    }

    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// 拖动边角时使用对侧边作为锚点，文字和图片始终等比缩放。
struct SnippetResizeGesture {
    let initialFrame: NSRect
    let initialPointer: NSPoint
    let initialZoom: CGFloat
    let horizontalEdge: Int  // -1 左，1 右，0 未拖动
    let verticalEdge: Int    // -1 下，1 上，0 未拖动
}

enum SnippetResizeGeometry {
    static func zoom(for gesture: SnippetResizeGesture, pointer: NSPoint) -> CGFloat {
        let horizontalRatio = gesture.horizontalEdge == 0 ? 1 :
            (gesture.initialFrame.width
             + CGFloat(gesture.horizontalEdge) * (pointer.x - gesture.initialPointer.x))
            / gesture.initialFrame.width
        let verticalRatio = gesture.verticalEdge == 0 ? 1 :
            (gesture.initialFrame.height
             + CGFloat(gesture.verticalEdge) * (pointer.y - gesture.initialPointer.y))
            / gesture.initialFrame.height
        let ratio = abs(horizontalRatio - 1) >= abs(verticalRatio - 1)
            ? horizontalRatio : verticalRatio
        return min(3, max(0.45, gesture.initialZoom * ratio))
    }

    static func frame(
        from gesture: SnippetResizeGesture,
        size: NSSize,
        in screen: NSRect
    ) -> NSRect {
        let initial = gesture.initialFrame
        let x: CGFloat
        switch gesture.horizontalEdge {
        case -1: x = initial.maxX - size.width
        case 1: x = initial.minX
        default: x = initial.midX - size.width / 2
        }
        let y: CGFloat
        switch gesture.verticalEdge {
        case -1: y = initial.maxY - size.height
        case 1: y = initial.minY
        default: y = initial.midY - size.height / 2
        }
        return NSRect(
            x: min(max(x, screen.minX + 8), screen.maxX - size.width - 8),
            y: min(max(y, screen.minY + 8), screen.maxY - size.height - 8),
            width: size.width,
            height: size.height
        )
    }
}

/// 内容本身就是贴出的画面；悬浮窗口没有系统标题栏、描边或常驻工具栏。
private final class SnippetCanvasView: NSView {
    let text: String
    let image: NSImage?
    var zoom: CGFloat = 1 {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }
    var onHoverChange: ((Bool) -> Void)?
    var onZoomStep: ((Bool) -> Void)?
    var onResize: ((SnippetResizeGesture, NSPoint) -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?
    private(set) var selectableTextView: SnippetSelectableTextView?
    private var trackingAreaRef: NSTrackingArea?
    private var wheelRemainder: CGFloat = 0
    private var resizeGesture: SnippetResizeGesture?

    init(text: String, image: NSImage?) {
        self.text = text
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        if image == nil {
            let textView = SnippetSelectableTextView(frame: .zero)
            textView.string = text
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.onContextMenu = { [weak self] point in
                self?.onContextMenu?(point)
            }
            addSubview(textView)
            selectableTextView = textView
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        selectableTextView?.frame = bounds.insetBy(dx: 14 * zoom, dy: 10 * zoom)
        selectableTextView?.font = .systemFont(ofSize: 16 * zoom)
        selectableTextView?.textColor = .labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let image, image.size.width > 0, image.size.height > 0 {
            let factor = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
            let rect = NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges(at: point)
        if (edges.horizontal != 0 || edges.vertical != 0), let window {
            resizeGesture = SnippetResizeGesture(
                initialFrame: window.frame,
                initialPointer: NSEvent.mouseLocation,
                initialZoom: zoom,
                horizontalEdge: edges.horizontal,
                verticalEdge: edges.vertical
            )
            return
        }
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let resizeGesture {
            onResize?(resizeGesture, NSEvent.mouseLocation)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        resizeGesture = nil
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        wheelRemainder += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        guard abs(wheelRemainder) >= threshold else { return }
        onZoomStep?(wheelRemainder > 0)
        wheelRemainder = 0
    }

    private func resizeEdges(at point: NSPoint) -> (horizontal: Int, vertical: Int) {
        let edge: CGFloat = 13
        let horizontal = point.x <= edge ? -1 : (point.x >= bounds.maxX - edge ? 1 : 0)
        let vertical = point.y <= edge ? -1 : (point.y >= bounds.maxY - edge ? 1 : 0)
        return (horizontal, vertical)
    }

    private func updateCursor(at point: NSPoint) {
        let edges = resizeEdges(at: point)
        if edges.horizontal != 0 && edges.vertical != 0 {
            NSCursor.crosshair.set()
        } else if edges.horizontal != 0 {
            NSCursor.resizeLeftRight.set()
        } else if edges.vertical != 0 {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

/// 单条贴出浮窗在当前会话中存在；“移除”仅关闭浮窗，不删除历史内容。
final class StandaloneSnippetController: NSObject, NSWindowDelegate {
    let id = UUID()
    private let item: ClipboardItem
    private let imageData: Data?
    private let sourceImage: NSImage?
    private let pasteboard: NSPasteboard
    private let baseSize: NSSize
    private let panel: BorderlessSnippetPanel
    private let canvas: SnippetCanvasView
    private let menuButton = NSButton()
    private var zoom: CGFloat = 1

    var onClose: ((UUID) -> Void)?

    init(item: ClipboardItem, imageData: Data?, pasteboard: NSPasteboard = .general) {
        self.item = item
        self.imageData = imageData
        self.pasteboard = pasteboard
        sourceImage = imageData.flatMap(NSImage.init(data:))
        baseSize = Self.makeBaseSize(text: item.text ?? "", image: sourceImage)
        panel = BorderlessSnippetPanel(
            contentRect: NSRect(origin: .zero, size: baseSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        canvas = SnippetCanvasView(text: item.text ?? "", image: sourceImage)
        super.init()
        configurePanel()
    }

    func show(near point: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1100, height: 750)
        let x = min(max(point.x + 16, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        let y = min(max(point.y - panel.frame.height - 16, screen.minY + 8), screen.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(id)
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = canvas

        menuButton.title = "操作"
        menuButton.bezelStyle = .rounded
        menuButton.controlSize = .small
        menuButton.toolTip = "复制或移除"
        menuButton.target = self
        menuButton.action = #selector(showActionsFromButton)
        menuButton.isHidden = true
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 6),
            menuButton.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -6)
        ])

        canvas.onHoverChange = { [weak self] hovering in
            self?.menuButton.isHidden = !hovering
        }
        canvas.onZoomStep = { [weak self] zoomIn in
            self?.adjustZoom(zoomIn: zoomIn)
        }
        canvas.onResize = { [weak self] gesture, pointer in
            self?.resize(using: gesture, pointer: pointer)
        }
        canvas.onContextMenu = { [weak self] point in
            self?.showActions(at: point)
        }
        panel.onKeyDown = { [weak self] event in
            self?.handleKey(event) ?? false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == [.command], key == "c" {
            if !copySelectedText() {
                copyItem()
            }
            return true
        }
        if modifiers.isEmpty,
           [kVK_Escape, kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
            removeSnippet()
            return true
        }
        return false
    }

    @objc private func showActionsFromButton() {
        showActions(at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.minY))
    }

    private func showActions(at point: NSPoint) {
        let menu = NSMenu()
        let hasSelection = (canvas.selectableTextView?.selectedRange().length ?? 0) > 0
        if hasSelection {
            let selected = NSMenuItem(title: "复制所选文字", action: #selector(copySelection), keyEquivalent: "c")
            selected.keyEquivalentModifierMask = .command
            selected.target = self
            menu.addItem(selected)
        }
        let copy = NSMenuItem(
            title: "复制原内容", action: #selector(copyItem), keyEquivalent: hasSelection ? "" : "c"
        )
        copy.keyEquivalentModifierMask = .command
        copy.target = self
        menu.addItem(copy)
        let remove = NSMenuItem(title: "移除贴出", action: #selector(removeSnippet), keyEquivalent: "\u{8}")
        remove.keyEquivalentModifierMask = []
        remove.target = self
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: point, in: canvas)
    }

    private func adjustZoom(zoomIn: Bool) {
        let screen = visibleScreen()
        let next = allowedZoom(zoom * (zoomIn ? 1.15 : 1 / 1.15), in: screen)
        guard abs(next - zoom) > 0.001 else { return }
        let size = scaledSize(at: next)
        let current = panel.frame
        let x = min(max(current.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        let y = min(max(current.midY - size.height / 2, screen.minY + 8), screen.maxY - size.height - 8)
        applyZoom(next, frame: NSRect(origin: NSPoint(x: x, y: y), size: size))
    }

    private func resize(using gesture: SnippetResizeGesture, pointer: NSPoint) {
        let screen = visibleScreen()
        let next = allowedZoom(SnippetResizeGeometry.zoom(for: gesture, pointer: pointer), in: screen)
        let frame = SnippetResizeGeometry.frame(
            from: gesture,
            size: scaledSize(at: next),
            in: screen
        )
        applyZoom(next, frame: frame)
    }

    private func applyZoom(_ value: CGFloat, frame: NSRect) {
        zoom = value
        canvas.zoom = value
        panel.setFrame(frame, display: true)
    }

    private func scaledSize(at value: CGFloat) -> NSSize {
        NSSize(width: baseSize.width * value, height: baseSize.height * value)
    }

    private func visibleScreen() -> NSRect {
        panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1100, height: 750)
    }

    private func allowedZoom(_ requested: CGFloat, in screen: NSRect) -> CGFloat {
        let lower = max(0.45, 60 / baseSize.width, 42 / baseSize.height)
        let upper = min(3, screen.width * 0.9 / baseSize.width, screen.height * 0.9 / baseSize.height)
        return min(max(requested, lower), max(lower, upper))
    }

    @objc private func copyItem() {
        let copied: Bool
        switch item.kind {
        case let .text(text):
            pasteboard.clearContents()
            copied = pasteboard.setString(text, forType: .string)
        case .image:
            guard let imageData else { return }
            pasteboard.clearContents()
            copied = pasteboard.setData(imageData, forType: .png)
        }
        if copied {
            menuButton.title = "已复制"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.menuButton.title = "操作"
            }
        }
    }

    @objc private func copySelection() {
        _ = copySelectedText()
    }

    @discardableResult
    private func copySelectedText() -> Bool {
        guard let textView = canvas.selectableTextView,
              textView.selectedRange().length > 0 else { return false }
        let selected = (textView.string as NSString).substring(with: textView.selectedRange())
        pasteboard.clearContents()
        return pasteboard.setString(selected, forType: .string)
    }

    @objc private func removeSnippet() {
        panel.close()
    }

    private static func makeBaseSize(text: String, image: NSImage?) -> NSSize {
        if let image, image.size.width > 0, image.size.height > 0 {
            let factor = min(1, 520 / image.size.width, 380 / image.size.height)
            return NSSize(
                width: max(80, ceil(image.size.width * factor)),
                height: max(60, ceil(image.size.height * factor))
            )
        }
        let width: CGFloat = 310
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: width - 28, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 16), .paragraphStyle: paragraph]
        )
        return NSSize(width: width, height: min(500, max(72, ceil(measured.height) + 20)))
    }
}
