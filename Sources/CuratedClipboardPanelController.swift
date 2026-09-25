import AppKit

private final class CuratedRowsStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// 与完整历史面板分开的常驻面板，只显示用户明确加入的条目。
final class CuratedClipboardPanelController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private static let frameKey = "curatedPanelFrame"
    private enum EditorPurpose {
        case add
        case split(UUID)
        case merge([UUID])
    }

    private let store: CuratedClipboardStore
    private let panel: NSPanel
    private let rowStack = CuratedRowsStackView()
    private let listScrollView = NSScrollView()
    private let editorView = NSView()
    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "复制清单")
    private let countLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private let mergeButton = NSButton()
    private let editorInstructionLabel = NSTextField(labelWithString: "")
    private let editorSourceScrollView = NSScrollView()
    private var editorTextView: NSTextView?
    private var addWholeButton: NSButton?
    private var isEditing = false
    private var isSelectingMerge = false
    private var selectedMergeIDs: Set<UUID> = []
    private var editorPurpose: EditorPurpose = .add
    private var listFrameBeforeEditing: NSRect?
    private var returnToHistory = false

    var onError: ((String) -> Void)?
    var onBackToHistory: (() -> Void)?

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

    func show(returnToHistory: Bool? = nil) {
        if let returnToHistory {
            self.returnToHistory = returnToHistory
        }
        backButton.toolTip = self.returnToHistory ? "返回剪贴板历史" : "返回上一页"
        if !panel.isVisible {
            if !isEditing {
                restorePosition()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            returnToHistory = false
        } else {
            show(returnToHistory: false)
        }
    }

    private func beginEditing(_ purpose: EditorPurpose, prefill: String) {
        show()
        editorPurpose = purpose
        isSelectingMerge = false
        selectedMergeIDs = []
        if !isEditing {
            listFrameBeforeEditing = panel.frame
            isEditing = true
            listScrollView.isHidden = true
            editorView.isHidden = false
            resizeForEditing()
        }
        editButton.isHidden = true
        mergeButton.isHidden = true
        switch purpose {
        case .add:
            titleLabel.stringValue = "添加内容"
            editButton.title = "完成"
            editorInstructionLabel.stringValue = "粘贴或输入内容，先加入清单，再按需拆分"
            addWholeButton?.title = "加入清单"
        case .split:
            titleLabel.stringValue = "拆分现有内容"
            editButton.title = "取消"
            editorInstructionLabel.stringValue = "每行保存为一条；按回车调整拆分位置"
            addWholeButton?.title = "保存拆分"
        case .merge:
            titleLabel.stringValue = "合并现有内容"
            editButton.title = "取消"
            editorInstructionLabel.stringValue = "编辑合并后的文字，保存后替换所选条目"
            addWholeButton?.title = "保存合并"
        }
        editorTextView?.string = prefill
        editorTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        updateHeaderCount()
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
        editorPurpose = .add
        titleLabel.stringValue = "复制清单"
        editButton.title = "添加"
        editButton.isHidden = false
        mergeButton.title = "合并"
        panel.makeFirstResponder(nil)
        editorView.isHidden = true
        listScrollView.isHidden = false
        mergeButton.isHidden = false
        panel.minSize = NSSize(width: 285, height: 180)
        if let saved = listFrameBeforeEditing {
            let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? current
            let x = min(max(current.maxX - saved.width, screen.minX + 12), screen.maxX - saved.width - 12)
            let y = min(max(current.maxY - saved.height, screen.minY + 12), screen.maxY - saved.height - 12)
            panel.setFrame(NSRect(x: x, y: y, width: saved.width, height: saved.height), display: true)
        }
        listFrameBeforeEditing = nil
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
        updateHeaderCount()
        renderRows()
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
        backButton.title = "返回"
        backButton.bezelStyle = .rounded
        backButton.controlSize = .small
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.toolTip = "返回上一页"
        backButton.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        editButton.title = "添加"
        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(openEditor)
        editButton.toolTip = "手动输入内容到复制清单"
        editButton.translatesAutoresizingMaskIntoConstraints = false
        mergeButton.title = "合并"
        mergeButton.bezelStyle = .rounded
        mergeButton.controlSize = .small
        mergeButton.target = self
        mergeButton.action = #selector(mergeAction)
        mergeButton.toolTip = "选择清单中已有的文字条目并合并"
        mergeButton.translatesAutoresizingMaskIntoConstraints = false

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

        root.addSubview(backButton)
        root.addSubview(titleLabel)
        root.addSubview(countLabel)
        root.addSubview(editButton)
        root.addSubview(mergeButton)
        root.addSubview(listScrollView)
        root.addSubview(editorView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: mergeButton.leadingAnchor, constant: -8),
            mergeButton.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -5),
            mergeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
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
        updateHeaderCount()
        mergeButton.isEnabled = isSelectingMerge
            ? selectedMergeIDs.count >= 2
            : store.items.filter { $0.text != nil }.count >= 2
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
            let row = isSelectingMerge ? makeMergeSelectionRow(for: item) : makeRow(for: item)
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
    }

    private func updateHeaderCount() {
        if isEditing {
            switch editorPurpose {
            case .split:
                countLabel.stringValue = "\(CuratedTextSegments.lines(in: editorTextView?.string ?? "").count) 行"
            case let .merge(ids):
                countLabel.stringValue = "\(ids.count) 条"
            case .add:
                countLabel.stringValue = "\(store.items.count) 条"
            }
        } else if isSelectingMerge {
            countLabel.stringValue = "已选 \(selectedMergeIDs.count) 条"
        } else {
            countLabel.stringValue = "\(store.items.count) 条"
        }
    }

    private func makeMergeSelectionRow(for item: ClipboardItem) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 9
        row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor

        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(selectMergeItem(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        checkbox.isEnabled = item.text != nil
        checkbox.state = selectedMergeIDs.contains(item.id) ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSTextField(labelWithString: item.previewText)
        preview.font = .systemFont(ofSize: 12.5, weight: .medium)
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.alignment = .left
        preview.textColor = item.text == nil ? .secondaryLabelColor : .labelColor
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.toolTip = item.text
        preview.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(checkbox)
        row.addSubview(preview)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            checkbox.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            checkbox.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 20),
            preview.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            preview.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            preview.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -9)
        ])
        return row
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
            constraints.append(copyButton.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 8))
        } else {
            constraints.append(preview.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12))
            if item.text != nil {
                let splitButton = NSButton(title: "拆分", target: self, action: #selector(splitItem(_:)))
                splitButton.bezelStyle = .rounded
                splitButton.controlSize = .small
                splitButton.contentTintColor = .controlAccentColor
                splitButton.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
                splitButton.toolTip = "把这条已有文字拆成多条"
                splitButton.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(splitButton)
                constraints.append(contentsOf: [
                    splitButton.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 5),
                    splitButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -2),
                    splitButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    splitButton.widthAnchor.constraint(equalToConstant: 46)
                ])
            } else {
                constraints.append(copyButton.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 8))
            }
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

    @objc private func splitItem(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let text = store.items.first(where: { $0.id == id })?.text else { return }
        beginEditing(.split(id), prefill: text)
    }

    @objc private func selectMergeItem(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              store.items.first(where: { $0.id == id })?.text != nil else { return }
        if sender.state == .on {
            selectedMergeIDs.insert(id)
        } else {
            selectedMergeIDs.remove(id)
        }
        updateHeaderCount()
        mergeButton.isEnabled = selectedMergeIDs.count >= 2
    }

    @objc private func mergeAction() {
        if isSelectingMerge {
            let selected = store.items.filter { selectedMergeIDs.contains($0.id) && $0.text != nil }
            guard selected.count >= 2 else { return }
            beginEditing(
                .merge(selected.map(\.id)),
                prefill: selected.compactMap(\.text).joined(separator: "\n")
            )
        } else {
            guard store.items.filter({ $0.text != nil }).count >= 2 else { return }
            startMergeSelection()
        }
    }

    @objc private func openEditor() {
        beginEditing(.add, prefill: "")
    }

    @objc private func goBack() {
        if isEditing {
            let selected: [UUID]?
            if case let .merge(ids) = editorPurpose {
                selected = ids
            } else {
                selected = nil
            }
            finishEditing()
            if let selected {
                startMergeSelection(restoring: Set(selected))
            }
        } else if isSelectingMerge {
            stopMergeSelection()
        } else {
            let shouldReturnToHistory = returnToHistory
            returnToHistory = false
            panel.orderOut(nil)
            if shouldReturnToHistory {
                onBackToHistory?()
            }
        }
    }

    private func startMergeSelection(restoring selected: Set<UUID> = []) {
        isSelectingMerge = true
        selectedMergeIDs = selected
        titleLabel.stringValue = "选择文字"
        editButton.isHidden = true
        mergeButton.title = "下一步"
        renderRows()
    }

    private func stopMergeSelection() {
        isSelectingMerge = false
        selectedMergeIDs = []
        titleLabel.stringValue = "复制清单"
        editButton.title = "添加"
        editButton.isHidden = false
        mergeButton.title = "合并"
        renderRows()
    }

    private func configureEditorView() {
        editorInstructionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        editorInstructionLabel.translatesAutoresizingMaskIntoConstraints = false

        editorSourceScrollView.hasVerticalScroller = true
        editorSourceScrollView.borderType = .bezelBorder
        editorSourceScrollView.translatesAutoresizingMaskIntoConstraints = false

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
        editorSourceScrollView.documentView = textView
        editorTextView = textView

        let wholeButton = NSButton(title: "加入清单", target: self, action: #selector(commitEditor))
        wholeButton.bezelStyle = .rounded
        wholeButton.translatesAutoresizingMaskIntoConstraints = false
        addWholeButton = wholeButton

        editorView.addSubview(editorInstructionLabel)
        editorView.addSubview(editorSourceScrollView)
        editorView.addSubview(wholeButton)

        NSLayoutConstraint.activate([
            editorInstructionLabel.topAnchor.constraint(equalTo: editorView.topAnchor, constant: 4),
            editorInstructionLabel.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 7),
            editorInstructionLabel.trailingAnchor.constraint(lessThanOrEqualTo: editorView.trailingAnchor, constant: -7),

            editorSourceScrollView.topAnchor.constraint(equalTo: editorInstructionLabel.bottomAnchor, constant: 12),
            editorSourceScrollView.leadingAnchor.constraint(equalTo: editorView.leadingAnchor, constant: 5),
            editorSourceScrollView.trailingAnchor.constraint(equalTo: editorView.trailingAnchor, constant: -5),
            editorSourceScrollView.bottomAnchor.constraint(equalTo: wholeButton.topAnchor, constant: -12),

            wholeButton.trailingAnchor.constraint(equalTo: editorView.trailingAnchor, constant: -5),
            wholeButton.bottomAnchor.constraint(equalTo: editorView.bottomAnchor, constant: -5)
        ])
    }

    private func refreshEditorButtons() {
        guard let textView = editorTextView else { return }
        let text = textView.string
        switch editorPurpose {
        case .add, .merge:
            addWholeButton?.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .split:
            addWholeButton?.isEnabled = CuratedTextSegments.lines(in: text).count >= 2
            updateHeaderCount()
        }
    }

    @objc private func commitEditor() {
        guard let textView = editorTextView else { return }
        do {
            switch editorPurpose {
            case .add:
                try store.addText(textView.string)
                textView.string = ""
                refreshEditorButtons()
            case let .split(id):
                try store.splitText(id, into: CuratedTextSegments.lines(in: textView.string))
                finishEditing()
            case let .merge(ids):
                try store.mergeText(ids, into: textView.string)
                finishEditing()
            }
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
