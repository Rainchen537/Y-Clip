import AppKit
import Security

struct YSettingAppDescriptor {
    let displayName: String
    let subtitle: String
    let version: String
    let icon: NSImage
}

enum YSettingRuntimeIdentity {
    private struct RelaunchError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private struct SigningInformation {
        let identifier: String
        let teamIdentifier: String
        let certificateSummary: String
        let flags: UInt32
    }

    private static let hardenedRuntimeFlag: UInt32 = 0x10000

    static func isSignedInstalledCopy(
        expectedPath: String,
        expectedTeamIdentifier: String,
        expectedBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        let runningURL = Bundle.main.bundleURL.standardizedFileURL
        let expectedURL = URL(fileURLWithPath: expectedPath, isDirectory: true)
            .standardizedFileURL
        guard runningURL == expectedURL, let expectedBundleIdentifier else {
            return false
        }

        return isValidSignedApplication(
            atPath: expectedURL.path,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier
        )
    }

    static func isValidSignedApplication(
        atPath path: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String
    ) -> Bool {
        let applicationURL = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        let resourceValues = try? applicationURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard
            applicationURL.pathExtension == "app",
            resourceValues?.isSymbolicLink != true,
            let bundle = Bundle(url: applicationURL),
            bundle.bundleIdentifier == expectedBundleIdentifier,
            let signingInformation = signingInformation(at: applicationURL),
            signingInformation.identifier == expectedBundleIdentifier,
            signingInformation.teamIdentifier == expectedTeamIdentifier,
            signingInformation.certificateSummary.hasPrefix("Developer ID Application:"),
            signingInformation.certificateSummary.hasSuffix("(\(expectedTeamIdentifier))"),
            signingInformation.flags & hardenedRuntimeFlag != 0
        else {
            return false
        }

        return true
    }

    static func relaunchInstalledApplication(
        atPath path: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String
    ) throws {
        guard isValidSignedApplication(
            atPath: path,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier
        ) else {
            throw RelaunchError(message: "找不到有效的正式签名安装版：\(path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n \"$2\"",
            "y-project-relaunch",
            "\(ProcessInfo.processInfo.processIdentifier)",
            path
        ]

        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            throw RelaunchError(message: "无法启动正式安装版：\(error.localizedDescription)")
        }
    }

    private static func signingInformation(at applicationURL: URL) -> SigningInformation? {
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode,
            SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
            ) == errSecSuccess
        else {
            return nil
        }

        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ) == errSecSuccess,
            let dictionary = information as? [CFString: Any],
            let identifier = dictionary[kSecCodeInfoIdentifier] as? String,
            let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier] as? String,
            let certificates = dictionary[kSecCodeInfoCertificates] as? [SecCertificate],
            let leafCertificate = certificates.first,
            let certificateSummary = SecCertificateCopySubjectSummary(leafCertificate) as String?,
            let flags = dictionary[kSecCodeInfoFlags] as? NSNumber
        else {
            return nil
        }

        return SigningInformation(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            certificateSummary: certificateSummary,
            flags: flags.uint32Value
        )
    }
}

struct YSettingSidebarItem {
    let identifier: String
    let title: String
    let symbolName: String

    init(_ identifier: String, title: String, symbolName: String) {
        self.identifier = identifier
        self.title = title
        self.symbolName = symbolName
    }
}

enum YSettingStandardSidebar {
    static let general = YSettingSidebarItem("general", title: "通用", symbolName: "gearshape")
    static let features = YSettingSidebarItem("features", title: "功能", symbolName: "slider.horizontal.3")
    static let permissions = YSettingSidebarItem("permissions", title: "权限", symbolName: "lock.shield")
    static let updates = YSettingSidebarItem("updates", title: "更新", symbolName: "arrow.triangle.2.circlepath")
    static let about = YSettingSidebarItem("about", title: "关于", symbolName: "info.circle")

    static let all: [YSettingSidebarItem] = [
        general,
        features,
        permissions,
        updates,
        about
    ]
}

enum YSettingButtonRole {
    case primary
    case secondary
    case link
    case danger
}

enum YSettingUI {
    static let windowSize = NSSize(width: 1200, height: 810)
    static let minimumWindowSize = NSSize(width: 900, height: 620)
    static let sidebarWidth: CGFloat = 285
    static let sidebarNavigationWidth: CGFloat = 168
    static let contentInset = NSEdgeInsets(top: 45, left: 45, bottom: 45, right: 45)
    static let contentSpacing: CGFloat = 18
    static let cardSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 10
    static let cardCornerRadius: CGFloat = 12

