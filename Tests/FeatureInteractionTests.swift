import AppKit
import Carbon
import CoreGraphics
import Foundation

@main
struct FeatureInteractionTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        try testLongSnippet()
        testHistoryActionShortcuts()
        try testCuratedUndo()
        print("FeatureInteraction tests passed")
    }

    private static func testLongSnippet() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let content = (1...80).map { "第\($0)行：模拟长文字内容" }.joined(separator: "\n")
        let controller = StandaloneSnippetController(item: ClipboardItem(text: content), imageData: nil, pasteboard: board)
        controller.show(near: NSPoint(x: 200, y: 400))
        guard let panel = NSApp.windows.first(where: { $0.isVisible }),
              let scrollView = panel.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
              let textView = scrollView.documentView as? NSTextView,
              let manager = textView.layoutManager,
              let container = textView.textContainer else { fatalError("长文字滚动区不存在") }
        panel.contentView?.layoutSubtreeIfNeeded()
        manager.ensureLayout(for: container)
        expect(manager.usedRect(for: container).height > scrollView.contentView.bounds.height,
               "测试文字应长于可见区域")
        expect(textView.isSelectable && !textView.isEditable, "滚动区应允许选字且不可修改")

        scrollView.contentView.scroll(to: .zero)
        let optionWheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                  wheel1: -10, wheel2: 0, wheel3: 0)!
        optionWheel.flags = [.maskAlternate]
        textView.scrollWheel(with: NSEvent(cgEvent: optionWheel)!)
        expect(scrollView.contentView.bounds.origin.y > 0, "Option+滚轮应滚动文字")
        let widthBeforeZoom = panel.frame.width
        let regularWheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                   wheel1: 2, wheel2: 0, wheel3: 0)!
        textView.scrollWheel(with: NSEvent(cgEvent: regularWheel)!)
        expect(panel.frame.width > widthBeforeZoom, "普通滚轮应继续缩放")

        textView.setSelectedRange((content as NSString).range(of: "第1行"))
        panel.sendEvent(key(UInt16(kVK_ANSI_C), flags: .command, text: "c", in: panel))
        expect(board.string(forType: .string) == "第1行", "选区复制应只包含选中文字")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        panel.sendEvent(key(UInt16(kVK_ANSI_C), flags: .command, text: "c", in: panel))
        expect(board.string(forType: .string) == content, "无选区时应复制整条原文")
        panel.sendEvent(key(UInt16(kVK_Delete), in: panel))
        expect(!panel.isVisible, "Delete 应移除贴出浮窗")
    }

    private static func testHistoryActionShortcuts() {
        let first = ClipboardItem(text: "姓名")
        let second = ClipboardItem(text: "电话")
        let controller = ClipboardPanelController()
        var added: UUID?
        var stuck: UUID?
        controller.onAddToCurated = { added = $0.id }
        controller.onStickOut = { stuck = $0.id }
        controller.show(items: [first, second], metrics: .default,
                        near: NSPoint(x: 300, y: 300), pinned: false, pinnedFrame: nil,
                        onChoose: { _ in }, onClose: {})
        guard let panel = NSApp.windows.first(where: { $0.isVisible }) else { fatalError("历史面板不存在") }
        let dragHandle = panel.contentView.flatMap { root in
            descendants(of: root).first { String(describing: type(of: $0)).contains("ClipboardPanelDragHandleView") }
        }
        expect(panel.isMovableByWindowBackground && panel.contentView?.mouseDownCanMoveWindow == true,
               "临时历史面板的空白背景应可拖动")
        expect(dragHandle?.isHidden == false, "临时历史面板顶部应有可拖动区域")
        panel.sendEvent(key(UInt16(kVK_ANSI_A), flags: [.command, .shift], in: panel))
        expect(added == first.id, "加入快捷键应作用于高亮条目")
        panel.sendEvent(key(UInt16(kVK_DownArrow), in: panel))
        panel.sendEvent(key(UInt16(kVK_ANSI_P), flags: [.command, .shift], in: panel))
        expect(stuck == second.id, "贴出快捷键应作用于新的高亮条目")
        controller.addSelectedHotKey = HotKey(keyCode: UInt32(kVK_ANSI_J),
                                               modifiers: UInt32(controlKey) | UInt32(cmdKey))
        added = nil
        panel.sendEvent(key(UInt16(kVK_ANSI_A), flags: [.command, .shift], in: panel))
        expect(added == nil, "修改后旧快捷键应失效")
        panel.sendEvent(key(UInt16(kVK_ANSI_J), flags: [.control, .command], in: panel))
        expect(added == second.id, "自定义快捷键应生效")
        controller.show(items: [first, second], metrics: .default,
                        near: NSPoint(x: 300, y: 300), pinned: true, pinnedFrame: nil,
                        onChoose: { _ in }, onClose: {})
        expect(panel.isMovableByWindowBackground && dragHandle?.isHidden == false,
               "固定历史面板仍应可拖动")
        panel.orderOut(nil)
    }

    private static func testCuratedUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("y-clip-undo-ui-\(UUID())")
        let board = NSPasteboard.withUniqueName()
        defer {
            try? FileManager.default.removeItem(at: directory)
            board.releaseGlobally()
        }
        let store = try CuratedClipboardStore(directory: directory, pasteboard: board)
        let original = try store.addText("姓名：张三 电话：13800000000")
        let controller = CuratedClipboardPanelController(store: store)
        controller.show(returnToHistory: false)
        guard let panel = NSApp.windows.first(where: { $0.isVisible }), let root = panel.contentView else {
            fatalError("复制清单不存在")
        }
        button(in: root, title: "拆分", id: original.id).performClick(nil)
        guard let editor = descendants(of: root).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable }) else {
            fatalError("拆分编辑框不存在")
        }
        let offset = (editor.string as NSString).range(of: "电话").location
        editor.insertText("\n", replacementRange: NSRange(location: offset, length: 0))
        button(in: root, title: "保存拆分").performClick(nil)
        expect(store.items.count == 2 && store.canUndoLastEdit, "拆分后应提供撤销")
        button(in: root, title: "撤销上次编辑").performClick(nil)
        expect(store.items.count == 1 && store.items[0].id == original.id,
               "撤销应恢复原条目和 ID")
        panel.close()
    }

    private static func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [],
                            text: String = "", in panel: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                         characters: text, charactersIgnoringModifiers: text,
                         isARepeat: false, keyCode: code)!
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func button(in view: NSView, title: String, id: UUID? = nil) -> NSButton {
        guard let button = descendants(of: view).compactMap({ $0 as? NSButton }).first(where: {
            $0.title == title && (id == nil || $0.identifier?.rawValue == id!.uuidString)
        }) else { fatalError("按钮不存在：\(title)") }
        return button
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
