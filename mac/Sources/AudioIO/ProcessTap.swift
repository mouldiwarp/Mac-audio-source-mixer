import CoreAudio
import Foundation

/// Captures system or app audio with a Core Audio process tap (macOS 14.2+),
/// wrapped in a private aggregate device so it can be read like any input device.
/// Needs the "System Audio Recording" permission.
public final class ProcessTap {
    public enum Target: Equatable, Sendable {
        /// Everything except this process (so the mixer's own output is not re-captured).
        case system
        /// Processes whose bundle ID starts with any of these prefixes.
        case apps([String])
    }

    public enum TapError: Error, CustomStringConvertible {
        case noMatchingProcess([String])
        case createTap(OSStatus)
        case noOutputDevice
        case createAggregate(OSStatus)

        public var description: String {
            switch self {
            case .noMatchingProcess(let ids): return "no running process plays audio for \(ids.joined(separator: ", "))"
            case .createTap(let st): return "creating the process tap failed (OSStatus \(st)); check System Audio Recording permission"
            case .noOutputDevice: return "no default output device to clock the tap"
            case .createAggregate(let st): return "creating the tap's aggregate device failed (OSStatus \(st))"
            }
        }
    }

    public let target: Target
    /// The aggregate device to read.
    public let deviceID: AudioObjectID
    /// 1-based input channels of `deviceID` that carry the tap. The aggregate also
    /// contains the clock device's own inputs (if it has any) before the tap.
    public let channelA: UInt32
    public let channelB: UInt32
    private let tapID: AudioObjectID

    public init(_ target: Target) throws {
        self.target = target
        let desc: CATapDescription
        switch target {
        case .system:
            let me = ProcessTap.processObject(pid: getpid()).map { [$0] } ?? []
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
        case .apps(let prefixes):
            let procs = ProcessTap.processObjects(bundlePrefixes: prefixes)
            guard !procs.isEmpty else { throw TapError.noMatchingProcess(prefixes) }
            desc = CATapDescription(stereoMixdownOfProcesses: procs)
        }
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.name = "Mixdeck tap"

        var tap = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr, tap != kAudioObjectUnknown else { throw TapError.createTap(st) }

        guard let outputUID = ProcessTap.defaultOutputUID() else {
            AudioHardwareDestroyProcessTap(tap)
            throw TapError.noOutputDevice
        }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixdeck Tap",
            kAudioAggregateDeviceUIDKey: "Mixdeck_Tap_" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let ast = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard ast == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tap)
            throw TapError.createAggregate(ast)
        }
        tapID = tap
        deviceID = aggID
        let total = UInt32(max(2, AudioDevices.channels(aggID, kAudioObjectPropertyScopeInput)))
        channelA = total - 1
        channelB = total
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(deviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    // MARK: - Process lookup

    /// Running processes known to Core Audio, with their bundle IDs.
    public static func audioProcesses() -> [(object: AudioObjectID, pid: pid_t, bundleID: String)] {
        var addr = AudioDevices.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let bundle = AudioDevices.string(id, kAudioProcessPropertyBundleID) ?? ""
            var pa = AudioDevices.address(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var ps = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(id, &pa, 0, nil, &ps, &pid)
            return (id, pid, bundle)
        }
    }

    static func processObjects(bundlePrefixes: [String]) -> [AudioObjectID] {
        audioProcesses().filter { p in bundlePrefixes.contains { p.bundleID.hasPrefix($0) } }.map(\.object)
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = AudioDevices.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    static func defaultOutputUID() -> String? {
        var addr = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
        else { return nil }
        return AudioDevices.string(dev, kAudioDevicePropertyDeviceUID)
    }
}
