import AppKit
import Carbon

@main
struct FeatureHotKeySettingsTests {
    static func main() {
        let domain = "com.yclip.feature-hotkey-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            fatalError("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: domain) }

        let settings = SettingsStore(defaults: defaults)
        expect(settings.hotKey == .default, "原历史快捷键应保持原默认值")
        expect(settings.pinnedHotKey == .pinnedDefault, "原固定面板快捷键应保持原默认值")
        expect(settings.copyListHotKey == .copyListDefault, "复制清单应有独立默认快捷键")
        expect(settings.standaloneHotKey == .standaloneDefault, "单独贴出应有独立默认快捷键")
        expect(settings.copyListHotKey != settings.standaloneHotKey, "两个新快捷键不得相同")
        expect(settings.addSelectedHotKey == .addSelectedDefault, "加入高亮条目应有独立默认快捷键")
        expect(settings.stickSelectedHotKey == .stickSelectedDefault, "贴出高亮条目应有独立默认快捷键")
        expect(Set([
            settings.hotKey.displayName, settings.pinnedHotKey.displayName,
            settings.copyListHotKey.displayName, settings.standaloneHotKey.displayName,
            settings.addSelectedHotKey.displayName, settings.stickSelectedHotKey.displayName
        ]).count == 6, "六组默认快捷键不得冲突")

        let customList = HotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey) | UInt32(cmdKey))
        let customPin = HotKey(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(optionKey) | UInt32(cmdKey))
        settings.copyListHotKey = customList
        settings.standaloneHotKey = customPin
        let customAdd = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey) | UInt32(cmdKey))
        let customStick = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey) | UInt32(cmdKey))
        settings.addSelectedHotKey = customAdd
        settings.stickSelectedHotKey = customStick

        let reopened = SettingsStore(defaults: defaults)
        expect(reopened.copyListHotKey == customList, "复制清单自定义快捷键应持久化")
        expect(reopened.standaloneHotKey == customPin, "单独贴出自定义快捷键应持久化")
        expect(reopened.addSelectedHotKey == customAdd, "加入高亮条目自定义快捷键应持久化")
        expect(reopened.stickSelectedHotKey == customStick, "贴出高亮条目自定义快捷键应持久化")
        expect(reopened.hotKey == .default, "设置新快捷键不应改动旧历史快捷键")
        expect(reopened.pinnedHotKey == .pinnedDefault, "设置新快捷键不应改动固定面板快捷键")

        print("FeatureHotKeySettings tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
