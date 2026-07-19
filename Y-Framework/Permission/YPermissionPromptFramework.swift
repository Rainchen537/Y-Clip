import AppKit
import Foundation

enum YPermissionPromptState: String {
    case granted
    case missing
    case restartRequired
}

struct YPermissionPromptAction {
    let title: String
    let perform: () -> Void

    init(title: String, perform: @escaping () -> Void) {
        self.title = title
        self.perform = perform
    }
}

struct YPermissionPromptDescriptor {
    let identifier: String
    let displayName: String
    let explanation: String
    let settingsLocation: String
    let state: () -> YPermissionPromptState
    let requestAction: YPermissionPromptAction?
    let openSettingsAction: YPermissionPromptAction?
    let restartAction: YPermissionPromptAction?
    let repairAction: YPermissionPromptAction?
    let prefersRepairWhenMissing: () -> Bool

    init(
        identifier: String,
        displayName: String,
        explanation: String,
        settingsLocation: String,
        state: @escaping () -> YPermissionPromptState,
        requestAction: YPermissionPromptAction? = nil,
        openSettingsAction: YPermissionPromptAction? = nil,
        restartAction: YPermissionPromptAction? = nil,
        repairAction: YPermissionPromptAction? = nil,
        prefersRepairWhenMissing: @escaping () -> Bool = { false }
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.explanation = explanation
        self.settingsLocation = settingsLocation
        self.state = state
        self.requestAction = requestAction
        self.openSettingsAction = openSettingsAction
        self.restartAction = restartAction
        self.repairAction = repairAction
        self.prefersRepairWhenMissing = prefersRepairWhenMissing
    }
}

struct YPermissionRuntimeDescriptor {
    let installedApplicationPath: String
    let isRunningPreferredCopy: () -> Bool
    let hasPreferredCopy: () -> Bool
    let switchAction: YPermissionPromptAction?

    init(
        installedApplicationPath: String,
        isRunningPreferredCopy: @escaping () -> Bool,
        hasPreferredCopy: @escaping () -> Bool,
        switchAction: YPermissionPromptAction? = nil
    ) {
        self.installedApplicationPath = installedApplicationPath
        self.isRunningPreferredCopy = isRunningPreferredCopy
        self.hasPreferredCopy = hasPreferredCopy
        self.switchAction = switchAction
    }
}

struct YPermissionPromptConfiguration {
    let appName: String
    let persistenceNamespace: String
    let previewEnvironmentKey: String
    let legacyInitialGuidanceKeys: [String]

    init(
        appName: String,
        persistenceNamespace: String,
        previewEnvironmentKey: String = "Y_SETTINGS_PREVIEW",
        legacyInitialGuidanceKeys: [String] = []
    ) {
        self.appName = appName
        self.persistenceNamespace = persistenceNamespace
        self.previewEnvironmentKey = previewEnvironmentKey
        self.legacyInitialGuidanceKeys = legacyInitialGuidanceKeys
    }
}

final class YPermissionPromptCoordinator {
    private struct Snapshot {
        let descriptors: [YPermissionPromptDescriptor]
        let states: [YPermissionPromptState]
        let isRunningPreferredCopy: Bool
        let hasPreferredCopy: Bool

        var allGranted: Bool {
            states.allSatisfy { $0 == .granted }
        }

        var firstUnresolvedIndex: Int? {
            states.firstIndex { $0 != .granted }
        }
    }

    private let configuration: YPermissionPromptConfiguration
    private let defaults: UserDefaults
    private var isPresenting = false

    private var initialGuidanceKey: String {
        "YPermissionPrompt.\(configuration.persistenceNamespace).didPresentInitialGuidance"
    }

    private var subsequentFingerprintKey: String {
        "YPermissionPrompt.\(configuration.persistenceNamespace).lastSubsequentFingerprint"
    }

    init(
        configuration: YPermissionPromptConfiguration,
        defaults: UserDefaults = .standard
    ) {
        self.configuration = configuration
        self.defaults = defaults

        if !defaults.bool(forKey: initialGuidanceKey),
           configuration.legacyInitialGuidanceKeys.contains(where: {
               defaults.bool(forKey: $0)
           }) {
            defaults.set(true, forKey: initialGuidanceKey)
        }
    }

