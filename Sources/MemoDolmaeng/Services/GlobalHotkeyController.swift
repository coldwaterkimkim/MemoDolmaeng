import Carbon.HIToolbox
import Foundation

enum GlobalHotkeyError: LocalizedError {
    case handlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .handlerInstallationFailed(status):
            "전역 단축키 이벤트 핸들러를 만들지 못했어. (OSStatus \(status))"
        case let .registrationFailed(status):
            "Cmd+Shift+M을 등록하지 못했어. 다른 앱 단축키와 충돌할 수 있어. (OSStatus \(status))"
        }
    }
}

@MainActor
final class GlobalHotkeyController {
    private static let signature: OSType = 0x4D_44_4C_47 // MDLG
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) throws {
        self.action = action
        try installHandler()
        try register()
        NSLog("MemoDolmaeng registered global hotkey Cmd+Shift+M")
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private func installHandler() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr,
                      hotKeyID.signature == GlobalHotkeyController.signature,
                      hotKeyID.id == GlobalHotkeyController.hotKeyID
                else {
                    return OSStatus(eventNotHandledErr)
                }

                let controller = Unmanaged<GlobalHotkeyController>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in controller.action() }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        guard status == noErr else {
            throw GlobalHotkeyError.handlerInstallationFailed(status)
        }
    }

    private func register() throws {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            throw GlobalHotkeyError.registrationFailed(status)
        }
    }
}
