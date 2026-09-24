import AppKit
import Carbon

private final class BorderlessSnippetPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// 内容本身就是贴出的画面；悬浮窗口没有系统标题栏、描边或常驻工具栏。
private final class SnippetCanvasView: NSView {
    let text: String
    let image: NSImage?
    var zoom: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    var onHoverChange: ((Bool) -> Void)?
    var onZoomStep: ((Bool) -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var wheelRemainder: CGFloat = 0

    init(text: String, image: NSImage?) {
        self.text = text
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        (text as NSString).draw(
            in: bounds.insetBy(dx: 14 * zoom, dy: 10 * zoom),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 16 * zoom),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
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
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = canvas

        menuButton.title = "操作"
        menuButton.bezelStyle = .rounded
        menuButton.controlSize = .small
        menuButton.toolTip = "放大、缩小、复制或移除"
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
        canvas.onContextMenu = { [weak self] point in
            self?.showActions(at: point)
        }
        panel.onKeyDown = { [weak self] event in
            self?.handleKey(event) ?? false
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command), key == "c" {
            copyItem()
            return true
        }
        switch key {
        case "+", "=":
            adjustZoom(zoomIn: true)
            return true
        case "-":
            adjustZoom(zoomIn: false)
            return true
        default:
            if Int(event.keyCode) == kVK_Escape {
                removeSnippet()
                return true
            }
            return false
        }
    }

    @objc private func showActionsFromButton() {
        showActions(at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.minY))
    }

    private func showActions(at point: NSPoint) {
        let menu = NSMenu()
        for (title, action) in [
            ("放大", #selector(zoomIn)),
            ("缩小", #selector(zoomOut)),
            ("复制原内容", #selector(copyItem)),
            ("移除贴出", #selector(removeSnippet))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: canvas)
    }

    @objc private func zoomIn() {
        adjustZoom(zoomIn: true)
    }

    @objc private func zoomOut() {
        adjustZoom(zoomIn: false)
    }

    private func adjustZoom(zoomIn: Bool) {
        let next = min(3, max(0.45, zoom * (zoomIn ? 1.15 : 1 / 1.15)))
        guard abs(next - zoom) > 0.001 else { return }
        zoom = next
        canvas.zoom = next
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1100, height: 750)
        let size = NSSize(
            width: min(max(60, baseSize.width * next), screen.width * 0.9),
            height: min(max(42, baseSize.height * next), screen.height * 0.9)
        )
        let current = panel.frame
        let x = min(max(current.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        let y = min(max(current.midY - size.height / 2, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
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
