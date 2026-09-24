import AppKit

@main
struct CurrentClipboardSnapshotTests {
    static func main() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        expect(CurrentClipboardSnapshot.capture(from: pasteboard) == nil, "空剪贴板不应贴出旧历史")
        pasteboard.clearContents()
        pasteboard.setString(" 张三 \u{0000}\n", forType: .string)
        let text = CurrentClipboardSnapshot.capture(from: pasteboard)
        expect(text?.item.text == " 张三 \n", "应读取当前文字并只去除 NUL")
        expect(text?.imageData == nil, "文字不应携带图片")

        pasteboard.clearContents()
        pasteboard.setString(" \n ", forType: .string)
        expect(CurrentClipboardSnapshot.capture(from: pasteboard) == nil, "纯空白不可贴出")

        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let png = image.representation(using: .png, properties: [:])!
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let picture = CurrentClipboardSnapshot.capture(from: pasteboard)
        expect(picture?.item.image?.pixelWidth == 2, "应读取当前图片尺寸")
        expect(picture?.imageData == png, "单独贴出应带原图数据")

        print("CurrentClipboardSnapshot tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
