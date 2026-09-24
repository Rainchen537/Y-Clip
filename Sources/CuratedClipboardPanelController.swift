import AppKit

private final class CuratedRowsStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// 与完整历史面板分开的常驻面板，只显示用户明确加入的条目。
final class CuratedClipboardPanelController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private static let frameKey = "curatedPanelFrame"

    private let store: CuratedClipboardStore
    private let panel: NSPanel
    private let rowStack = CuratedRowsStackView()
    private let listScrollView = NSScrollView()
    private let editorView = NSView()
    private let titleLabel = NSTextField(labelWithString: "复制清单")
    private let countLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private var editorTextView: NSTextView?
    private var addSelectionButton: NSButton?
    private var addWholeButton: NSButton?
    private var isEditing = false
    private var listFrameBeforeEditing: NSRect?

    var onError: ((String) -> Void)?

    init(store: CuratedClipboardStore) {
        self.store = store
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 350),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        store.onChange = { [weak self] _ in
            self?.renderRows()
        }
        renderRows()
    }

    func show() {
        if !panel.isVisible {
            if !isEditing {
                restorePosition()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func showEditor(prefill: String? = nil) {
        show()
        if !isEditing {
            listFrameBeforeEditing = panel.frame
            isEditing = true
            titleLabel.stringValue = "拆分内容"
            editButton.title = "完成"
            listScrollView.isHidden = true
            editorView.isHidden = false
            resizeForEditing()
        }
        if let prefill {
            editorTextView?.string = prefill
            editorTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
        refreshEditorButtons()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editorTextView)
    }

    private func resizeForEditing() {
        let previous = panel.frame
        let width = max(previous.width, 500)
        let height = max(previous.height, 430)
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? previous
        let x = min(max(previous.maxX - width, screen.minX + 12), screen.maxX - width - 12)
        let y = min(max(previous.maxY - height, screen.minY + 12), screen.maxY - height - 12)
        panel.minSize = NSSize(width: 380, height: 280)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func finishEditing() {
        guard isEditing else { return }
        let current = panel.frame
        isEditing = false
        titleLabel.stringValue = "复制清单"
        editButton.title = "添加 / 拆分"
        panel.makeFirstResponder(nil)
        editorView.isHidden = true
        listScrollView.isHidden = false
        panel.minSize = NSSize(width: 285, height: 180)
        if let saved = listFrameBeforeEditing {
            let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? current
            let x = min(max(current.maxX - saved.width, screen.minX + 12), screen.maxX - saved.width - 12)
            let y = min(max(current.maxY - saved.height, screen.minY + 12), screen.maxY - saved.height - 12)
            panel.setFrame(NSRect(x: x, y: y, width: saved.width, height: saved.height), display: true)
        }
        listFrameBeforeEditing = nil
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel, panel.isVisible, !isEditing else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel, panel.isVisible, !isEditing else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    func textDidChange(_ notification: Notification) {
        refreshEditorButtons()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshEditorButtons()
    }

    private func configurePanel() {
        panel.title = "复制清单"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 285, height: 180)
        panel.delegate = self

        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        panel.contentView = root

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        editButton.title = "添加 / 拆分"
        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(openEditor)
        editButton.toolTip = "手动输入，或选取长文本中的片段"
        editButton.translatesAutoresizingMaskIntoConstraints = false

        listScrollView.drawsBackground = false
        listScrollView.hasVerticalScroller = true
        listScrollView.borderType = .noBorder
        listScrollView.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.spacing = 7
        rowStack.alignment = .leading
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        listScrollView.documentView = rowStack
        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.isHidden = true
        configureEditorView()

        root.addSubview(titleLabel)
        root.addSubview(countLabel)
        root.addSubview(editButton)
        root.addSubview(listScrollView)
        root.addSubview(editorView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -8),
            editButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            editButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            listScrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            listScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 9),
            listScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -9),
            listScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
            editorView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            editorView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 9),
            editorView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -9),
            editorView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),

            rowStack.leadingAnchor.constraint(equalTo: listScrollView.contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: listScrollView.contentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: listScrollView.contentView.topAnchor),
            rowStack.widthAnchor.constraint(equalTo: listScrollView.contentView.widthAnchor)
        ])
    }

    private func renderRows() {
        countLabel.stringValue = "\(store.items.count) 条"
        rowStack.arrangedSubviews.forEach { view in
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if store.items.isEmpty {
            let empty = NSTextField(labelWithString: "从历史加入，或点右上角添加内容")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            rowStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 80).isActive = true
            return
        }

        for item in store.items {
            let row = makeRow(for: item)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(for item: ClipboardItem) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 9
        row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor

        let preview = NSTextField(labelWithString: item.previewText)
        preview.font = .systemFont(ofSize: 12.5, weight: .medium)
        preview.textColor = .labelColor
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.cell?.wraps = true
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.toolTip = item.text

        let copyButton = NSButton(title: "复制", target: self, action: #selector(copyItem(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        copyButton.toolTip = "只复制这一条"
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(title: "移除", target: self, action: #selector(removeItem(_:)))
        removeButton.bezelStyle = .inline
        removeButton.controlSize = .small
        removeButton.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        removeButton.toolTip = "从复制清单移除"
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(preview)
        row.addSubview(copyButton)
        row.addSubview(removeButton)

        var constraints = [
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            preview.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            preview.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -9),
            copyButton.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 8),
            copyButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 56),
            removeButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 2),
            removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 38)
        ]

        if let payload = item.image,
           let imageURL = store.imageURL(for: payload),
           let image = NSImage(contentsOf: imageURL) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(imageView)
            constraints.append(contentsOf: [
                imageView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                imageView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 40),
                imageView.heightAnchor.constraint(equalToConstant: 40),
                preview.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8)
            ])
        } else {
            constraints.append(preview.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    @objc private func copyItem(_ sender: NSButton) {
        guard
            let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
            let item = store.items.first(where: { $0.id == id })
        else { return }
        guard store.copyToPasteboard(item) else {
            onError?("内容已不可用，无法复制。")
            return
        }
        sender.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.title = "复制"
        }
    }

    @objc private func removeItem(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        do {
            try store.remove(id)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    @objc private func openEditor() {
        if isEditing {
            finishEditing()
        } else {
            showEditor()
        }
    }

    private func configureEditorView() {
        let instruction = NSTextField(labelWithString: "粘贴或输入内容，选中一段后加入复制清单")
        instruction.font = .systemFont(ofSize: 13, weight: .medium)
        instruction.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize.height = .greatestFiniteMagnitude
        textView.delegate = self
        scrollView.documentView = textView
        editorTextView = textView

        let selectionButton = NSButton(title: "加入选中片段", target: self, action: #selector(addSelectedText))
        selectionButton.bezelStyle = .rounded
        selectionButton.translatesAutoresizingMaskIntoConstraints = false
        addSelectionButton = selectionButton

        let wholeButton = NSButton(title: "整段加入", target: self, action: #selector(addWholeText))
        wholeButton.bezelStyle = .rounded
        wholeButton.translatesAutoresizingMaskIntoConstraints = false
        addWholeButton = wholeButton

        editorView.addSubview(instruction)
        editorView.addSubview(scrollView)
        editorView.addSubview(selectionButton)
        editorView.addSubview(wholeButton)

        NSLayoutConstraint.activate([
            instruction.topAnchor.constraint(equalTo: editorView.topAnchor, constant: 4),
            instruction.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 7),
            instruction.trailingAnchor.constraint(lessThanOrEqualTo: editorView.trailingAnchor, constant: -7),

            scrollView.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 5),
            scrollView.trailingAnchor.constraint(equalTo: editorView.trailingAnchor, constant: -5),
            scrollView.bottomAnchor.constraint(equalTo: selectionButton.topAnchor, constant: -12),

            selectionButton.trailingAnchor.constraint(equalTo: editorView.trailingAnchor, constant: -5),
            selectionButton.bottomAnchor.constraint(equalTo: editorView.bottomAnchor, constant: -5),
            wholeButton.trailingAnchor.constraint(equalTo: selectionButton.leadingAnchor, constant: -8),
            wholeButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor)
        ])
    }

    private func refreshEditorButtons() {
        guard let textView = editorTextView else { return }
        let text = textView.string
        let range = textView.selectedRange()
        addWholeButton?.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        addSelectionButton?.isEnabled = CuratedTextSelection.fragment(in: text, range: range) != nil
    }

    @objc private func addSelectedText() {
        guard let textView = editorTextView else { return }
        guard let selected = CuratedTextSelection.fragment(
            in: textView.string,
            range: textView.selectedRange()
        ) else {
            return
        }
        addText(selected)
    }

    @objc private func addWholeText() {
        guard let text = editorTextView?.string else { return }
        addText(text)
    }

    private func addText(_ text: String) {
        do {
            try store.addText(text)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func restorePosition() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 750)
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= panel.minSize.width, frame.height >= panel.minSize.height,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrame(frame, display: false)
                return
            }
        }
        panel.setFrameOrigin(NSPoint(
            x: screen.maxX - panel.frame.width - 24,
            y: screen.midY - panel.frame.height / 2
        ))
    }
}
