import AppKit
import Foundation

struct YDMGGeneratorArguments {
    let outputPath: String
    let title: String
    let width: Int
    let height: Int
    let appIconX: CGFloat
    let appIconY: CGFloat
    let applicationsIconX: CGFloat
    let applicationsIconY: CGFloat
    let iconSize: CGFloat
    let scale: Int

    init() throws {
        let values = CommandLine.arguments
        guard values.count == 11,
              let width = Int(values[3]),
              let height = Int(values[4]),
              let appIconX = Double(values[5]),
              let appIconY = Double(values[6]),
              let applicationsIconX = Double(values[7]),
              let applicationsIconY = Double(values[8]),
              let iconSize = Double(values[9]),
              let scale = Int(values[10]),
              width > 0,
              height > 0,
              appIconX > 0,
              appIconY > 0,
              applicationsIconX > appIconX,
              applicationsIconY > 0,
              iconSize > 0,
              (1...4).contains(scale) else {
            throw NSError(
                domain: "YDMGBackgroundGenerator",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "用法：DmgBackgroundGenerator.swift <输出路径> <应用名称> <宽度> <高度> <应用X> <应用Y> <ApplicationsX> <ApplicationsY> <图标尺寸> <缩放倍率>"
                ]
            )
        }

        outputPath = values[1]
        title = values[2]
        self.width = width
        self.height = height
        self.appIconX = appIconX
        self.appIconY = appIconY
        self.applicationsIconX = applicationsIconX
        self.applicationsIconY = applicationsIconY
        self.iconSize = iconSize
        self.scale = scale
    }
}

private func fittedTitleFont(for title: String, maximumWidth: CGFloat) -> NSFont {
    for size in stride(from: 31.0, through: 19.0, by: -1.0) {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        if width <= maximumWidth {
            return font
        }
    }

    return NSFont.systemFont(ofSize: 19, weight: .bold)
}

private func drawCentered(
    _ string: NSAttributedString,
    centerX: CGFloat,
    top: CGFloat,
    canvasHeight: CGFloat
) {
    let size = string.size()
    string.draw(at: CGPoint(
        x: centerX - size.width / 2,
        y: canvasHeight - top - size.height
    ))
}

let arguments = try YDMGGeneratorArguments()
let width = CGFloat(arguments.width)
let height = CGFloat(arguments.height)
let pixelWidth = arguments.width * arguments.scale
let pixelHeight = arguments.height * arguments.scale

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
bitmap.size = NSSize(width: width, height: height)

let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)!
graphicsContext.imageInterpolation = .high
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

let canvas = CGRect(x: 0, y: 0, width: width, height: height)
NSGradient(colors: [
    NSColor(calibratedRed: 0.985, green: 0.989, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.915, green: 0.931, blue: 0.985, alpha: 1)
])!.draw(in: canvas, angle: -90)

NSColor(calibratedRed: 0.60, green: 0.45, blue: 1.0, alpha: 0.09).setFill()
NSBezierPath(ovalIn: CGRect(
    x: width - width * 0.34,
    y: height - height * 0.34,
    width: width * 0.41,
    height: height * 0.48
)).fill()

NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.64, alpha: 0.065).setFill()
NSBezierPath(ovalIn: CGRect(
    x: -width * 0.14,
    y: -height * 0.18,
    width: width * 0.42,
    height: height * 0.48
)).fill()

let panelRect = CGRect(
    x: width * 0.075,
    y: height * 0.11,
    width: width * 0.85,
    height: height * 0.55
)
let panelPath = NSBezierPath(
    roundedRect: panelRect,
    xRadius: min(28, width * 0.044),
    yRadius: min(28, width * 0.044)
)
let panelShadow = NSShadow()
panelShadow.shadowColor = NSColor(calibratedWhite: 0.18, alpha: 0.12)
panelShadow.shadowBlurRadius = 22
panelShadow.shadowOffset = NSSize(width: 0, height: -7)
panelShadow.set()
NSColor.white.withAlphaComponent(0.68).setFill()
panelPath.fill()
NSShadow().set()
NSColor.white.withAlphaComponent(0.9).setStroke()
panelPath.lineWidth = 1
panelPath.stroke()

let title = NSAttributedString(
    string: arguments.title,
    attributes: [
        .font: fittedTitleFont(for: arguments.title, maximumWidth: width - 96),
        .foregroundColor: NSColor(
            calibratedRed: 0.11,
            green: 0.14,
            blue: 0.24,
            alpha: 1
        ),
        .kern: 0.2
    ]
)
drawCentered(
    title,
    centerX: width / 2,
    top: height * 0.095,
    canvasHeight: height
)

let instruction = NSAttributedString(
    string: "将左侧应用拖入右侧「应用程序」文件夹即可安装",
    attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(
            calibratedRed: 0.36,
            green: 0.40,
            blue: 0.50,
            alpha: 1
        )
    ]
)
drawCentered(
    instruction,
    centerX: width / 2,
    top: height * 0.205,
    canvasHeight: height
)

let divider = NSBezierPath(
    roundedRect: CGRect(
        x: width / 2 - 58,
        y: height - height * 0.295,
        width: 116,
        height: 3
    ),
    xRadius: 1.5,
    yRadius: 1.5
)
NSColor(
    calibratedRed: 0.39,
    green: 0.46,
    blue: 0.85,
    alpha: 0.34
).setFill()
divider.fill()

let iconCenterYFromTop =
    (arguments.appIconY + arguments.applicationsIconY) / 2
let arrowCenterY = height - iconCenterYFromTop
let iconClearance = arguments.iconSize * 0.68
let startX = arguments.appIconX + iconClearance
let endX = arguments.applicationsIconX - iconClearance
let availableLength = endX - startX

guard availableLength >= 36 else {
    throw NSError(
        domain: "YDMGBackgroundGenerator",
        code: 2,
        userInfo: [
            NSLocalizedDescriptionKey:
                "App 与 Applications 图标间距不足，无法绘制安装箭头。"
        ]
    )
}

let headLength = min(28, max(20, availableLength * 0.22))
let headHeight = min(19, max(14, arguments.iconSize * 0.13))
let lineWidth = max(5.5, min(7.5, arguments.iconSize * 0.055))
let arrowColor = NSColor(
    calibratedRed: 0.35,
    green: 0.40,
    blue: 0.92,
    alpha: 0.9
)
arrowColor.setStroke()

let shaft = NSBezierPath()
shaft.lineWidth = lineWidth
shaft.lineCapStyle = .round
shaft.move(to: CGPoint(x: startX, y: arrowCenterY))
shaft.line(to: CGPoint(x: endX - headLength + 4, y: arrowCenterY))
shaft.stroke()

let head = NSBezierPath()
head.lineWidth = lineWidth
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: CGPoint(
    x: endX - headLength,
    y: arrowCenterY + headHeight
))
head.line(to: CGPoint(x: endX, y: arrowCenterY))
head.line(to: CGPoint(
    x: endX - headLength,
    y: arrowCenterY - headHeight
))
head.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw NSError(
        domain: "YDMGBackgroundGenerator",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "无法编码 DMG 背景 PNG。"]
    )
}

let outputURL = URL(fileURLWithPath: arguments.outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
print(
    "已生成 DMG 背景：\(outputURL.path)（\(pixelWidth)×\(pixelHeight)，\(arguments.scale)x）"
)
