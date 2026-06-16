import AppKit
import CryptoKit
import Foundation

/// 历史项的内容类型。
enum ClipboardKind: Equatable {
    case text(String)
    case image(ImagePayload)
}

/// 图片负载：全图存磁盘，这里只保留元数据（文件名、像素尺寸、内容指纹）。
struct ImagePayload: Codable, Equatable {
    let fileName: String      // images/ 目录下的文件名，如 "<sha>.png"
    let pixelWidth: Int
    let pixelHeight: Int
    let digest: String        // 内容 sha256，用于去重
}

struct ClipboardItem: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: ClipboardKind
    let createdAt: Date

    init(id: UUID = UUID(), kind: ClipboardKind, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }

    /// 便捷构造：纯文本项。
    init(text: String, createdAt: Date = Date()) {
        self.init(kind: .text(text), createdAt: createdAt)
    }

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }

    /// 文本内容（图片项为 nil）。
    var text: String? {
        if case let .text(value) = kind { return value }
        return nil
    }

    /// 图片负载（文本项为 nil）。
    var image: ImagePayload? {
        if case let .image(payload) = kind { return payload }
        return nil
    }

    /// 列表中显示的预览文字。图片项给出尺寸描述。
    var previewText: String {
        switch kind {
        case let .text(value):
            return value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case let .image(payload):
            return "图片 · \(payload.pixelWidth)×\(payload.pixelHeight)"
        }
    }

    /// 去重键：文本用规范化后的正文，图片用内容指纹。
    var dedupeKey: String {
        switch kind {
        case let .text(value):
            return "t:" + value
        case let .image(payload):
            return "i:" + payload.digest
        }
    }
}

// MARK: - Codable（手写以兼容旧版「仅 text 字段」的历史文件）

extension ClipboardItem {
    private enum CodingKeys: String, CodingKey {
        case id, text, image, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        // 优先图片，其次文本；都没有时回退为空文本（不抛错，避免整份历史解码失败）。
        if let payload = try container.decodeIfPresent(ImagePayload.self, forKey: .image) {
            kind = .image(payload)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .text) {
            kind = .text(value)
        } else {
            kind = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)

        switch kind {
        case let .text(value):
            try container.encode(value, forKey: .text)
        case let .image(payload):
            try container.encode(payload, forKey: .image)
        }
    }
}

// MARK: - 图片指纹

enum ImageDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
