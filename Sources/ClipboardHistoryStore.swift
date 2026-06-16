import AppKit
import Foundation

final class ClipboardHistoryStore {
    static let defaultMaxItems = 50

    private let pasteboard = NSPasteboard.general
    private let saveURL: URL
    private let imagesDir: URL
    private var timer: Timer?
    private var lastChangeCount: Int
    private var observers: [([ClipboardItem]) -> Void] = []

    private(set) var items: [ClipboardItem] = [] {
        didSet {
            save()
            notifyObservers()
        }
    }

    var maxItems: Int {
        didSet {
            maxItems = max(1, maxItems)
            trimToMaxItems()
        }
    }

    init(maxItems: Int = ClipboardHistoryStore.defaultMaxItems) {
        self.maxItems = max(1, maxItems)
        lastChangeCount = pasteboard.changeCount
        saveURL = Self.makeSaveURL()
        imagesDir = saveURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        load()
        trimToMaxItems()
        captureCurrentClipboard()
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
    }

    func observe(_ observer: @escaping ([ClipboardItem]) -> Void) {
        observers.append(observer)
        observer(items)
    }

    func clear() {
        items.removeAll()
        // 清空历史时一并删除所有图片文件。
        try? FileManager.default.removeItem(at: imagesDir)
    }

    /// 把某个历史项写回系统剪贴板，并将其提到历史最前（成为「当前」内容）。
    func writeToPasteboard(_ item: ClipboardItem) {
        pasteboard.clearContents()

        switch item.kind {
        case let .text(value):
            pasteboard.setString(value, forType: .string)
        case let .image(payload):
            if let data = try? Data(contentsOf: imageURL(for: payload)) {
                pasteboard.setData(data, forType: .png)
            }
        }

        lastChangeCount = pasteboard.changeCount
        promoteToFront(item)
    }

    /// 读取某图片项对应的全图 URL。
    func imageURL(for payload: ImagePayload) -> URL {
        imagesDir.appendingPathComponent(payload.fileName)
    }

    private func pollPasteboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = changeCount
        captureCurrentClipboard()
    }

    private func captureCurrentClipboard() {
        // 优先捕获文本；没有文本再尝试图片。
        if let text = pasteboard.string(forType: .string),
           !sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(text: sanitize(text))
            return
        }

        if let payload = readImageFromPasteboard() {
            add(image: payload)
        }
    }

    /// 从剪贴板读取图片，落盘为 PNG，返回元数据负载（失败返回 nil）。
    private func readImageFromPasteboard() -> ImagePayload? {
        // 直接拿 PNG/TIFF 数据，统一转成 PNG 存储。
        let raw: Data? = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff)
            ?? (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?
                .first?
                .tiffRepresentation

        guard
            let data = raw,
            let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        let digest = ImageDigest.sha256(png)
        let fileName = "\(digest).png"
        let url = imagesDir.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try png.write(to: url, options: [.atomic])
            }
        } catch {
            NSLog("Failed to persist clipboard image: \(error)")
            return nil
        }

        return ImagePayload(
            fileName: fileName,
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh,
            digest: digest
        )
    }

    private func add(text: String, createdAt: Date = Date()) {
        let cleaned = sanitize(text)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        insert(ClipboardItem(text: cleaned, createdAt: createdAt))
    }

    private func add(image payload: ImagePayload, createdAt: Date = Date()) {
        insert(ClipboardItem(kind: .image(payload), createdAt: createdAt))
    }

    /// 插入新项到最前，按 dedupeKey 去重，并执行容量淘汰。
    private func insert(_ item: ClipboardItem) {
        var next = items
        next.removeAll { $0.dedupeKey == item.dedupeKey }
        next.insert(item, at: 0)

        if next.count > maxItems {
            next.removeLast(next.count - maxItems)
        }

        items = next
        pruneOrphanImages()
    }

    private func trimToMaxItems() {
        guard items.count > maxItems else {
            return
        }

        items.removeLast(items.count - maxItems)
        pruneOrphanImages()
    }

    /// 把已有项提到最前（用于选中后置顶）。若不在历史中则按新项插入。
    private func promoteToFront(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.dedupeKey == item.dedupeKey }) {
            guard index != 0 else { return }
            var next = items
            let existing = next.remove(at: index)
            next.insert(existing, at: 0)
            items = next
        } else {
            insert(item)
        }
    }

    /// 删除磁盘上不再被任何历史项引用的图片文件。
    private func pruneOrphanImages() {
        let referenced = Set(items.compactMap { $0.image?.fileName })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: imagesDir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{0000}", with: "")
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else {
            return
        }

        do {
            items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            items = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: saveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(items)
            try data.write(to: saveURL, options: [.atomic])
        } catch {
            NSLog("Failed to save clipboard history: \(error)")
        }
    }

    private func notifyObservers() {
        observers.forEach { $0(items) }
    }

    private static func makeSaveURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return appSupport
            .appendingPathComponent("GlobalClipboard", isDirectory: true)
            .appendingPathComponent("history.json")
    }
}
