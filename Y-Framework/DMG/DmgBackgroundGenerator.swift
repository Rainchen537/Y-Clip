import AppKit
import Foundation

struct YDMGGeneratorArguments {
    let outputPath: String
    let title: String
    let width: Int
    let height: Int

    init() throws {
        let values = CommandLine.arguments
        guard values.count == 5,
              let width = Int(values[3]),
              let height = Int(values[4]),
              width > 0,
              height > 0 else {
            throw NSError(
                domain: "YDMGBackgroundGenerator",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "用法：DmgBackgroundGenerator.swift <输出路径> <应用名称> <宽度> <高度>"
                ]
            )
        }

        outputPath = values[1]
        title = values[2]
        self.width = width
        self.height = height
    }
}

private func centeredOrigin(
    for attributedString: NSAttributedString,
    centerX: CGFloat,
    y: CGFloat
) -> CGPoint {
    let size = attributedString.size()
    return CGPoint(x: centerX - size.width / 2, y: y)
}

private func fittedTitleFont(for title: String, maximumWidth: CGFloat) -> NSFont {
    for size in stride(from: 30.0, through: 18.0, by: -1.0) {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        if width <= maximumWidth {
            return font
        }
    }

    return NSFont.systemFont(ofSize: 18, weight: .semibold)
}

let arguments = try YDMGGeneratorArguments()
let width = CGFloat(arguments.width)
let height = CGFloat(arguments.height)

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: arguments.width,
    pixelsHigh: arguments.height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

let canvas = CGRect(x: 0, y: 0, width: width, height: height)
NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
])!.draw(in: canvas, angle: -90)

let title = NSAttributedString(
    string: arguments.title,
    attributes: [
        .font: fittedTitleFont(for: arguments.title, maximumWidth: width - 96),
        .foregroundColor: NSColor(white: 0.97, alpha: 1)
    ]
)
title.draw(at: centeredOrigin(
    for: title,
    centerX: width / 2,
    y: height - 78
))

let instruction = NSAttributedString(
    string: "将左侧应用拖入右侧「应用程序」文件夹即可安装",
    attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .regular),
        .foregroundColor: NSColor(white: 0.66, alpha: 1)
    ]
)
instruction.draw(at: centeredOrigin(
    for: instruction,
    centerX: width / 2,
    y: height - 112
))

NSColor(white: 0.36, alpha: 1).setFill()
NSBezierPath(
    roundedRect: CGRect(x: width / 2 - 70, y: height - 132, width: 140, height: 3),
    xRadius: 1.5,
    yRadius: 1.5
).fill()

let scaleX = width / 640
let scaleY = height / 400
let arrowCenterY = 190 * scaleY
let arrowColor = NSColor(calibratedRed: 0.46, green: 0.72, blue: 1, alpha: 0.92)
arrowColor.setStroke()

let shaft = NSBezierPath()
shaft.lineWidth = 8 * min(scaleX, scaleY)
shaft.lineCapStyle = .round
shaft.move(to: CGPoint(x: 270 * scaleX, y: arrowCenterY))
shaft.line(to: CGPoint(x: 360 * scaleX, y: arrowCenterY))
shaft.stroke()

let head = NSBezierPath()
head.move(to: CGPoint(x: 358 * scaleX, y: arrowCenterY + 16 * scaleY))
head.line(to: CGPoint(x: 386 * scaleX, y: arrowCenterY))
head.line(to: CGPoint(x: 358 * scaleX, y: arrowCenterY - 16 * scaleY))
head.lineWidth = 8 * min(scaleX, scaleY)
head.lineJoinStyle = .round
head.lineCapStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(
    using: NSBitmapImageRep.FileType.png,
    properties: [:]
) else {
    throw NSError(
        domain: "YDMGBackgroundGenerator",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "无法编码 DMG 背景 PNG。"]
    )
}

let outputURL = URL(fileURLWithPath: arguments.outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: Data.WritingOptions.atomic)
print("已生成 DMG 背景：\(outputURL.path)（\(arguments.width)×\(arguments.height)）")
