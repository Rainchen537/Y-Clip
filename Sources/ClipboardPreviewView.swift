import AppKit

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
    private let pinButton = NSButton()
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

        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "固定剪贴板")
        pinButton.bezelStyle = .regularSquare
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.translatesAutoresizingMaskIntoConstraints = false

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
        panelView.addSubview(pinButton)
        panelView.addSubview(settingsButton)
        panelView.addSubview(scrollView)
        addSubview(previewHost)

        NSLayoutConstraint.activate([
            previewHost.topAnchor.constraint(equalTo: topAnchor),
            previewHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewHost.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerStack.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 14),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -10),

            pinButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -4),
            pinButton.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 26),
            pinButton.heightAnchor.constraint(equalToConstant: 26),

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
                item: ClipboardItem(text: "https://github.com/Rainchen537/Y-Clip"),
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
        let border = NSBezierPath(
            roundedRect: NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1),
            xRadius: 14,
            yRadius: 14
        )
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
