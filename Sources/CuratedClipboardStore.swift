import AppKit
import Foundation

enum CuratedClipboardError: LocalizedError {
    case emptyText
    case missingImage

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "请先选中或输入要添加的内容。"
        case .missingImage:
            return "原图片已不在剪贴板历史中，无法加入精选面板。"
        }
    }
}

/// 精选面板有自己的存储区，避免普通历史淘汰时删掉用户挑选的图片。
final class CuratedClipboardStore {
    private let directory: URL
    private let saveURL: URL
    private let imagesDirectory: URL
    private let pasteboard: NSPasteboard

    private(set) var items: [ClipboardItem]
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

    private func replaceItems(_ next: [ClipboardItem]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: saveURL, options: [.atomic])
        items = next
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