    static func appVersionString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }

    static func bundledAppIcon(fallback: NSImage = NSApp.applicationIconImage) -> NSImage {
        if
            let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
            let image = NSImage(contentsOfFile: path)
        {
            return image
        }

        return fallback
    }

    static func makeContentStack(title: String, symbolName: String, subtitle: String? = nil) -> NSStackView {
        let header = contentHeader(title: title, symbolName: symbolName, subtitle: subtitle)
        let stack = YSettingContentStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = contentSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        return stack
    }

    static func contentHeader(title: String, symbolName: String, subtitle: String? = nil) -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        symbol.contentTintColor = .white
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let symbolBackground = NSView()
        symbolBackground.wantsLayer = true
        symbolBackground.layer?.cornerRadius = 7
        symbolBackground.layer?.cornerCurve = .continuous
        symbolBackground.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        symbolBackground.translatesAutoresizingMaskIntoConstraints = false
        symbolBackground.addSubview(symbol)

        let titleLabel = label(title, size: 22, weight: .semibold)
        titleLabel.textColor = .labelColor

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = secondaryLabel(subtitle)
            subtitleLabel.maximumNumberOfLines = 2
            textStack.addArrangedSubview(subtitleLabel)
        }

        let row = NSStackView(views: [symbolBackground, textStack, spacer()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            symbolBackground.widthAnchor.constraint(equalToConstant: 32),
            symbolBackground.heightAnchor.constraint(equalToConstant: 32),
            symbol.centerXAnchor.constraint(equalTo: symbolBackground.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: symbolBackground.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 19),
            symbol.heightAnchor.constraint(equalToConstant: 19)
        ])

        return row
    }

    static func label(_ title: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func rowTitle(_ title: String) -> NSTextField {
        let label = label(title, size: 13, weight: .medium)
        label.textColor = .labelColor
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return label
    }

    static func secondaryLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    static func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    static func row(title: String, trailingView: NSView) -> NSView {
        let titleLabel = rowTitle(title)
        let row = NSStackView(views: [titleLabel, spacer(), trailingView])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        return row
    }

    static func sliderRow(title: String, slider: NSSlider, valueView: NSView) -> NSView {
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueView.setContentHuggingPriority(.required, for: .horizontal)

        let topRow = NSStackView(views: [rowTitle(title), spacer(), valueView])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = rowSpacing

        let stack = NSStackView(views: [topRow, slider])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func makeSwitch(target: AnyObject, action: Selector) -> NSSwitch {
        let control = NSSwitch()
        control.target = target
        control.action = action
        control.controlSize = .small
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    static func makeButton(
        title: String,
        symbolName: String,
        role: YSettingButtonRole = .secondary,
        target: AnyObject?,
        action: Selector?
    ) -> NSButton {
        let button = YSettingActionButton(title: title, symbolName: symbolName, role: role)
        button.target = target
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

final class YSettingWindowController: NSWindowController, NSWindowDelegate {
    typealias ContentProvider = (String) -> NSView

    private let rootViewController: YSettingRootViewController
    var onClose: (() -> Void)?

    init(
        descriptor: YSettingAppDescriptor,
        sidebarItems: [YSettingSidebarItem],
        initialIdentifier: String? = nil,
        contentProvider: @escaping ContentProvider
    ) {
        rootViewController = YSettingRootViewController(
            descriptor: descriptor,
            sidebarItems: sidebarItems,
            initialIdentifier: initialIdentifier,
            contentProvider: contentProvider
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: YSettingUI.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "\(descriptor.displayName) 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        if ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW"] == "1" {
            window.sharingType = .readOnly
        }
        if let visibleFrame = NSScreen.main?.visibleFrame.insetBy(dx: 20, dy: 20) {
            var frame = window.frame
            frame.size.width = min(frame.width, visibleFrame.width)
            frame.size.height = min(frame.height, visibleFrame.height)
            frame.origin = NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            )
            window.setFrame(frame, display: false)
            window.minSize = NSSize(
                width: min(YSettingUI.minimumWindowSize.width, frame.width),
                height: min(YSettingUI.minimumWindowSize.height, frame.height)
            )
        } else {
            window.minSize = YSettingUI.minimumWindowSize
            window.center()
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = rootViewController

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func showAndActivate() {
        rootViewController.reloadSelectedContent()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        capturePreviewIfRequested()
    }

    private func capturePreviewIfRequested() {
        guard
            let outputPath = ProcessInfo.processInfo.environment["Y_SETTINGS_PREVIEW_OUTPUT"],
            !outputPath.isEmpty
        else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let view = self?.window?.contentView else { return }
            let bounds = view.bounds
            guard
                let representation = view.bitmapImageRepForCachingDisplay(in: bounds)
            else {
                return
            }
            view.cacheDisplay(in: bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                return
            }
            try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    func selectItem(_ identifier: String) {
        rootViewController.selectItem(identifier)
        capturePreviewIfRequested()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class YSettingSectionView: YSettingHoverTrackingView {
    let stack = NSStackView()

    init(
        title: String,
        symbolName: String,
        views: [NSView],
        trailingView: NSView? = nil,
        onHoverChange: ((Bool) -> Void)? = nil
    ) {
        super.init(frame: .zero)
        self.onHoverChange = onHoverChange

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 15, left: 17, bottom: 15, right: 17)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(header(title: title, symbolName: symbolName, trailingView: trailingView))
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateLayerStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerStyle()
    }

    private func header(title: String, symbolName: String, trailingView: NSView?) -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        symbol.contentTintColor = .controlAccentColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = YSettingUI.label(title, size: 14, weight: .semibold)
        let views: [NSView]
        if let trailingView {
            views = [symbol, titleLabel, YSettingUI.spacer(), trailingView]
        } else {
            views = [symbol, titleLabel, YSettingUI.spacer()]
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 18),
            symbol.heightAnchor.constraint(equalToConstant: 18)
        ])

        return row
    }

    private func updateLayerStyle() {
        layer?.cornerRadius = YSettingUI.cardCornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 0.88).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }
}

final class YSettingPill: NSView {
    enum Tone {
        case neutral
        case accent
        case success
        case warning
        case danger
        case disabled
    }

    private let label = NSTextField(labelWithString: "")
    private var tone: Tone

    init(text: String = "", tone: Tone = .neutral) {
        self.tone = tone
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        label.stringValue = text
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 58)
        ])

        updateLayerStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: max(58, size.width + 22), height: 24)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerStyle()
    }

    func setText(_ text: String, tone: Tone) {
        label.stringValue = text
        self.tone = tone
        invalidateIntrinsicContentSize()
        updateLayerStyle()
    }

    private func updateLayerStyle() {
        let colors = palette(for: tone)
        label.textColor = colors.foreground
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = colors.background.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = colors.border.cgColor
    }

    private func palette(for tone: Tone) -> (foreground: NSColor, background: NSColor, border: NSColor) {
        switch tone {
        case .neutral:
            return (.secondaryLabelColor, NSColor.white.withAlphaComponent(0.075), NSColor.white.withAlphaComponent(0.08))
        case .accent:
            return (.controlAccentColor, NSColor.controlAccentColor.withAlphaComponent(0.18), NSColor.controlAccentColor.withAlphaComponent(0.34))
        case .success:
            return (.systemGreen, NSColor.systemGreen.withAlphaComponent(0.18), NSColor.systemGreen.withAlphaComponent(0.34))
        case .warning:
            return (.systemOrange, NSColor.systemOrange.withAlphaComponent(0.18), NSColor.systemOrange.withAlphaComponent(0.34))
        case .danger:
            return (.systemRed, NSColor.systemRed.withAlphaComponent(0.18), NSColor.systemRed.withAlphaComponent(0.34))
        case .disabled:
            return (.tertiaryLabelColor, NSColor.white.withAlphaComponent(0.055), NSColor.white.withAlphaComponent(0.06))
        }
    }
}

