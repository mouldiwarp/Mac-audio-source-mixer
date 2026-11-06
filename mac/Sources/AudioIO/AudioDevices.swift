import CoreAudio
import Foundation

/// A Core Audio device as seen by the mixer.
public struct AudioDevice: Hashable, Sendable {
    public let id: AudioObjectID
    public let name: String
    public let uid: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalRate: Double
}

public enum AudioDevices {
    /// UIDs published by MixdeckDriver (spec/features/virtual-devices.md).
    public static let feedUID = "Mixdeck_Feed_UID"
    public static let micUIDs = ["MixerB1_Input_UID", "MixerB2_Input_UID", "MixerB3_Input_UID"]

    /// True for devices published by our own driver.
    public static func isMixdeck(_ d: AudioDevice) -> Bool { d.uid == feedUID || micUIDs.contains(d.uid) }

    /// Output devices whose name contains `query` (case-insensitive).
    public static func outputs(matching query: String) -> [AudioDevice] {
        all().filter { $0.outputChannels > 0 && !isMixdeck($0) && $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// All visible devices. Hidden devices (such as the feed) are not listed; use `device(uid:)`.
    public static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(describe)
    }

    /// Finds a device by UID, including hidden devices.
    public static func device(uid: String) -> AudioDevice? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &cfUID) { q in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), q, &size, &id)
        }
        guard st == noErr, id != kAudioObjectUnknown else { return nil }
        return describe(id)
    }

    /// Input devices whose name contains `query` (case-insensitive).
    public static func inputs(matching query: String) -> [AudioDevice] {
        all().filter { $0.inputChannels > 0 && $0.name.localizedCaseInsensitiveContains(query) }
    }

    static func describe(_ id: AudioObjectID) -> AudioDevice? {
        guard let name = string(id, kAudioObjectPropertyName),
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(id: id, name: name, uid: uid,
                           inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                           outputChannels: channels(id, kAudioObjectPropertyScopeOutput),
                           nominalRate: rate(id))
    }

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    public static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func rate(_ id: AudioObjectID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var r: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &r)
        return r
    }
}
