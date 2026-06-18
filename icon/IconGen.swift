import AppKit
import Foundation

// 离屏绘制 1024x1024 的 app 图标主图，输出 PNG。
// 设计：留出 macOS 图标安全边距，浅色圆角底板 + 柔和渐变层叠剪切板。

let size: CGFloat = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
bitmap.size = NSSize(width: size, height: size)

let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
let ctx = graphicsContext.cgContext

ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawLinearGradient(
    colors: [NSColor],
    in rect: CGRect,
    start: CGPoint,
    end: CGPoint,
    clippedTo path: NSBezierPath? = nil
) {
    ctx.saveGState()
    path?.addClip()
    let cgColors = colors.map { $0.cgColor } as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil) else {
        ctx.restoreGState()
        return
    }
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX + rect.width * start.x, y: rect.minY + rect.height * start.y),
        end: CGPoint(x: rect.minX + rect.width * end.x, y: rect.minY + rect.height * end.y),
        options: []
    )
    ctx.restoreGState()
}

func drawShadowedPath(
    _ path: NSBezierPath,
    fill: NSColor,
    shadowOffset: CGSize,
    shadowBlur: CGFloat,
    shadowColor: NSColor
) {
    ctx.saveGState()
    ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor.cgColor)
    fill.setFill()
    path.fill()
    ctx.restoreGState()
}

func drawGradientBorder(
    rect: CGRect,
    radius: CGFloat,
    strokeWidth: CGFloat,
    colors: [NSColor]
) {
    ctx.saveGState()
    let outer = roundedRect(rect, radius)
    outer.addClip()
    let inner = roundedRect(rect.insetBy(dx: strokeWidth, dy: strokeWidth), radius - strokeWidth)
    inner.append(NSBezierPath(rect: rect))
    inner.windingRule = .evenOdd
    inner.addClip()
    drawLinearGradient(
        colors: colors,
        in: rect,
        start: CGPoint(x: 0.05, y: 0.90),
        end: CGPoint(x: 0.95, y: 0.05)
    )
    ctx.restoreGState()
}

func drawLine(_ rect: CGRect, alpha: CGFloat = 1) {
    NSColor(calibratedRed: 0.82, green: 0.84, blue: 0.87, alpha: alpha).setFill()
    roundedRect(rect, rect.height / 2).fill()
}

let iconRect = CGRect(x: 88, y: 88, width: 848, height: 848)
let iconRadius = iconRect.width * 0.225

// 底板，比画布略小，避免在 macOS 里看起来比其他 app 大一圈。
let platePath = roundedRect(iconRect, iconRadius)
drawShadowedPath(
    platePath,
    fill: NSColor(calibratedRed: 0.965, green: 0.955, blue: 0.925, alpha: 1),
    shadowOffset: CGSize(width: 0, height: -18),
    shadowBlur: 44,
    shadowColor: NSColor(white: 0, alpha: 0.24)
)

drawLinearGradient(
    colors: [
        NSColor(calibratedRed: 1.00, green: 0.995, blue: 0.970, alpha: 1),
        NSColor(calibratedRed: 0.935, green: 0.955, blue: 0.920, alpha: 1)
    ],
    in: iconRect,
    start: CGPoint(x: 0.20, y: 0.95),
    end: CGPoint(x: 0.90, y: 0.05),
    clippedTo: platePath
)

// 微弱内高光，让浅色底板不显得平。
ctx.saveGState()
platePath.addClip()
NSColor(white: 1.0, alpha: 0.48).setStroke()
let innerStroke = roundedRect(iconRect.insetBy(dx: 10, dy: 10), iconRadius - 10)
innerStroke.lineWidth = 5
innerStroke.stroke()
ctx.restoreGState()

let center = CGPoint(x: size / 2, y: size / 2)

struct BoardLayer {
    let dx: CGFloat
    let dy: CGFloat
    let scale: CGFloat
    let alpha: CGFloat
}

let boardWidth: CGFloat = 452
let boardHeight: CGFloat = 534
let boardRadius: CGFloat = 70
let layers = [
    BoardLayer(dx: -58, dy: 52, scale: 0.92, alpha: 0.50),
    BoardLayer(dx: -26, dy: 24, scale: 0.96, alpha: 0.72),
    BoardLayer(dx: 0, dy: 0, scale: 1.00, alpha: 1.00)
]

let borderColors = [
    NSColor(calibratedRed: 0.61, green: 0.39, blue: 0.82, alpha: 1),
    NSColor(calibratedRed: 0.94, green: 0.42, blue: 0.53, alpha: 1),
    NSColor(calibratedRed: 0.98, green: 0.70, blue: 0.43, alpha: 1)
]

