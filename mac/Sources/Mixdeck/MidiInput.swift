import CoreMIDI
import Foundation

/// Listens to every MIDI input (spec/features/control-and-recording.md §6).
@MainActor
final class MidiInput {
    struct Event { var channel: Int; var kind: MidiMapping.Kind; var number: Int; var value: Int; var isNoteOff: Bool }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let onEvent: (Event) -> Void
    private(set) var sourceNames: [String] = []
    private(set) var status = "not started"

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        var st = MIDIClientCreateWithBlock("Mixdeck" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                Task { @MainActor in self?.connectAll() }
            }
        }
        guard st == noErr else { status = "MIDI unavailable (\(st))"; return }
        st = MIDIInputPortCreateWithProtocol(client, "Mixdeck In" as CFString, ._1_0, &port) { [weak self] list, _ in
            // CoreMIDI thread: decode here, hand events to the main actor.
            var events: [Event] = []
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafeBytes(of: packet.pointee.words) { raw in
                    let words = raw.bindMemory(to: UInt32.self)
                    for i in 0..<min(count, words.count) {
                        let w = words[i]
                        guard w >> 28 == 0x2 else { continue }    // MIDI 1.0 channel voice
                        let status = Int(w >> 16 & 0xF0), ch = Int(w >> 16 & 0x0F)
                        let d1 = Int(w >> 8 & 0x7F), d2 = Int(w & 0x7F)
                        switch status {
                        case 0xB0: events.append(Event(channel: ch, kind: .cc, number: d1, value: d2, isNoteOff: false))
                        case 0x90: events.append(Event(channel: ch, kind: .note, number: d1, value: d2, isNoteOff: d2 == 0))
                        case 0x80: events.append(Event(channel: ch, kind: .note, number: d1, value: 0, isNoteOff: true))
                        default: break
                        }
                    }
                }
            }
            guard !events.isEmpty else { return }
            Task { @MainActor in events.forEach { self?.onEvent($0) } }
        }
        guard st == noErr else { status = "MIDI unavailable (\(st))"; return }
        connectAll()
    }

    func connectAll() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)   // connecting twice is harmless
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() {
                names.append(n as String)
            }
        }
        sourceNames = names
        status = names.isEmpty ? "no MIDI inputs found" : "listening to \(names.count) input(s)"
    }
}
