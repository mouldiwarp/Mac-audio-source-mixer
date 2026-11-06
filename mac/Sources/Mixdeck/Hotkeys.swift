import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon hot keys, which need no Accessibility permission
/// (spec/features/control-and-recording.md §7).
@MainActor
final class HotkeyCenter {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var ids: [UInt32: UUID] = [:]
    private var handler: EventHandlerRef?
    private let onFire: (UUID) -> Void
    private(set) var failures: Set<UUID> = []
    private static weak var shared: HotkeyCenter?

    init(onFire: @escaping (UUID) -> Void) {
        self.onFire = onFire
        Self.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let n = hk.id
            MainActor.assumeIsolated {
                if let c = HotkeyCenter.shared, let id = c.ids[n] { c.onFire(id) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Replaces all registrations.
    func register(_ keys: [Hotkey]) {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll(); ids.removeAll(); failures.removeAll()
        for (i, k) in keys.enumerated() {
            let n = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(k.keyCode, k.modifiers, EventHotKeyID(signature: OSType(0x4D584B44), id: n),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs[n] = ref; ids[n] = k.id } else { failures.insert(k.id) }
        }
    }

    /// Carbon modifier flags and a display string for a key event.
    static func describe(_ e: NSEvent) -> (keyCode: UInt32, modifiers: UInt32, display: String)? {
        let f = e.modifierFlags
        var mods: UInt32 = 0, text = ""
        if f.contains(.control) { mods |= UInt32(controlKey); text += "⌃" }
        if f.contains(.option) { mods |= UInt32(optionKey); text += "⌥" }
        if f.contains(.shift) { mods |= UInt32(shiftKey); text += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey); text += "⌘" }
        guard mods != 0 else { return nil }
        let names: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                       101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let key = names[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        return (UInt32(e.keyCode), mods, text + key)
    }
}