for (index, layer) in layers.enumerated() {
    let w = boardWidth * layer.scale
    let h = boardHeight * layer.scale
    let rect = CGRect(
        x: center.x - w / 2 + layer.dx,
        y: center.y - h / 2 + layer.dy - 10,
        width: w,
        height: h
    )
    let radius = boardRadius * layer.scale
    let shadowAlpha: CGFloat = index == layers.count - 1 ? 0.22 : 0.12
    let pagePath = roundedRect(rect, radius)

    drawShadowedPath(
        pagePath,
        fill: NSColor(white: 1, alpha: 0.0),
        shadowOffset: CGSize(width: 0, height: -12 * layer.scale),
        shadowBlur: 26 * layer.scale,
        shadowColor: NSColor(white: 0, alpha: shadowAlpha)
    )

    ctx.saveGState()
    pagePath.addClip()
    drawLinearGradient(
        colors: [
            NSColor(calibratedRed: 1.00, green: 1.00, blue: 0.985, alpha: layer.alpha),
            NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.982, alpha: layer.alpha)
        ],
        in: rect,
        start: CGPoint(x: 0.25, y: 0.95),
        end: CGPoint(x: 0.85, y: 0.10)
    )
    ctx.restoreGState()

    drawGradientBorder(
        rect: rect,
        radius: radius,
        strokeWidth: 44 * layer.scale,
        colors: borderColors.map { $0.withAlphaComponent(0.86 * layer.alpha) }
    )

    if index == layers.count - 1 {
        // 用白色内容区盖住大部分边框，中间保留轻盈纸张感。
        let contentRect = rect.insetBy(dx: 58, dy: 74)
        let contentPath = roundedRect(contentRect, 28)
        drawLinearGradient(
            colors: [
                NSColor(calibratedRed: 1.0, green: 1.0, blue: 0.995, alpha: 1),
                NSColor(calibratedRed: 0.985, green: 0.990, blue: 1.0, alpha: 1)
            ],
            in: contentRect,
            start: CGPoint(x: 0.20, y: 0.95),
            end: CGPoint(x: 0.80, y: 0.05),
            clippedTo: contentPath
        )

        // 右下角折页。
        let foldSize: CGFloat = 128
        let foldPath = NSBezierPath()
        foldPath.move(to: CGPoint(x: contentRect.maxX - foldSize, y: contentRect.minY))
        foldPath.line(to: CGPoint(x: contentRect.maxX, y: contentRect.minY))
        foldPath.line(to: CGPoint(x: contentRect.maxX, y: contentRect.minY + foldSize))
        foldPath.close()
        drawLinearGradient(
            colors: [
                NSColor(calibratedRed: 0.890, green: 0.912, blue: 0.940, alpha: 1),
                NSColor(calibratedRed: 0.790, green: 0.822, blue: 0.868, alpha: 1)
            ],
            in: CGRect(x: contentRect.maxX - foldSize, y: contentRect.minY, width: foldSize, height: foldSize),
            start: CGPoint(x: 0.2, y: 0.2),
            end: CGPoint(x: 1, y: 1),
            clippedTo: foldPath
        )

        // 文本线条。
        let lineX = contentRect.minX + 54
        let lineY = contentRect.maxY - 118
        let lineH: CGFloat = 30
        drawLine(CGRect(x: lineX, y: lineY, width: 246, height: lineH), alpha: 0.76)
        drawLine(CGRect(x: lineX, y: lineY - 74, width: 284, height: lineH), alpha: 0.72)
        drawLine(CGRect(x: lineX, y: lineY - 148, width: 168, height: lineH), alpha: 0.66)

        // 顶部夹子。
        let clipColor = NSColor(calibratedRed: 0.235, green: 0.270, blue: 0.410, alpha: 1)
        let clipW: CGFloat = 226
        let clipH: CGFloat = 106
        let clipRect = CGRect(x: rect.midX - clipW / 2, y: rect.maxY - 42, width: clipW, height: clipH)
        let clipPath = roundedRect(clipRect, 34)
        drawShadowedPath(
            clipPath,
            fill: clipColor,
            shadowOffset: CGSize(width: 0, height: -6),
            shadowBlur: 14,
            shadowColor: NSColor(white: 0, alpha: 0.18)
        )

        let knobOuter = CGRect(x: rect.midX - 46, y: clipRect.maxY - 8, width: 92, height: 78)
        let knobPath = roundedRect(knobOuter, 32)
        clipColor.setFill()
        knobPath.fill()

        NSColor(calibratedRed: 0.965, green: 0.955, blue: 0.925, alpha: 1).setFill()
        roundedRect(CGRect(x: rect.midX - 19, y: knobOuter.maxY - 40, width: 38, height: 38), 19).fill()
        clipColor.setFill()
        roundedRect(CGRect(x: rect.midX - 12, y: knobOuter.maxY - 33, width: 24, height: 24), 12).fill()
    }
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("encode failed")
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
