import Carbon
import Foundation

enum HotKeyError: Error, LocalizedError {
    case installHandlerFailed(OSStatus)
    case registerFailed(OSStatus, HotKey)

    var errorDescription: String? {
        switch self {
        case .installHandlerFailed(let status):
            return "注册快捷键处理器失败：\(status)"
        case .registerFailed(let status, let hotKey):
            return "注册 \(hotKey.displayName) 失败：\(status)"
        }
    }
}

final class HotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let identifier: UInt32
    private let signature: OSType = 0x47434256 // "GCBV"
    private let callback: () -> Void

    init(identifier: UInt32, callback: @escaping () -> Void) {
        self.identifier = identifier
        self.callback = callback
    }

    deinit {
        unregister()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func register(hotKey: HotKey) throws {
        try installHandlerIfNeeded()
        unregister()

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)

        let registerStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            throw HotKeyError.registerFailed(registerStatus, hotKey)
        }
    }

    func unregister() {
        guard let hotKeyRef else {
            return
        }

        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else {
            return
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr else {
                    return status
                }

                let controller = Unmanaged<HotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                guard
                    hotKeyID.signature == controller.signature,
                    hotKeyID.id == controller.identifier
                else {
                    return OSStatus(eventNotHandledErr)
                }

                DispatchQueue.main.async {
                    controller.callback()
                }

                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        guard handlerStatus == noErr else {
            throw HotKeyError.installHandlerFailed(handlerStatus)
        }
    }

}
