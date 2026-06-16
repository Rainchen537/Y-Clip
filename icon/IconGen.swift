import AppKit
import Foundation

// 离屏绘制 1024×1024 的 app 图标主图，输出 PNG。
// 设计：深色石墨渐变圆角底 + 多层叠放卡片（呼应「剪贴板历史多条记录」）。

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no context")
}

let full = CGRect(x: 0, y: 0, width: size, height: size)

// macOS Big Sur+ 图标采用 squircle（连续圆角），圆角半径约为边长的 22.4%。
let cornerRadius = size * 0.2237
let bgPath = NSBezierPath(roundedRect: full, xRadius: cornerRadius, yRadius: cornerRadius)
bgPath.addClip()

// ---- 背景：深色石墨竖向渐变 ----
let baseGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.27, green: 0.30, blue: 0.34, alpha: 1.0),
    NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 1.0)
])!
baseGradient.draw(in: full, angle: -90)

// 顶部一层柔光，增加金属质感
let sheen = NSGradient(colors: [
    NSColor(white: 1.0, alpha: 0.10),
    NSColor(white: 1.0, alpha: 0.0)
])!
sheen.draw(in: CGRect(x: 0, y: size * 0.55, width: size, height: size * 0.45), angle: -90)

// ---- 顶部夹子（clipboard clip） ----
// 卡片区域整体居中略偏下，夹子压在卡片顶部中间。
func roundedRect(_ rect: CGRect, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
}

// ---- 叠放卡片：从后到前画三层，制造层叠纵深 ----
// 卡片尺寸与中心
let cardW = size * 0.46
let cardH = size * 0.54
let centerX = size * 0.5
let centerY = size * 0.46

// 每层相对中心的偏移（越靠后越往左上、越小、越淡）
struct Layer {
    let dx: CGFloat
    let dy: CGFloat
    let scale: CGFloat
    let white: CGFloat
    let alpha: CGFloat
}

let layers: [Layer] = [
    Layer(dx: -size * 0.072, dy:  size * 0.080, scale: 0.88, white: 0.62, alpha: 1.0),
    Layer(dx: -size * 0.034, dy:  size * 0.040, scale: 0.94, white: 0.82, alpha: 1.0),
    Layer(dx:  0,            dy:  0,            scale: 1.00, white: 1.00, alpha: 1.0)
]

for (idx, layer) in layers.enumerated() {
    let w = cardW * layer.scale
    let h = cardH * layer.scale
    let rect = CGRect(
        x: centerX - w / 2 + layer.dx,
        y: centerY - h / 2 + layer.dy,
        width: w,
        height: h
    )
    let r = w * 0.10

    // 每层都有一点投影，制造真实的纸张叠放纵深
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.010),
        blur: size * (idx == layers.count - 1 ? 0.045 : 0.028),
        color: NSColor(white: 0, alpha: idx == layers.count - 1 ? 0.35 : 0.22).cgColor
    )
    NSColor(white: layer.white, alpha: layer.alpha).setFill()
    roundedRect(rect, r).fill()
    ctx.restoreGState()

    // 最前层画上文本行 + 顶部夹子
    if idx == layers.count - 1 {
        // 文本行（用深色短横线表示几行文字，模仿历史条目）
        let lineColor = NSColor(calibratedRed: 0.22, green: 0.25, blue: 0.30, alpha: 1.0)
        lineColor.setFill()
        let lineX = rect.minX + w * 0.14
        let lineH = h * 0.052
        let lineGap = h * 0.105
        let lineTop = rect.maxY - h * 0.27
        let widths: [CGFloat] = [0.62, 0.72, 0.50, 0.66]
        for (i, wf) in widths.enumerated() {
            let ly = lineTop - CGFloat(i) * lineGap
            let lw = w * 0.72 * wf
            roundedRect(CGRect(x: lineX, y: ly, width: lw, height: lineH), lineH / 2).fill()
        }

        // 顶部夹子：底座（梯形圆角）压在卡片顶部中间，上方一个收敛的小提手
        let clipW = w * 0.32
        let clipH = h * 0.10
        let clipX = rect.midX - clipW / 2
        let clipY = rect.maxY - clipH * 0.62
        let clipBase = roundedRect(CGRect(x: clipX, y: clipY, width: clipW, height: clipH), clipH * 0.36)
        NSColor(calibratedRed: 0.32, green: 0.35, blue: 0.40, alpha: 1.0).setFill()
        clipBase.fill()

        // 提手：比底座窄、贴着底座顶部的小圆角方块（更像真实夹子，不再是突出的耳朵）
        let knobW = clipW * 0.46
        let knobH = clipH * 0.62
        let knobRect = CGRect(
            x: rect.midX - knobW / 2,
            y: clipY + clipH * 0.72,
            width: knobW,
            height: knobH
        )
        roundedRect(knobRect, knobW * 0.28).fill()
    }
}

image.unlockFocus()

// ---- 输出 PNG ----
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("encode failed")
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
