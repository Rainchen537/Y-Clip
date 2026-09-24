import AppKit

/// 全局“单独贴出”快捷键直接读取当前剪贴板，避免轮询间隔内误贴上一条历史。
struct CurrentClipboardSnapshot {
    let item: ClipboardItem
    let imageData: Data?

    static func capture(from pasteboard: NSPasteboard = .general) -> CurrentClipboardSnapshot? {
        if let value = pasteboard.string(forType: .string) {
            let text = value.replacingOccurrences(of: "\u{0000}", with: "")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return CurrentClipboardSnapshot(item: ClipboardItem(text: text), imageData: nil)
            }
        }

        let originalPNG = pasteboard.data(forType: .png)
        let raw = originalPNG
            ?? pasteboard.data(forType: .tiff)
            ?? (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?
                .first?
                .tiffRepresentation
        guard let raw,
              let bitmap = NSBitmapImageRep(data: raw),
              let png = originalPNG ?? bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let payload = ImagePayload(
            fileName: "current-clipboard.png",  // 临时贴出不依赖磁盘文件
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh,
            digest: ImageDigest.sha256(png)
        )
        return CurrentClipboardSnapshot(
            item: ClipboardItem(kind: .image(payload)),
            imageData: png
        )
    }
}
