import Foundation

final class SettingsStore {
    private enum Keys {
        static let hotKey = "hotKey"
        static let menuSize = "menuSize"
        static let maxHistoryItems = "maxHistoryItems"
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

    var menuSize: MenuSize {
        get {
            guard
                let raw = defaults.string(forKey: Keys.menuSize),
                let size = MenuSize(rawValue: raw)
            else {
                return .default
            }

            return size
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.menuSize)
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

    static func clampedHistoryLimit(_ value: Int) -> Int {
        min(max(value, allowedHistoryRange.lowerBound), allowedHistoryRange.upperBound)
    }
}
