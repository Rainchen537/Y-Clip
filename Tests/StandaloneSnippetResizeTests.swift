import AppKit

@main
struct StandaloneSnippetResizeTests {
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let initial = NSRect(x: 100, y: 100, width: 200, height: 100)

        let rightEdge = SnippetResizeGesture(
            initialFrame: initial,
            initialPointer: NSPoint(x: 300, y: 150),
            initialZoom: 1,
            horizontalEdge: 1,
            verticalEdge: 0
        )
        let rightZoom = SnippetResizeGeometry.zoom(for: rightEdge, pointer: NSPoint(x: 350, y: 150))
        expect(close(rightZoom, 1.25), "右边缘向外拖动应等比放大")
        let rightFrame = SnippetResizeGeometry.frame(
            from: rightEdge,
            size: NSSize(width: 250, height: 125),
            in: screen
        )
        expect(close(rightFrame.minX, initial.minX), "拖右边缘时左边应保持原位")
        expect(close(rightFrame.midY, initial.midY), "只拖水平边缘时应保持垂直中心")

        let lowerRight = SnippetResizeGesture(
            initialFrame: initial,
            initialPointer: NSPoint(x: 300, y: 100),
            initialZoom: 1,
            horizontalEdge: 1,
            verticalEdge: -1
        )
        let cornerZoom = SnippetResizeGeometry.zoom(for: lowerRight, pointer: NSPoint(x: 340, y: 80))
        expect(close(cornerZoom, 1.2), "右下角应按拖动幅度放大")
        let cornerFrame = SnippetResizeGeometry.frame(
            from: lowerRight,
            size: NSSize(width: 240, height: 120),
            in: screen
        )
        expect(close(cornerFrame.minX, initial.minX), "拖右下角时左边应保持原位")
        expect(close(cornerFrame.maxY, initial.maxY), "拖右下角时上边应保持原位")
        expect(close(cornerFrame.width / cornerFrame.height, initial.width / initial.height), "角落缩放应保留内容比例")

        let leftEdge = SnippetResizeGesture(
            initialFrame: initial,
            initialPointer: NSPoint(x: 100, y: 150),
            initialZoom: 1,
            horizontalEdge: -1,
            verticalEdge: 0
        )
        let leftZoom = SnippetResizeGeometry.zoom(for: leftEdge, pointer: NSPoint(x: 80, y: 150))
        expect(close(leftZoom, 1.1), "左边缘向外拖动应放大")
        let leftFrame = SnippetResizeGeometry.frame(
            from: leftEdge,
            size: NSSize(width: 220, height: 110),
            in: screen
        )
        expect(close(leftFrame.maxX, initial.maxX), "拖左边缘时右边应保持原位")

        let minimum = SnippetResizeGeometry.zoom(for: rightEdge, pointer: NSPoint(x: -500, y: 150))
        expect(close(minimum, 0.45), "大幅向内拖动不应缩小到零或反转")
        print("StandaloneSnippetResize tests passed")
    }

    private static func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.0001
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
