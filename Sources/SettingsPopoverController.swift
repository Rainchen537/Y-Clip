import AppKit
import Carbon

final class SettingsPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let settingsViewController: SettingsViewController

    init(
        hotKey: HotKey,
        menuSize: MenuSize,
        launchAtLoginEnabled: Bool,
        onShowHistory: @escaping () -> Void,
        onClearHistory: @escaping () -> Void,
        onLaunchAtLoginChange: @escaping (Bool) -> Void,
        onHotKeyChange: @escaping (HotKey) -> Void,
        onMenuSizeChange: @escaping (MenuSize) -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        settingsViewController = SettingsViewController(
            hotKey: hotKey,
            menuSize: menuSize,
            launchAtLoginEnabled: launchAtLoginEnabled,
            onShowHistory: onShowHistory,
            onClearHistory: onClearHistory,
            onLaunchAtLoginChange: onLaunchAtLoginChange,
            onHotKeyChange: onHotKeyChange,
            onMenuSizeChange: onMenuSizeChange,
            onOpenAccessibility: onOpenAccessibility,
            onQuit: onQuit
        )

        super.init()

        popover.contentSize = NSSize(width: 320, height: 340)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = settingsViewController
        popover.delegate = self
    }

    var isShown: Bool {
        popover.isShown
    }

    func show(relativeTo button: NSStatusBarButton) {
        updateLaunchAtLogin(LaunchAtLoginController.isEnabled)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }

    func updateHotKey(_ hotKey: HotKey) {
        settingsViewController.updateHotKey(hotKey)
    }

    func updateMenuSize(_ size: MenuSize) {
        settingsViewController.updateMenuSize(size)
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        settingsViewController.updateLaunchAtLogin(enabled)
    }

    func popoverDidClose(_ notification: Notification) {
        settingsViewController.stopRecording()
    }
}

