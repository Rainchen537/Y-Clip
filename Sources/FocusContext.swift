import AppKit
import ApplicationServices

struct FocusContext {
    let application: NSRunningApplication?
    let focusedElement: AXUIElement?
    let selectedTextRange: AXValue?
    let caretPoint: NSPoint?
}

enum FocusContextReader {
    static func current() -> FocusContext {
        let application = filteredApplication(
            NSWorkspace.shared.frontmostApplication
        )

        guard AccessibilityPermission.isTrusted(prompt: false) else {
            return FocusContext(
                application: application,
                focusedElement: nil,
                selectedTextRange: nil,
                caretPoint: nil
            )
        }

        guard let focusedElement = currentFocusedElement(
            for: application
        ) else {
            return FocusContext(
                application: application,
                focusedElement: nil,
                selectedTextRange: nil,
                caretPoint: nil
            )
        }

        let selectedTextRange = selectedRange(for: focusedElement)
        let caretPoint = caretPoint(
            for: focusedElement,
            selectedTextRange: selectedTextRange
        )

        return FocusContext(
            application: application,
            focusedElement: focusedElement,
            selectedTextRange: selectedTextRange,
            caretPoint: caretPoint
        )
    }

    static func restore(_ context: FocusContext?) {
        guard let context else {
            return
        }

        if let application = context.application, !application.isTerminated {
            application.activate(options: [.activateIgnoringOtherApps])
        }

        guard AccessibilityPermission.isTrusted(prompt: false), let focusedElement = context.focusedElement else {
            return
        }

        AXUIElementSetAttributeValue(
            focusedElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        if let selectedTextRange = context.selectedTextRange {
            AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                selectedTextRange
            )
        }
    }

    private static func filteredApplication(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        return app
    }

    private static func currentFocusedElement(
        for application: NSRunningApplication?
    ) -> AXUIElement? {
        guard let application else {
            return currentFocusedElement()
        }

        let applicationElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard result == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func currentFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard result == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func selectedRange(for element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )

        guard result == .success, let value else {
            return nil
        }

        return (value as! AXValue)
    }

    private static func caretPoint(for element: AXUIElement, selectedTextRange: AXValue?) -> NSPoint? {
        if let selectedTextRange, let bounds = boundsForSelectedRange(element, selectedTextRange) {
            return NSPoint(x: bounds.midX, y: bounds.minY)
        }

        if let bounds = boundsForElement(element) {
            return NSPoint(x: bounds.minX + 24, y: bounds.minY)
        }

        return nil
    }

    private static func boundsForSelectedRange(_ element: AXUIElement, _ selectedTextRange: AXValue) -> NSRect? {
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedTextRange,
            &value
        )

        guard result == .success, let value else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect), !rect.isNull, !rect.isEmpty else {
            return nil
        }

        return cocoaRect(fromAccessibilityRect: rect)
    }

    private static func boundsForElement(_ element: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        let positionResult = AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        let sizeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        )

        guard
            positionResult == .success,
            sizeResult == .success,
            let positionValue,
            let sizeValue
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero

        guard
            AXValueGetValue((positionValue as! AXValue), .cgPoint, &point),
            AXValueGetValue((sizeValue as! AXValue), .cgSize, &size),
            size.width > 0,
            size.height > 0
        else {
            return nil
        }

        return cocoaRect(fromAccessibilityRect: CGRect(origin: point, size: size))
    }

    private static func cocoaRect(fromAccessibilityRect rect: CGRect) -> NSRect {
        let desktopTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let converted = NSRect(
            x: rect.minX,
            y: desktopTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        return converted
    }
}
