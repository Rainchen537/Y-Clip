import Foundation

/// NSTextView 的选区使用 UTF-16 下标；用 NSString 按同一口径截取，避免表情等字符错位。
enum CuratedTextSelection {
    static func fragment(in text: String, range: NSRange) -> String? {
        let source = text as NSString
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= source.length else {
            return nil
        }
        let fragment = source.substring(with: range)
        return fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fragment
    }
}