final class SettingsViewController: NSViewController {
    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "开机自启动", target: nil, action: nil)
    private let recordingHintLabel = NSTextField(labelWithString: "")
    private let menuSizeControl = NSSegmentedControl()
    private var localKeyMonitor: Any?
    private var currentHotKey: HotKey
    private var currentMenuSize: MenuSize
    private let onShowHistory: () -> Void
    private let onClearHistory: () -> Void
    private let onLaunchAtLoginChange: (Bool) -> Void
    private let onHotKeyChange: (HotKey) -> Void
    private let onMenuSizeChange: (MenuSize) -> Void
    private let onOpenAccessibility: () -> Void
    private let onQuit: () -> Void

    init(
        hotKey: HotKey,
        menuSize: MenuSize,
        launchAtLoginEnabled: Bool,
        onShowHistory: @escaping () -> Void,
        onClearHistory: @escaping () -> Void,
        onLaunchAtLoginChange: @escaping (Bool) -> Void,
        onHotKeyChange: @escaping (HotKey) -> Void,
        onMenuSizeChange: @escaping (MenuSize) -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        currentHotKey = hotKey
        currentMenuSize = menuSize
        self.onShowHistory = onShowHistory
        self.onClearHistory = onClearHistory
        self.onLaunchAtLoginChange = onLaunchAtLoginChange
        self.onHotKeyChange = onHotKeyChange
        self.onMenuSizeChange = onMenuSizeChange
        self.onOpenAccessibility = onOpenAccessibility
        self.onQuit = onQuit

        super.init(nibName: nil, bundle: nil)

        launchAtLoginButton.state = launchAtLoginEnabled ? .on : .off
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        view.wantsLayer = true

        let titleLabel = NSTextField(labelWithString: "全局剪切板")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin)

        let shortcutTitleLabel = NSTextField(labelWithString: "快捷键")
        shortcutTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        shortcutButton.bezelStyle = .rounded
        shortcutButton.target = self
        shortcutButton.action = #selector(startRecording)
        shortcutButton.setButtonType(.momentaryPushIn)
        shortcutButton.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        shortcutButton.contentTintColor = .controlAccentColor
        updateHotKey(currentHotKey)

        recordingHintLabel.font = .systemFont(ofSize: 11)
        recordingHintLabel.textColor = .secondaryLabelColor
        recordingHintLabel.stringValue = " "

        let shortcutStack = NSStackView(views: [shortcutTitleLabel, shortcutButton])
        shortcutStack.orientation = .horizontal
        shortcutStack.alignment = .centerY
        shortcutStack.distribution = .gravityAreas
        shortcutStack.spacing = 12

        let menuSizeTitleLabel = NSTextField(labelWithString: "菜单大小")
        menuSizeTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        menuSizeControl.segmentStyle = .rounded
        menuSizeControl.trackingMode = .selectOne
        menuSizeControl.segmentCount = MenuSize.allCases.count
        for (index, size) in MenuSize.allCases.enumerated() {
            menuSizeControl.setLabel(size.displayName, forSegment: index)
            menuSizeControl.setWidth(40, forSegment: index)
        }
        menuSizeControl.target = self
        menuSizeControl.action = #selector(changeMenuSize)
        updateMenuSize(currentMenuSize)

        let menuSizeStack = NSStackView(views: [menuSizeTitleLabel, menuSizeControl])
        menuSizeStack.orientation = .horizontal
        menuSizeStack.alignment = .centerY
        menuSizeStack.distribution = .gravityAreas
        menuSizeStack.spacing = 12

        let showHistoryButton = makeCommandButton(title: "显示历史", symbolName: "list.bullet.clipboard")
        showHistoryButton.target = self
        showHistoryButton.action = #selector(showHistory)

        let clearButton = makeCommandButton(title: "清空历史", symbolName: "trash")
        clearButton.target = self
        clearButton.action = #selector(clearHistory)

        let permissionButton = makeCommandButton(title: "辅助功能", symbolName: "accessibility")
        permissionButton.target = self
        permissionButton.action = #selector(openAccessibility)

        let quitButton = makeCommandButton(title: "退出", symbolName: "power")
        quitButton.target = self
        quitButton.action = #selector(quit)

        let commandGrid = NSGridView(views: [
            [showHistoryButton, clearButton],
            [permissionButton, quitButton]
        ])
        commandGrid.rowSpacing = 8
        commandGrid.columnSpacing = 8

        for columnIndex in 0..<2 {
            commandGrid.column(at: columnIndex).xPlacement = .fill
        }

        let stack = NSStackView(views: [
            titleLabel,
            separator(),
            launchAtLoginButton,
            shortcutStack,
            recordingHintLabel,
            menuSizeStack,
            separator(),
            commandGrid
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18),

            shortcutStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutButton.widthAnchor.constraint(equalToConstant: 122),
            menuSizeStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandGrid.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func updateHotKey(_ hotKey: HotKey) {
        currentHotKey = hotKey
        shortcutButton.title = hotKey.displayName
        recordingHintLabel.stringValue = " "
    }

    func updateMenuSize(_ size: MenuSize) {
        currentMenuSize = size
        if let index = MenuSize.allCases.firstIndex(of: size) {
            menuSizeControl.selectedSegment = index
        }
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginButton.state = enabled ? .on : .off
    }

    func stopRecording() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }

        localKeyMonitor = nil
        shortcutButton.title = currentHotKey.displayName
        recordingHintLabel.stringValue = " "
    }

    @objc private func toggleLaunchAtLogin() {
        onLaunchAtLoginChange(launchAtLoginButton.state == .on)
    }

    @objc private func changeMenuSize() {
        let index = menuSizeControl.selectedSegment
        guard MenuSize.allCases.indices.contains(index) else { return }
        let size = MenuSize.allCases[index]
        currentMenuSize = size
        onMenuSizeChange(size)
    }

    @objc private func startRecording() {
        shortcutButton.title = "录制中"
        recordingHintLabel.stringValue = "按下新的组合键，Esc 取消"

        if localKeyMonitor != nil {
            return
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    @objc private func showHistory() {
        onShowHistory()
    }

    @objc private func clearHistory() {
        onClearHistory()
    }

    @objc private func openAccessibility() {
        onOpenAccessibility()
    }

    @objc private func quit() {
        onQuit()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        guard let hotKey = HotKey(event: event) else {
            recordingHintLabel.stringValue = "请至少包含一个修饰键"
            return
        }

        stopRecording()
        onHotKeyChange(hotKey)
    }

    private func makeCommandButton(title: String, symbolName: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .center
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
