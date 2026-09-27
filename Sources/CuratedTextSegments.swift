import Foundation

/// 回车分行后的每个非空行，在清单中成为一条可独立复制的内容。
enum CuratedTextSegments {
    /// 拆分时以回车为边界；空白行不会生成不可复制的条目。
    static func lines(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