final class YSettingActionButton: NSButton {
    private var buttonTitle: String
    private let symbolName: String
    private let role: YSettingButtonRole
    private let titleLabel = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false

    init(title: String, symbolName: String, role: YSettingButtonRole) {
        buttonTitle = title
        self.symbolName = symbolName
        self.role = role
        super.init(frame: .zero)

        super.title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: role == .primary ? .semibold : .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true

        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [symbolView, titleLabel])
        content.orientation = .horizontal
        content.spacing = 6
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 14),
            symbolView.heightAnchor.constraint(equalToConstant: 14),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 11),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -11)
        ])

        updateLayerStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var title: String {
        get { buttonTitle }
        set {
            buttonTitle = newValue
            super.title = ""
            titleLabel.stringValue = newValue
            symbolView.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: newValue
            )
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let textSize = (buttonTitle as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: role == .primary ? .semibold : .medium)
        ])
        return NSSize(width: max(62, ceil(textSize.width) + 46), height: 28)
    }

    override var isEnabled: Bool {
        didSet {
            updateLayerStyle()
        }
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateLayerStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateLayerStyle()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateLayerStyle()
        super.mouseExited(with: event)
    }

    private func updateLayerStyle() {
        let colors = palette()
        titleLabel.textColor = colors.foreground
        symbolView.contentTintColor = colors.foreground
        alphaValue = isEnabled ? 1 : 0.48
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = colors.background.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = colors.border.cgColor
    }

    private func palette() -> (foreground: NSColor, background: NSColor, border: NSColor) {
        let pressed = isHighlighted
        let hoverBoost: CGFloat = isHovering ? 0.05 : 0
        switch role {
        case .primary:
            return (
                .white,
                NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.88 : 0.78 + hoverBoost),
                NSColor.white.withAlphaComponent(0.10)
            )
        case .secondary:
            return (
                .labelColor,
                NSColor.white.withAlphaComponent(pressed ? 0.13 : 0.08 + hoverBoost),
                NSColor.white.withAlphaComponent(0.10)
            )
        case .link:
            return (
                .controlAccentColor,
                NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.18 : 0.10 + hoverBoost),
                NSColor.controlAccentColor.withAlphaComponent(0.22)
            )
        case .danger:
            return (
                .systemRed,
                NSColor.systemRed.withAlphaComponent(pressed ? 0.20 : 0.12 + hoverBoost),
                NSColor.systemRed.withAlphaComponent(0.30)
            )
        }
    }
}

