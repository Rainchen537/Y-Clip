import AppKit
import Foundation

enum CuratedClipboardError: LocalizedError {
    case emptyText
    case missingImage
    case itemUnavailable
    case textOnly
    case requiresTwoSegments
    case requiresTwoItems
    case nothingToUndo

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "请先输入要保存的文字内容。"
        case .missingImage:
            return "原图片已不在剪贴板历史中，无法加入复制清单。"
        case .itemUnavailable:
            return "要编辑的内容已不在复制清单中。"
        case .textOnly:
            return "目前只能拆分或合并文字内容。"
        case .requiresTwoSegments:
            return "请至少用回车分成两行，再保存拆分。"
        case .requiresTwoItems:
            return "请至少选中两条文字，再合并。"
        case .nothingToUndo:
            return "没有可撤销的拆分或合并。"
        }
    }
}

/// 复制清单有自己的存储区，避免普通历史淘汰时删掉用户挑选的图片。
final class CuratedClipboardStore {
    private let directory: URL
    private let saveURL: URL
    private let imagesDirectory: URL
    private let pasteboard: NSPasteboard

    private(set) var items: [ClipboardItem]
    private var undoItems: [ClipboardItem]?
    var canUndoLastEdit: Bool { undoItems != nil }
    var onChange: (([ClipboardItem]) -> Void)?

    init(
        directory: URL = CuratedClipboardStore.defaultDirectory(),
        pasteboard: NSPasteboard = .general
    ) throws {
        self.directory = directory
        self.pasteboard = pasteboard
        saveURL = directory.appendingPathComponent("items.json")
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)

        if FileManager.default.fileExists(atPath: saveURL.path) {
            let data = try Data(contentsOf: saveURL)
            items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        } else {
            items = []
        }
    }

    @discardableResult
    func addText(_ text: String) throws -> ClipboardItem {
        // 保留用户划定的准确边界，包括片段两端的空格和换行。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CuratedClipboardError.emptyText
        }
        let item = ClipboardItem(text: text)
        try replaceItems(items + [item])
        return item
    }

    @discardableResult
    func addFromHistory(_ item: ClipboardItem, imageURL: URL?) throws -> ClipboardItem {
        switch item.kind {
        case let .text(text):
            return try addText(text)
        case let .image(payload):
            guard let imageURL, FileManager.default.fileExists(atPath: imageURL.path) else {
                throw CuratedClipboardError.missingImage
            }

            try FileManager.default.createDirectory(
                at: imagesDirectory,
                withIntermediateDirectories: true
            )
            let fileName = UUID().uuidString + ".png"
            let destination = imagesDirectory.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: imageURL, to: destination)

            let copiedPayload = ImagePayload(
                fileName: fileName,
                pixelWidth: payload.pixelWidth,
                pixelHeight: payload.pixelHeight,
                digest: payload.digest
            )
            let copiedItem = ClipboardItem(kind: .image(copiedPayload))
            do {
                try replaceItems(items + [copiedItem])
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return copiedItem
        }
    }

    func remove(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }) else {
            return
        }
        try replaceItems(items.filter { $0.id != id })
        if let payload = item.image,
           !items.contains(where: { $0.image?.fileName == payload.fileName }),
           let imageURL = imageURL(for: payload) {
            try? FileManager.default.removeItem(at: imageURL)
        }
    }

    @discardableResult
    func splitText(_ id: UUID, into segments: [String]) throws -> [ClipboardItem] {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw CuratedClipboardError.itemUnavailable
        }
        guard items[index].text != nil else {
            throw CuratedClipboardError.textOnly
        }
        guard segments.count >= 2 else {
            throw CuratedClipboardError.requiresTwoSegments
        }
        guard segments.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CuratedClipboardError.emptyText
        }

        let replacements = segments.map { ClipboardItem(text: $0) }
        var next = items
        next.replaceSubrange(index...index, with: replacements)
        try replaceItems(next, undoSnapshot: items)
        return replacements
    }

    @discardableResult
    func mergeText(_ ids: [UUID], into text: String) throws -> ClipboardItem {
        let selected = Set(ids)
        guard selected.count >= 2 else {
            throw CuratedClipboardError.requiresTwoItems
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CuratedClipboardError.emptyText
        }
        guard items.filter({ selected.contains($0.id) }).count == selected.count else {
            throw CuratedClipboardError.itemUnavailable
        }
        guard items.filter({ selected.contains($0.id) }).allSatisfy({ $0.text != nil }) else {
            throw CuratedClipboardError.textOnly
        }

        let firstIndex = items.firstIndex(where: { selected.contains($0.id) })!
        let merged = ClipboardItem(text: text)
        let next = items.enumerated().compactMap { index, item -> ClipboardItem? in
            guard selected.contains(item.id) else { return item }
            return index == firstIndex ? merged : nil
        }
        try replaceItems(next, undoSnapshot: items)
        return merged
    }

    func undoLastEdit() throws {
        guard let undoItems else { throw CuratedClipboardError.nothingToUndo }
        try replaceItems(undoItems)
    }

    func imageURL(for payload: ImagePayload) -> URL? {
        guard payload.fileName.hasSuffix(".png"),
              UUID(uuidString: String(payload.fileName.dropLast(4))) != nil else {
            return nil
        }
        return imagesDirectory.appendingPathComponent(payload.fileName)
    }

    @discardableResult
    func copyToPasteboard(_ item: ClipboardItem) -> Bool {
        guard items.contains(where: { $0.id == item.id }) else {
            return false
        }

        switch item.kind {
        case let .text(text):
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        case let .image(payload):
            guard let imageURL = imageURL(for: payload),
                  let data = try? Data(contentsOf: imageURL) else {
                return false
            }
            pasteboard.clearContents()
            return pasteboard.setData(data, forType: .png)
        }
    }

    private func replaceItems(_ next: [ClipboardItem], undoSnapshot: [ClipboardItem]? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: saveURL, options: [.atomic])
        items = next
        undoItems = undoSnapshot
        onChange?(items)
    }

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupport
            .appendingPathComponent("GlobalClipboard", isDirectory: true)
            .appendingPathComponent("curated", isDirectory: true)
    }
}