    func presentInitialGuidanceIfNeeded(
        permissions: [YPermissionPromptDescriptor],
        runtime: YPermissionRuntimeDescriptor? = nil
    ) {
        performOnMain { [weak self] in
            guard let self, !self.shouldSuppressPresentation else { return }
            guard !self.defaults.bool(forKey: self.initialGuidanceKey) else { return }

            let snapshot = self.makeSnapshot(permissions: permissions, runtime: runtime)
            self.defaults.set(true, forKey: self.initialGuidanceKey)
            guard !snapshot.allGranted else { return }

            let fingerprint = self.fingerprint(for: snapshot)
            self.defaults.set(fingerprint, forKey: self.subsequentFingerprintKey)
            self.presentInitial(snapshot: snapshot, runtime: runtime)
        }
    }

    func presentMissingPermissionIfNeeded(
        permissions: [YPermissionPromptDescriptor],
        runtime: YPermissionRuntimeDescriptor? = nil,
        reason: String? = nil,
        force: Bool = false
    ) {
        performOnMain { [weak self] in
            guard let self, !self.shouldSuppressPresentation else { return }

            let snapshot = self.makeSnapshot(permissions: permissions, runtime: runtime)
            guard !snapshot.allGranted else {
                self.defaults.removeObject(forKey: self.subsequentFingerprintKey)
                return
            }

            let fingerprint = self.fingerprint(for: snapshot)
            if !force,
               self.defaults.string(forKey: self.subsequentFingerprintKey) == fingerprint {
                return
            }

            self.defaults.set(fingerprint, forKey: self.subsequentFingerprintKey)
            self.presentSubsequent(
                snapshot: snapshot,
                runtime: runtime,
                reason: reason
            )
        }
    }

    func resetPresentationHistory(includeInitialGuidance: Bool = false) {
        defaults.removeObject(forKey: subsequentFingerprintKey)
        if includeInitialGuidance {
            defaults.removeObject(forKey: initialGuidanceKey)
        }
    }

    private var shouldSuppressPresentation: Bool {
        isPresenting || ProcessInfo.processInfo.environment[
            configuration.previewEnvironmentKey
        ] == "1"
    }

    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func makeSnapshot(
        permissions: [YPermissionPromptDescriptor],
        runtime: YPermissionRuntimeDescriptor?
    ) -> Snapshot {
        Snapshot(
            descriptors: permissions,
            states: permissions.map { $0.state() },
            isRunningPreferredCopy: runtime?.isRunningPreferredCopy() ?? true,
            hasPreferredCopy: runtime?.hasPreferredCopy() ?? false
        )
    }

    private func fingerprint(for snapshot: Snapshot) -> String {
        let permissionValues = zip(snapshot.descriptors, snapshot.states)
            .map { "\($0.identifier)=\($1.rawValue)" }
            .joined(separator: ";")
        return [
            "runningPreferred=\(snapshot.isRunningPreferredCopy)",
            "hasPreferred=\(snapshot.hasPreferredCopy)",
            permissionValues
        ].joined(separator: "|")
    }

    private func presentInitial(
        snapshot: Snapshot,
        runtime: YPermissionRuntimeDescriptor?
    ) {
        guard let unresolvedIndex = snapshot.firstUnresolvedIndex else { return }

        if !snapshot.isRunningPreferredCopy {
            presentRuntimeMismatch(
                snapshot: snapshot,
                runtime: runtime,
                isInitial: true
            )
            return
        }

        let permissionLines = zip(snapshot.descriptors, snapshot.states)
            .filter { $0.1 != .granted }
            .map { descriptor, state in
                let suffix = state == .restartRequired ? "（需要重启）" : ""
                return "• \(descriptor.displayName)\(suffix)：\(descriptor.explanation)"
            }
            .joined(separator: "\n")
        let descriptor = snapshot.descriptors[unresolvedIndex]
        let state = snapshot.states[unresolvedIndex]
        let action = preferredAction(for: descriptor, state: state)

        var message = "首次使用前请完成以下授权：\n\n\(permissionLines)"
        if let runtime {
            message += "\n\n系统权限会绑定 App 的签名身份和启动副本。请始终从 \(runtime.installedApplicationPath) 启动正式安装版。"
        }

        presentAlert(
            title: "\(configuration.appName) 需要权限",
            message: message,
            actions: action.map { [$0] } ?? []
        )
    }