enum YProjectStatusMenu {
    static func make(
        target: AnyObject,
        openSettingsAction: Selector,
        moreProjectsAction: Selector? = nil,
        quitAction: Selector? = nil,
        appName: String
    ) -> NSMenu {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "打开设置", action: openSettingsAction, keyEquivalent: ",")
        settingsItem.target = target
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let moreItem = NSMenuItem(title: "更多 Y-Project", action: moreProjectsAction, keyEquivalent: "")
        moreItem.target = moreProjectsAction == nil ? nil : target
        moreItem.isEnabled = moreProjectsAction != nil
        menu.addItem(moreItem)

        if let quitAction {
            menu.addItem(.separator())
            let quitItem = NSMenuItem(title: "退出 \(appName)", action: quitAction, keyEquivalent: "q")
            quitItem.target = target
            menu.addItem(quitItem)
        }

        return menu
    }
}

class YSettingHoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            setHovering(false)
        }
    }

    private func setHovering(_ value: Bool) {
        guard isHovering != value else {
            return
        }

        isHovering = value
        onHoverChange?(value)
    }
}

private final class YSettingRootViewController: NSViewController {
    private let descriptor: YSettingAppDescriptor
    private let sidebarItems: [YSettingSidebarItem]
    private let sidebarIdentifiers: Set<String>
    private let contentProvider: YSettingWindowController.ContentProvider
    private var selectedIdentifier: String
    private let sidebarStack = NSStackView()
    private let contentHost = YSettingDocumentView()
    private let scrollView = NSScrollView()
    private var sidebarButtons: [String: YSettingSidebarButton] = [:]
    private var currentContentView: NSView?
    private var currentContentConstraints: [NSLayoutConstraint] = []

