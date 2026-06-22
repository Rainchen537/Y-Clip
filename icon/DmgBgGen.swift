import AppKit
import Foundation

// 生成 DMG 安装窗口的背景图。
// 设计与 app 图标一致的深色石墨调，中间一个「拖入」箭头提示。
// Finder 的 DMG 背景图按像素原尺寸铺放，不会因为 Retina 自动按 @2x 缩放。
// 因此背景图必须和 make_dmg.sh 里的窗口尺寸一比一匹配：640×400。

let scale = 1.0
let w = 640.0 * scale
let h = 400.0 * scale

// 用显式 bitmap rep 按精确像素绘制，避开 NSImage.lockFocus 在 Retina 屏的自动缩放。
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(w),
    pixelsHigh: Int(h),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

let full = CGRect(x: 0, y: 0, width: w, height: h)

// 背景渐变（深石墨）
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1.0),
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
])!
bg.draw(in: full, angle: -90)

func draw(_ s: String, _ font: NSFont, _ color: NSColor, centerX: CGFloat, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    let size = str.size()
    str.draw(at: CGPoint(x: centerX - size.width / 2, y: y))
}

// 标题
draw("Y-Clip", NSFont.systemFont(ofSize: 30 * scale, weight: .semibold),
     NSColor(white: 0.97, alpha: 1.0), centerX: w / 2, y: h - 78 * scale)
draw("将左侧应用拖入右侧「应用程序」文件夹即可安装",
     NSFont.systemFont(ofSize: 14 * scale, weight: .regular),
     NSColor(white: 0.62, alpha: 1.0), centerX: w / 2, y: h - 112 * scale)

// 中间箭头（图标中心在 y≈190 逻辑坐标，从底部量）。两图标 x=165 / x=475。
// 箭头画在两者之间 x≈320，水平指向右。
let arrowY = (400.0 - 190.0) * scale  // 从顶部 190 → 转成自底部坐标
let cy = h - arrowY
let arrowColor = NSColor(calibratedRed: 0.46, green: 0.72, blue: 1.0, alpha: 0.9)
arrowColor.setStroke()
arrowColor.setFill()

let shaft = NSBezierPath()
shaft.lineWidth = 8 * scale
shaft.lineCapStyle = .round
shaft.move(to: CGPoint(x: 270 * scale, y: cy))
shaft.line(to: CGPoint(x: 360 * scale, y: cy))
shaft.stroke()

let head = NSBezierPath()
head.move(to: CGPoint(x: 358 * scale, y: cy + 16 * scale))
head.line(to: CGPoint(x: 386 * scale, y: cy))
head.line(to: CGPoint(x: 358 * scale, y: cy - 16 * scale))
head.lineWidth = 8 * scale
head.lineJoinStyle = .round
head.lineCapStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("encode failed")
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_bg.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