    private func presentSubsequent(
        snapshot: Snapshot,
        runtime: YPermissionRuntimeDescriptor?,
        reason: String?
    ) {
        guard let unresolvedIndex = snapshot.firstUnresolvedIndex else { return }

        if !snapshot.isRunningPreferredCopy {
            presentRuntimeMismatch(
                snapshot: snapshot,
                runtime: runtime,
                isInitial: false
            )
            return
        }

        let descriptor = snapshot.descriptors[unresolvedIndex]
        let state = snapshot.states[unresolvedIndex]
        var messageParts: [String] = []
        if let reason, !reason.isEmpty {
            messageParts.append(reason)
        }
        messageParts.append(descriptor.explanation)

        switch state {
        case .granted:
            return
        case .missing:
            messageParts.append("路径：\(descriptor.settingsLocation)。")
        case .restartRequired:
            messageParts.append("授权记录已写入，但当前进程尚未载入。请重启正式安装版后再试。")
        }

        presentAlert(
            title: title(for: descriptor, state: state),
            message: messageParts.joined(separator: "\n\n"),
            actions: actions(for: descriptor, state: state)
        )
    }

    private func presentRuntimeMismatch(
        snapshot: Snapshot,
        runtime: YPermissionRuntimeDescriptor?,
        isInitial: Bool
    ) {
        guard let runtime else { return }

        if snapshot.hasPreferredCopy {
            presentAlert(
                title: "当前运行副本与系统授权不匹配",
                message: "系统权限会绑定 App 的签名身份和启动副本。请切换到 \(runtime.installedApplicationPath)，不要直接运行 DerivedData、副本目录或 Contents/MacOS 可执行文件。",
                actions: runtime.switchAction.map { [$0] } ?? []
            )
        } else {
            let prefix = isInitial ? "首次授权前" : "继续授权前"
            presentAlert(
                title: "请先安装正式版 \(configuration.appName)",
                message: "\(prefix)请先将 App 安装到 \(runtime.installedApplicationPath)。为避免把权限绑定到开发副本，本次不会请求系统授权。",
                actions: []
            )
        }
    }

    private func title(
        for descriptor: YPermissionPromptDescriptor,
        state: YPermissionPromptState
    ) -> String {
        switch state {
        case .granted:
            return "\(descriptor.displayName)已开启"
        case .missing:
            return "\(configuration.appName) 需要\(descriptor.displayName)"
        case .restartRequired:
            return "\(descriptor.displayName)需要重新载入"
        }
    }

    private func preferredAction(
        for descriptor: YPermissionPromptDescriptor,
        state: YPermissionPromptState
    ) -> YPermissionPromptAction? {
        actions(for: descriptor, state: state).first
    }

    private func actions(
        for descriptor: YPermissionPromptDescriptor,
        state: YPermissionPromptState
    ) -> [YPermissionPromptAction] {
        switch state {
        case .granted:
            return []
        case .restartRequired:
            return compactActions([
                descriptor.restartAction,
                descriptor.openSettingsAction
            ])
        case .missing:
            if descriptor.prefersRepairWhenMissing(),
               let repairAction = descriptor.repairAction {
                return compactActions([
                    repairAction,
                    descriptor.openSettingsAction
                ])
            }

            return compactActions([
                descriptor.requestAction ?? descriptor.openSettingsAction,
                descriptor.repairAction
            ])
        }
    }

    private func compactActions(
        _ actions: [YPermissionPromptAction?]
    ) -> [YPermissionPromptAction] {
        var seenTitles = Set<String>()
        return actions.compactMap { action in
            guard let action, seenTitles.insert(action.title).inserted else {
                return nil
            }
            return action
        }
    }

    private func presentAlert(
        title: String,
        message: String,
        actions: [YPermissionPromptAction]
    ) {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message

        let visibleActions = Array(actions.prefix(2))
        visibleActions.forEach { alert.addButton(withTitle: $0.title) }
        alert.addButton(withTitle: visibleActions.isEmpty ? "好" : "稍后")

        let response = alert.runModal()
        let selectedIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard visibleActions.indices.contains(selectedIndex) else { return }
        visibleActions[selectedIndex].perform()
    }
}
