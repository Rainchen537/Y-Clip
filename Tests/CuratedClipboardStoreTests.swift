import AppKit
import Foundation

@main
struct CuratedClipboardStoreTests {
    static func main() throws {
        try testManualSelectionAndPersistence()
        try testHistoryImageSurvivesHistoryRemoval()
        print("CuratedClipboardStore tests passed")
    }

    private static func testManualSelectionAndPersistence() throws {
        let text = "姓名：喵🐈\n电话：13800000000\n地址：北京"
        let source = text as NSString
        let nameRange = source.range(of: "喵🐈")
        let phoneRange = source.range(of: "13800000000")
        expect(CuratedTextSelection.fragment(in: text, range: nameRange) == "喵🐈", "表情后的 UTF-16 选区应准确")
        expect(CuratedTextSelection.fragment(in: text, range: phoneRange) == "13800000000", "可选择任意边界的电话片段")
        expect(CuratedTextSelection.fragment(in: text, range: NSRange(location: source.length, length: 2)) == nil, "越界选区应拒绝")
        expect(CuratedTextSelection.fragment(in: " \n ", range: NSRange(location: 0, length: 3)) == nil, "纯空白不应成为条目")
        expect(CuratedTextSelection.fragment(in: " A ", range: NSRange(location: 0, length: 3)) == " A ", "应保留用户划定的空格")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("y-clip-curated-tests-\(UUID())")
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            try? FileManager.default.removeItem(at: directory)
            pasteboard.releaseGlobally()
        }

        let store = try CuratedClipboardStore(directory: directory, pasteboard: pasteboard)
        let name = try store.addText(source.substring(with: nameRange))
        let phone = try store.addText(source.substring(with: phoneRange))
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