    init(
        descriptor: YSettingAppDescriptor,
        sidebarItems: [YSettingSidebarItem],
        initialIdentifier: String?,
        contentProvider: @escaping YSettingWindowController.ContentProvider
    ) {
        let sidebarIdentifiers = Set(sidebarItems.map { $0.identifier })
        self.descriptor = descriptor
        self.sidebarItems = sidebarItems
        self.sidebarIdentifiers = sidebarIdentifiers
        self.contentProvider = contentProvider
        selectedIdentifier = initialIdentifier.flatMap { sidebarIdentifiers.contains($0) ? $0 : nil }
            ?? sidebarItems.first?.identifier
            ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        let sidebar = makeSidebar()
        let content = makeContentArea()
        root.addSubview(sidebar)
        root.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: YSettingUI.sidebarWidth),

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        reloadSelectedContent()
    }

    func selectItem(_ identifier: String) {
        guard sidebarIdentifiers.contains(identifier) else {
            return
        }
        guard selectedIdentifier != identifier || currentContentView == nil else {
            return
        }

        selectedIdentifier = identifier
        reloadSelectedContent()
    }

    func reloadSelectedContent() {
        guard isViewLoaded else {
            return
        }

        for (identifier, button) in sidebarButtons {
            button.isSelected = identifier == selectedIdentifier
        }

        NSLayoutConstraint.deactivate(currentContentConstraints)
        currentContentConstraints = []
        currentContentView?.removeFromSuperview()

        let content = contentProvider(selectedIdentifier)
        content.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(content)
        currentContentView = content

        let constraints = [
            content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: YSettingUI.contentInset.left),
            content.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -YSettingUI.contentInset.right),
            content.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: YSettingUI.contentInset.top),
            content.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -YSettingUI.contentInset.bottom),
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -(YSettingUI.contentInset.left + YSettingUI.contentInset.right))
        ]
        NSLayoutConstraint.activate(constraints)
        currentContentConstraints = constraints
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: descriptor.icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.shadowColor = NSColor.black.cgColor
        iconView.layer?.shadowOpacity = 0.22
        iconView.layer?.shadowRadius = 10
        iconView.layer?.shadowOffset = CGSize(width: 0, height: -2)

        let titleLabel = YSettingUI.label(descriptor.displayName, size: 18, weight: .bold)
        titleLabel.alignment = .center
        let subtitleLabel = YSettingUI.label(descriptor.version, size: 13, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        let appStack = NSStackView(views: [iconView, titleLabel, subtitleLabel])
        appStack.orientation = .vertical
        appStack.alignment = .centerX
        appStack.spacing = 8
        appStack.translatesAutoresizingMaskIntoConstraints = false

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .centerX
        sidebarStack.spacing = 8
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        for item in sidebarItems {
            let button = YSettingSidebarButton(item: item, target: self, action: #selector(sidebarButtonClicked(_:)))
            sidebarStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: YSettingUI.sidebarNavigationWidth).isActive = true
            sidebarButtons[item.identifier] = button
        }

        sidebar.addSubview(appStack)
        sidebar.addSubview(sidebarStack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 82),
            iconView.heightAnchor.constraint(equalToConstant: 82),
            appStack.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            appStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 96),
            appStack.widthAnchor.constraint(lessThanOrEqualTo: sidebar.widthAnchor, constant: -56),
            sidebarStack.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            sidebarStack.topAnchor.constraint(equalTo: appStack.bottomAnchor, constant: 58),
            sidebarStack.widthAnchor.constraint(lessThanOrEqualTo: sidebar.widthAnchor, constant: -56)
        ])

        return sidebar
    }

    private func makeContentArea() -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentHost
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            contentHost.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentHost.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        return content
    }

    @objc private func sidebarButtonClicked(_ sender: YSettingSidebarButton) {
        selectItem(sender.itemIdentifier)
    }
}

private final class YSettingDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class YSettingContentStackView: NSStackView {
    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

private final class YSettingSidebarButton: NSButton {
    let itemIdentifier: String
    private let itemTitle: String
    private let symbolName: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private var trackingAreaRef: NSTrackingArea?
    private var hovering = false

    var isSelected: Bool = false {
        didSet {
            updateLayerStyle()
        }
    }

    init(item: YSettingSidebarItem, target: AnyObject, action: Selector) {
        itemIdentifier = item.identifier
        itemTitle = item.title
        symbolName = item.symbolName
        super.init(frame: .zero)

        self.target = target
        self.action = action
        title = ""
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 38).isActive = true

        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: itemTitle)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = itemTitle
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true

        let row = NSStackView(views: [symbolView, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateLayerStyle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateLayerStyle()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateLayerStyle()
        super.mouseExited(with: event)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateLayerStyle()
    }

    private func updateLayerStyle() {
        let active = isSelected || isHighlighted
        let backgroundAlpha: CGFloat
        if active {
            backgroundAlpha = 0.16
        } else {
            backgroundAlpha = hovering ? 0.08 : 0
        }

        titleLabel.textColor = active ? .labelColor : .secondaryLabelColor
        symbolView.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(backgroundAlpha).cgColor
    }
}
