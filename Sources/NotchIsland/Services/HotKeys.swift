import AppKit
import Carbon.HIToolbox

/// Global shortcuts for a pending permission: ⌃⌥Y allow, ⌃⌥N deny, ⌃⌥T open terminal.
///
/// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission. The keys are
/// registered only while a permission alert is on screen, so they never shadow other apps'
/// shortcuts the rest of the time.
@MainActor
final class HotKeys {
    enum Action: UInt32 {
        case allow = 1, deny, openTerminal

        var keyCode: Int {
            switch self {
            case .allow: return kVK_ANSI_Y
            case .deny: return kVK_ANSI_N
            case .openTerminal: return kVK_ANSI_T
            }
        }
    }

    static let shared = HotKeys()
    var onAction: ((Action) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var isActive = false

    private init() {}

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        active ? register() : unregister()
    }

    private func register() {
        installHandlerIfNeeded()
        let signature = OSType(0x4E49_534C) // "NISL"
        for action in [Action.allow, .deny, .openTerminal] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: action.rawValue)
            let status = RegisterEventHotKey(UInt32(action.keyCode), UInt32(controlKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            if AppModel.debug {
                FileHandle.standardError.write(Data("[hotkey] \(action) registered: \(status == noErr)\n".utf8))
            }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let action = HotKeys.Action(rawValue: id.id) else { return status }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeys.shared.onAction?(action) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
