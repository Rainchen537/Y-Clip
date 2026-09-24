import AppKit

/// 一条历史内容对应一个可移动的浮窗；浮窗关闭后不保存该临时贴出状态。
final class StandaloneSnippetController: NSObject, NSWindowDelegate {
    let id = UUID()
    private let item: ClipboardItem
    private let imageData: Data?
    private let pasteboard: NSPasteboard
    private let panel: NSPanel

    var onClose: ((UUID) -> Void)?

    init(item: ClipboardItem, imageData: Data?, pasteboard: NSPasteboard = .general) {
        self.item = item
        self.imageData = imageData
        self.pasteboard = pasteboard
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 225),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func show(near point: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1100, height: 750)
        let x = min(max(point.x + 16, screen.minX + 12), screen.maxX - panel.frame.width - 12)
        let y = min(max(point.y - panel.frame.height - 16, screen.minY + 12), screen.maxY - panel.frame.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(id)
    }

    private func configurePanel() {
        panel.title = "单条贴出"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 240, height: 155)
        panel.delegate = self

        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        panel.contentView = root

        let copyButton = NSButton(title: "复制这一条", target: self, action: #selector(copyItem(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(copyButton)

        if let imageData, let image = NSImage(data: imageData) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
                imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                imageView.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10)
            ])
        } else {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false

            let textView = NSTextView(frame: .zero)
            textView.string = item.text ?? ""
            textView.font = .systemFont(ofSize: 14)
            textView.textColor = .labelColor
            textView.drawsBackground = false
            textView.isEditable = false
            textView.isSelectable = true
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize.height = .greatestFiniteMagnitude
            scrollView.documentView = textView
            root.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
                scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
                scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
                scrollView.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -10)
            ])
        }

        NSLayoutConstraint.activate([
            copyButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    @objc private func copyItem(_ sender: NSButton) {
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
            sender.title = "已复制"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
                sender?.title = "复制这一条"
            }
        }
    }
}
