import Carbon.HIToolbox

/// Глобальный хоткей ⌃⌥⌘R через Carbon. Не требует разрешения
/// «Универсальный доступ». Возвращает `nil`, если сочетание уже занято.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    init?(keyCode: Int = kVK_ANSI_R,
          modifiers: Int = controlKey | optionKey | cmdKey,
          action: @escaping () -> Void) {
        Self.action = action

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &type, nil, &handler)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4D4E_454D), id: 1) // 'MNEM'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }
}
