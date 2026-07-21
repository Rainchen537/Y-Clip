import AppKit
import Foundation

final class SettingsStore {
    private enum Keys {
        static let hotKey = "hotKey"
        static let pinnedHotKey = "pinnedHotKey"
        static let pinnedPanelFrame = "pinnedPanelFrame"
        static let menuSize = "menuSize"
        static let maxHistoryItems = "maxHistoryItems"
        static let panelScale = "panelScale"
        static let panelWidth = "panelWidth"
        static let panelVisibleRows = "panelVisibleRows"
        static let autoUpdateEnabled = "autoUpdateEnabled"
        static let accessibilityWasTrusted = "accessibilityWasTrusted"
        static let accessibilityRepairPending = "accessibilityRepairPending"
    }

    static let defaultMaxHistoryItems = 50
    static let allowedHistoryRange = 1...500

    private let defaults = UserDefaults.standard

    var hotKey: HotKey {
        get {
            guard
                let data = defaults.data(forKey: Keys.hotKey),
                let hotKey = try? JSONDecoder().decode(HotKey.self, from: data)
            else {
                return .default
            }

            return hotKey
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }

            defaults.set(data, forKey: Keys.hotKey)
        }
    }

    var pinnedHotKey: HotKey {
        get {
            guard
                let data = defaults.data(forKey: Keys.pinnedHotKey),
                let hotKey = try? JSONDecoder().decode(HotKey.self, from: data)
            else {
                return .pinnedDefault
            }

            return hotKey
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }

            defaults.set(data, forKey: Keys.pinnedHotKey)
        }
    }

    var pinnedPanelFrame: NSRect? {
        get {
            guard let value = defaults.string(forKey: Keys.pinnedPanelFrame) else {
                return nil
            }

            let frame = NSRectFromString(value)
            guard frame.width > 0, frame.height > 0 else {
                return nil
            }
            return frame
        }
        set {
            if let newValue {
                defaults.set(NSStringFromRect(newValue), forKey: Keys.pinnedPanelFrame)
            } else {
                defaults.removeObject(forKey: Keys.pinnedPanelFrame)
            }
        }
    }

    var panelMetrics: HistoryPanelMetrics {
        get {
            let fallbackScale = migratedScaleFromMenuSize()
            let scale = storedDouble(forKey: Keys.panelScale) ?? fallbackScale
            let width = storedDouble(forKey: Keys.panelWidth) ?? Double(HistoryPanelMetrics.default.width)
            let rows = storedDouble(forKey: Keys.panelVisibleRows) ?? Double(HistoryPanelMetrics.default.visibleRows)
            return HistoryPanelMetrics(
                scale: CGFloat(scale),
                width: CGFloat(width),
                visibleRows: CGFloat(rows)
            )
        }
        set {
            defaults.set(Double(newValue.scale), forKey: Keys.panelScale)
            defaults.set(Double(newValue.width), forKey: Keys.panelWidth)
            defaults.set(Double(newValue.visibleRows), forKey: Keys.panelVisibleRows)
        }
    }

    var maxHistoryItems: Int {
        get {
            let value = defaults.integer(forKey: Keys.maxHistoryItems)
            guard value > 0 else {
                return Self.defaultMaxHistoryItems
            }

            return Self.clampedHistoryLimit(value)
        }
        set {
            defaults.set(Self.clampedHistoryLimit(newValue), forKey: Keys.maxHistoryItems)
        }
    }

    var autoUpdateEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.autoUpdateEnabled) != nil else {
                return true
            }

            return defaults.bool(forKey: Keys.autoUpdateEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoUpdateEnabled)
        }
    }

    var accessibilityWasTrusted: Bool {
        get {
            defaults.bool(forKey: Keys.accessibilityWasTrusted)
        }
        set {
            defaults.set(newValue, forKey: Keys.accessibilityWasTrusted)
        }
    }

    var accessibilityRepairPending: Bool {
        get {
            defaults.bool(forKey: Keys.accessibilityRepairPending)
        }
        set {
            defaults.set(newValue, forKey: Keys.accessibilityRepairPending)
        }
    }

    static func clampedHistoryLimit(_ value: Int) -> Int {
        min(max(value, allowedHistoryRange.lowerBound), allowedHistoryRange.upperBound)
    }

    private func storedDouble(forKey key: String) -> Double? {
        guard defaults.object(forKey: key) != nil else {
            return nil
        }

        return defaults.double(forKey: key)
    }

    private func migratedScaleFromMenuSize() -> Double {
        switch defaults.string(forKey: Keys.menuSize) {
        case "small":
            return 0.86
        case "large":
            return 1.18
        default:
            return Double(HistoryPanelMetrics.default.scale)
        }
    }
}
