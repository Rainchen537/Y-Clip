import AppKit
import Foundation

// 按 make_dmg.sh 里的真实坐标合成一张 DMG 窗口预览图，用于验证布局。
// 窗口内容区 640×400；图标坐标为中心点，原点左上。

let W = 640.0, H = 400.0
let iconSize = 128.0

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
let ctx = nsCtx.cgContext
ctx.scaleBy(x: 2, y: 2)  // 逻辑坐标绘制，输出 @2x

let args = CommandLine.arguments
let bgPath = args[1]
let appIconPath = args[2]
let outPath = args[3]

// 背景图（AppKit 坐标原点在左下，背景铺满）
if let bg = NSImage(contentsOfFile: bgPath) {
    bg.draw(in: CGRect(x: 0, y: 0, width: W, height: H))
}

// 把 AppleScript 的「左上原点中心坐标」转成 AppKit 的「左下原点左下角坐标」
func place(centerXTop: Double, centerYTop: Double) -> CGRect {
    let x = centerXTop - iconSize / 2
    let yTop = centerYTop - iconSize / 2
    let yBottom = H - yTop - iconSize
    return CGRect(x: x, y: yBottom, width: iconSize, height: iconSize)
}

func label(_ s: String, centerXTop: Double, belowIconCenterYTop: Double) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(white: 0.95, alpha: 1.0)
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    let xTop = centerXTop - Double(sz.width) / 2
    let yTop = belowIconCenterYTop + iconSize / 2 + 6
    let yBottom = H - yTop - Double(sz.height)
    str.draw(at: CGPoint(x: xTop, y: yBottom))
}

// App 图标（位置 {165,200}）
if let appIcon = NSImage(contentsOfFile: appIconPath) {
    appIcon.draw(in: place(centerXTop: 165, centerYTop: 200))
}
label("Global Clipboard.app", centerXTop: 165, belowIconCenterYTop: 200)

// Applications 文件夹图标（位置 {475,200}），用系统文件夹图标
let folderIcon = NSWorkspace.shared.icon(forFile: "/Applications")
folderIcon.draw(in: place(centerXTop: 475, centerYTop: 200))
label("Applications", centerXTop: 475, belowIconCenterYTop: 200)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
