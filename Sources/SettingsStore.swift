import Foundation

final class SettingsStore {
    private enum Keys {
        static let hotKey = "hotKey"
        static let menuSize = "menuSize"
    }

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
}
