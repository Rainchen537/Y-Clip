import AppKit
import Foundation

@main
struct CuratedClipboardStoreTests {
    static func main() throws {
        try testManualEntryAndPersistence()
        try testSplitAndMergeExistingRows()
        try testUndoSplitAndMerge()
        try testHistoryImageSurvivesHistoryRemoval()
        print("CuratedClipboardStore tests passed")
    }

    private static func testSplitAndMergeExistingRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("y-clip-curated-edit-tests-\(UUID())")
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            try? FileManager.default.removeItem(at: directory)
            pasteboard.releaseGlobally()
        }

        let store = try CuratedClipboardStore(directory: directory, pasteboard: pasteboard)
        let source = try store.addText("姓名：张三 电话：13800000000")
        _ = try store.addText("备注")
        let address = try store.addText("北京市示例路")
        let segments = try store.splitText(source.id, into: ["张三", "13800000000"])
        expect(store.items.compactMap(\.text) == ["姓名：张三 电话：13800000000", "备注", "北京市示例路"], "拆分后首页应保留原整段")
        expect(store.detailItems(for: source.id).map(\.id) == segments.map(\.id), "拆分行应只归属原条目详情")
        expect(store.copyDetailToPasteboard(segments[1], parentID: source.id), "详情行应可独立复制")
        expect(pasteboard.string(forType: .string) == "13800000000", "详情行复制不应包含原整段")
        let reopenedSplit = try CuratedClipboardStore(directory: directory, pasteboard: pasteboard)
        expect(reopenedSplit.detailItems(for: source.id).map(\.text) == ["张三", "13800000000"], "拆分详情应持久化")

        do {
            _ = try store.splitText(source.id, into: ["仅一段"])
            fatalError("单段不应覆盖原条目")
        } catch CuratedClipboardError.requiresTwoSegments {
            expect(store.detailItems(for: source.id).map(\.id) == segments.map(\.id), "拆分无效时原详情应保留")
        }

        let merged = try store.mergeText([address.id, source.id], into: "张三\n北京市示例路")
        expect(store.items.compactMap(\.text) == ["张三\n北京市示例路", "备注"], "合并应只处理首页所选条目")
        expect(store.items[0].id == merged.id, "合并结果应有独立 ID")
        let reopened = try CuratedClipboardStore(directory: directory, pasteboard: pasteboard)
        expect(reopened.items.compactMap(\.text) == store.items.compactMap(\.text), "拆分和合并结果应持久化")
        expect(reopened.detailItems(for: source.id).isEmpty, "合并后旧条目的详情不应留在可见清单")
        expect(reopened.detailItems(for: merged.id).compactMap(\.text) == ["张三", "13800000000", "北京市示例路"],
               "合并应把原详情行带入合并条目，避免丢失")
    }

    private static func testManualEntryAndPersistence() throws {
        expect(CuratedTextSegments.lines(in: "张三\r\n13800000000\n\n 北京 ") == ["张三", "13800000000", " 北京 "], "回车应逐行拆分，跳过空行并保留文字边界")
        expect(CuratedTextSegments.lines(in: "learntyping2") == ["learntyping2"], "单行内容默认仍是一条")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("y-clip-curated-tests-\(UUID())")
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            try? FileManager.default.removeItem(at: directory)
            pasteboard.releaseGlobally()
        }

        let store = try CuratedClipboardStore(directory: directory, pasteboard: pasteboard)
        let name = try store.addText("喵🐈")
        let phone = try store.addText("13800000000")
        expect(store.items.map(\.text) == ["喵🐈", "13800000000"], "条目应按用户添加顺序保存")
        expect(store.copyToPasteboard(phone), "电话条目应能独立复制")
        expect(pasteboard.string(forType: .string) == "13800000000", "独立复制不应包含姓名")

        let reopened = try CuratedClipboardStore(directory: directory, pasteboard: pasteboard)
        expect(reopened.items.map(\.id) == [name.id, phone.id], "重新打开后应恢复精选顺序")
        try reopened.remove(name.id)
        expect(reopened.items.map(\.id) == [phone.id], "移除一条不应改变另一条")
        let afterRemove = try CuratedClipboardStore(directory: directory, pasteboard: pasteboard)
        expect(afterRemove.items.count == 1, "移除后应持久化")
    }

    private static func testUndoSplitAndMerge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("y-clip-curated-undo-\(UUID())")
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            try? FileManager.default.removeItem(at: directory)
            pasteboard.releaseGlobally()
        }
        let store = try CuratedClipboardStore(directory: directory, pasteboard: pasteboard)
        let original = try store.addText("姓名：张三\n电话：13800000000")
        let address = try store.addText("地址：示例路")
        _ = try store.splitText(original.id, into: ["姓名：张三", "电话：13800000000"])
        expect(store.canUndoLastEdit, "拆分后应允许撤销")
        try store.undoLastEdit()
        expect(store.items.map(\.id) == [original.id, address.id], "撤销拆分应恢复原内容及 ID")
        expect(store.detailItems(for: original.id).isEmpty, "撤销拆分应移除详情行")
        expect(!store.canUndoLastEdit, "一次撤销后不应重复撤销")

        let details = try store.splitText(original.id, into: ["姓名：张三", "电话：13800000000"])
        _ = try store.mergeText([original.id, address.id], into: "合并结果")
        expect(store.canUndoLastEdit, "合并后应允许撤销")
        try store.undoLastEdit()
        expect(store.items.map(\.id) == [original.id, address.id], "撤销合并应恢复原顺序")
        expect(store.items[0].text == "姓名：张三\n电话：13800000000", "撤销合并应恢复原文")
        expect(store.detailItems(for: original.id).map(\.id) == details.map(\.id), "撤销合并应恢复原详情")

        _ = try store.splitText(original.id, into: ["姓名：张三", "电话：13800000000"])
        _ = try store.addText("新条目")
        expect(!store.canUndoLastEdit, "后续修改应使旧撤销失效")
    }

    private static func testHistoryImageSurvivesHistoryRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("y-clip-curated-image-tests-\(UUID())")
        let source = directory.appendingPathComponent("history-image.png")
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            try? FileManager.default.removeItem(at: directory)
            pasteboard.releaseGlobally()
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        try imageData.write(to: source)
        let payload = ImagePayload(fileName: "history-image.png", pixelWidth: 2, pixelHeight: 1, digest: "test")
        let historyItem = ClipboardItem(kind: .image(payload))
        let store = try CuratedClipboardStore(directory: directory.appendingPathComponent("curated"), pasteboard: pasteboard)
        let added = try store.addFromHistory(historyItem, imageURL: source)
        try FileManager.default.removeItem(at: source)
        expect(added.image != nil, "精选图片应保持图片类型")
        expect(store.copyToPasteboard(added), "历史原图删除后仍应能复制精选图片")
        expect(pasteboard.data(forType: .png) == imageData, "复制的应是精选区保存的原图")

        let reopened = try CuratedClipboardStore(directory: directory.appendingPathComponent("curated"), pasteboard: pasteboard)
        expect(reopened.items.count == 1, "精选图片应在重新打开后保留")
        let text = try reopened.addText("文字")
        do {
            _ = try reopened.mergeText([added.id, text.id], into: "无效合并")
            fatalError("图片不可合并为文字")
        } catch CuratedClipboardError.textOnly {
            expect(reopened.items.count == 2, "拒绝图片合并时应保留原数据")
        }
        try reopened.remove(added.id)
        let copiedImageURL = store.imageURL(for: added.image!)!
        expect(!FileManager.default.fileExists(atPath: copiedImageURL.path), "移除精选图片应清理专用副本")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
