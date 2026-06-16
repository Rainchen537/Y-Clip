import AppKit
import Foundation

// 生成 README 用的「历史面板」演示图（纯合成，无真实背景，安全可公开）。
// 还原 app 面板外观：深色毛玻璃底 + 标题 + 若干历史块（含一张图片缩略图块）。

let scale = 2.0
let W = 760.0, H = 560.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W*scale), pixelsHigh: Int(H*scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
ctx.cgContext.scaleBy(x: scale, y: scale)

func rr(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }

// 背景：柔和渐变画布（仅用于让面板有立体感）
let canvas = NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.47, blue: 0.58, alpha: 1),
    NSColor(calibratedRed: 0.28, green: 0.32, blue: 0.42, alpha: 1)])!
canvas.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// 面板
let panel = NSRect(x: 210, y: 40, width: 340, height: 480)
ctx.cgContext.saveGState()
ctx.cgContext.setShadow(offset: CGSize(width: 0, height: -8), blur: 40, color: NSColor(white: 0, alpha: 0.4).cgColor)
NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 0.98).setFill()
rr(panel, 16).fill()
ctx.cgContext.restoreGState()

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, maxW: CGFloat? = nil) {
    let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
    let str = NSAttributedString(string: s, attributes: a)
    if let maxW { str.draw(with: NSRect(x: x, y: y, width: maxW, height: size*1.6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }
    else { str.draw(at: NSPoint(x: x, y: y)) }
}

// 标题区（顶部，注意 AppKit 坐标系原点在左下）
let titleY = panel.maxY - 44
text("剪贴板历史", panel.minX + 22, titleY, size: 16, weight: .semibold, color: NSColor(white: 0.97, alpha: 1))
text("↑↓ 选择 · Enter 粘贴 · Esc 关闭", panel.minX + 22, titleY - 22, size: 11, weight: .regular, color: NSColor(white: 0.55, alpha: 1))

// 历史块
struct Row { let image: Bool; let title: String; let selected: Bool }
let rows = [
    Row(image: false, title: "晚上 7 点团队同步会，带上季度数据", selected: true),
    Row(image: true,  title: "图片 · 1920×1080", selected: false),
    Row(image: false, title: "npm install && npm run dev", selected: false),
    Row(image: false, title: "这是一段较长的剪贴板文本示例，展示多行预览与省略效果，方便快速辨认内容。", selected: false),
    Row(image: false, title: "user@example.com", selected: false),
]

var ry = panel.maxY - 92
let rowH = 64.0, gap = 6.0
let rowX = panel.minX + 10, rowW = panel.width - 20

for row in rows {
    let rect = NSRect(x: rowX, y: ry - rowH, width: rowW, height: rowH)
    if row.selected { NSColor.controlAccentColor.withAlphaComponent(0.22).setFill() }
    else { NSColor(white: 1, alpha: 0.05).setFill() }
    rr(rect, 8).fill()

    if row.image {
        // 缩略图占位（青色块）
        let side = rowH - 20
        let thumb = NSRect(x: rect.minX + 12, y: rect.midY - side/2, width: side, height: side)
        NSColor.systemTeal.setFill(); rr(thumb, 5).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        rr(NSRect(x: thumb.minX + side*0.28, y: thumb.minY + side*0.28, width: side*0.44, height: side*0.44), 3).fill()
        text(row.title, thumb.maxX + 12, rect.midY - 7, size: 13, weight: .medium, color: NSColor(white: 0.6, alpha: 1))
    } else {
        text(row.title, rect.minX + 14, rect.midY - 8, size: 13, weight: .medium,
             color: NSColor(white: 0.95, alpha: 1), maxW: rowW - 28)
    }
    ry -= (rowH + gap)
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError() }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hero.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
