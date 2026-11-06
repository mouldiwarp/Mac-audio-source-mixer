import Foundation

/// Where a strip's audio comes from (spec/features/mixer.md, Topology).
enum SourceSetting: Codable, Hashable {
    case device(uid: String, name: String, channelA: Int, channelB: Int)
    case systemAudio
    case app(bundleIDs: [String], name: String)
    case file(path: String, name: String)

    var label: String {
        switch self {
        case .device(_, let name, let a, let b): return a == b ? "\(name) ch \(a)" : "\(name) \(a)-\(b)"
        case .systemAudio: return "System audio"
        case .app(_, let name): return name
        case .file(_, let name): return "▶︎ " + name
        }
    }
}

struct StripSetting: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var source: SourceSetting?
    var gainDB: Float = 0
    var pan: Float = 0
    var mono = false
    var mute = false
    var solo = false
    /// A1 A2 A3 B1 B2 B3
    var assign: [Bool] = [false, false, false, true, false, false]
    var fx = FxSetting()
    /// File player strips only.
    var loop = false
    /// Audio Unit inserts, in processing order (max 4).
    var inserts: [InsertSetting] = []
    /// Level balance (spec/features/plugins-and-balance.md §2).
    var balanceSelected = false
    var trimDB: Float = 0

    init(name: String, source: SourceSetting? = nil) { self.name = name; self.source = source }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.get(.id, UUID()); name = c.get(.name, "Strip"); source = c.get(.source, nil)
        gainDB = c.get(.gainDB, 0); pan = c.get(.pan, 0); mono = c.get(.mono, false)
        mute = c.get(.mute, false); solo = c.get(.solo, false)
        assign = c.get(.assign, [false, false, false, true, false, false])
        fx = c.get(.fx, FxSetting())
        loop = c.get(.loop, false)
        inserts = c.get(.inserts, [])
        balanceSelected = c.get(.balanceSelected, false)
        trimDB = c.get(.trimDB, 0)
    }
}

struct BusSetting: Codable, Hashable {
    var gainDB: Float = 0
    var mute = false
    /// A buses only.
    var deviceUID: String?
    var deviceName: String?
    /// Parametric EQ, limiter and mode (monoOut) only.
    var fx = FxSetting()
    var inserts: [InsertSetting] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gainDB = c.get(.gainDB, 0); mute = c.get(.mute, false)
        deviceUID = c.get(.deviceUID, nil); deviceName = c.get(.deviceName, nil)
        fx = c.get(.fx, FxSetting())
        inserts = c.get(.inserts, [])
    }
}

/// One Audio Unit insert (spec/features/plugins-and-balance.md §1).
struct InsertSetting: Codable, Hashable, Identifiable {
    var id = UUID()
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    var name: String
    var vendor: String
    var bypass = false
    /// The plug-in's full state (property list), saved with the settings.
    var state: Data?
}

struct AppSettings: Codable {
    static let busNames = ["A1", "A2", "A3", "B1", "B2", "B3"]

    var strips: [StripSetting] = [StripSetting(name: "Mic"), StripSetting(name: "System", source: .systemAudio)]
    var buses: [BusSetting] = Array(repeating: BusSetting(), count: 6)
    var launchAtLogin = false
    /// User strip presets by name.
    var userPresets: [String: FxSetting] = [:]
    var recorder = RecorderSettings()
    var control = ControlSettings()
    var midiMappings: [MidiMapping] = []
    var hotkeys: [Hotkey] = []
    var scenes: [String: MixScene] = [:]
    var balanceSeconds = 8

    init() {}

    // Missing keys fall back to defaults, so older or hand-edited files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        strips = try c.decodeIfPresent([StripSetting].self, forKey: .strips) ?? d.strips
        buses = try c.decodeIfPresent([BusSetting].self, forKey: .buses) ?? d.buses
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        userPresets = c.get(.userPresets, [:])
        recorder = c.get(.recorder, RecorderSettings())
        control = c.get(.control, ControlSettings())
        midiMappings = c.get(.midiMappings, [])
        hotkeys = c.get(.hotkeys, [])
        scenes = c.get(.scenes, [:])
        balanceSeconds = c.get(.balanceSeconds, 8)
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mixdeck", isDirectory: true)
        return dir.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              var s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        if s.buses.count != 6 { s.buses = Array(repeating: BusSetting(), count: 6) }
        for i in s.strips.indices where s.strips[i].assign.count != 6 { s.strips[i].assign = [false, false, false, true, false, false] }
        return s
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

// MARK: Voice chain (spec/features/voice-dsp.md)

extension KeyedDecodingContainer {
    /// Missing or malformed keys fall back to the default, so older settings files still load.
    func get<T: Decodable>(_ key: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
}

enum PeqType: Int32, Codable, CaseIterable, Identifiable {
    case peak, lowShelf, highShelf, highPass, lowPass
    var id: Int32 { rawValue }
    var label: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .highPass: return "High-pass"
        case .lowPass: return "Low-pass"
        }
    }
    var hasGain: Bool { self != .highPass && self != .lowPass }
}

struct PeqBand: Codable, Hashable {
    var on = false
    var type = PeqType.peak
    var freq: Float = 1000
    var gainDB: Float = 0
    var q: Float = 1

    init(on: Bool = false, type: PeqType = .peak, freq: Float, gainDB: Float = 0, q: Float = 1) {
        self.on = on; self.type = type; self.freq = freq; self.gainDB = gainDB; self.q = q
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = c.get(.on, false); type = c.get(.type, .peak); freq = c.get(.freq, 1000); gainDB = c.get(.gainDB, 0); q = c.get(.q, 1)
    }
}

struct FxSetting: Codable, Hashable {
    static let defaultFreqs: [Float] = [100, 250, 1000, 3000, 6000, 12000]

    var denoiseOn = false, denoiseAmount: Float = 0.5
    var gateOn = false, gateThresholdDB: Float = -50, gateRangeDB: Float = 40
    var gateAttackMs: Float = 1, gateHoldMs: Float = 80, gateReleaseMs: Float = 200
    var eq3On = false, eqLowDB: Float = 0, eqMidDB: Float = 0, eqHighDB: Float = 0
    var peqOn = false
    var peq: [PeqBand] = FxSetting.defaultFreqs.map { PeqBand(freq: $0) }
    var compOn = false, compThresholdDB: Float = -20, compRatio: Float = 3, compKneeDB: Float = 6
    var compAttackMs: Float = 10, compReleaseMs: Float = 150, compMakeupDB: Float = 0
    var limiterOn = false, limiterCeilingDB: Float = -1, limiterReleaseMs: Float = 100
    var monoOut = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FxSetting()
        denoiseOn = c.get(.denoiseOn, d.denoiseOn); denoiseAmount = c.get(.denoiseAmount, d.denoiseAmount)
        gateOn = c.get(.gateOn, d.gateOn); gateThresholdDB = c.get(.gateThresholdDB, d.gateThresholdDB)
        gateRangeDB = c.get(.gateRangeDB, d.gateRangeDB); gateAttackMs = c.get(.gateAttackMs, d.gateAttackMs)
        gateHoldMs = c.get(.gateHoldMs, d.gateHoldMs); gateReleaseMs = c.get(.gateReleaseMs, d.gateReleaseMs)
        eq3On = c.get(.eq3On, d.eq3On); eqLowDB = c.get(.eqLowDB, 0); eqMidDB = c.get(.eqMidDB, 0); eqHighDB = c.get(.eqHighDB, 0)
        peqOn = c.get(.peqOn, d.peqOn)
        peq = c.get(.peq, d.peq)
        if peq.count != 6 { peq = d.peq }
        compOn = c.get(.compOn, d.compOn); compThresholdDB = c.get(.compThresholdDB, d.compThresholdDB)
        compRatio = c.get(.compRatio, d.compRatio); compKneeDB = c.get(.compKneeDB, d.compKneeDB)
        compAttackMs = c.get(.compAttackMs, d.compAttackMs); compReleaseMs = c.get(.compReleaseMs, d.compReleaseMs)
        compMakeupDB = c.get(.compMakeupDB, d.compMakeupDB)
        limiterOn = c.get(.limiterOn, d.limiterOn); limiterCeilingDB = c.get(.limiterCeilingDB, d.limiterCeilingDB)
        limiterReleaseMs = c.get(.limiterReleaseMs, d.limiterReleaseMs)
        monoOut = c.get(.monoOut, d.monoOut)
    }

    /// True if any strip block is switched on (for the FX button highlight).
    var anyStripBlockOn: Bool { denoiseOn || gateOn || eq3On || (peqOn && peq.contains { $0.on }) || compOn || limiterOn }
    var anyBusBlockOn: Bool { (peqOn && peq.contains { $0.on }) || limiterOn || monoOut }

    /// Everything except gain, pan and routing is part of a preset; for a strip that is this whole struct.
    var stripPreset: FxSetting { var p = self; p.monoOut = false; return p }
}

/// Built-in strip presets (spec/features/voice-dsp.md, Presets).
enum FxPresets {
    static var builtIn: [(name: String, fx: FxSetting)] {
        var clean = FxSetting()
        clean.gateOn = true; clean.gateThresholdDB = -50
        clean.peqOn = true; clean.peq[0] = PeqBand(on: true, type: .highPass, freq: 80, q: 0.707)
        clean.compOn = true; clean.compRatio = 3; clean.compThresholdDB = -20
        clean.limiterOn = true; clean.limiterCeilingDB = -1

        var broadcast = FxSetting()
        broadcast.peqOn = true
        broadcast.peq[0] = PeqBand(on: true, type: .highPass, freq: 80, q: 0.707)
        broadcast.peq[1] = PeqBand(on: true, type: .lowShelf, freq: 100, gainDB: -2, q: 0.707)
        broadcast.peq[4] = PeqBand(on: true, type: .peak, freq: 4000, gainDB: 3, q: 1)
        broadcast.compOn = true; broadcast.compRatio = 4; broadcast.compThresholdDB = -24; broadcast.compMakeupDB = 6
        broadcast.limiterOn = true; broadcast.limiterCeilingDB = -1

        var webcam = FxSetting()
        webcam.denoiseOn = true; webcam.denoiseAmount = 0.7
        webcam.gateOn = true; webcam.gateThresholdDB = -45
        webcam.peqOn = true
        webcam.peq[0] = PeqBand(on: true, type: .highPass, freq: 120, q: 0.707)
        webcam.peq[1] = PeqBand(on: true, type: .lowShelf, freq: 100, gainDB: -3, q: 0.707)
        webcam.compOn = true; webcam.compRatio = 3; webcam.compThresholdDB = -22; webcam.compMakeupDB = 4
        webcam.limiterOn = true; webcam.limiterCeilingDB = -1

        return [("Flat", FxSetting()), ("Voice – clean", clean), ("Voice – broadcast", broadcast), ("Webcam mic cleanup", webcam)]
    }
}

// MARK: Phase 4 (spec/features/control-and-recording.md)

struct RecorderSettings: Codable, Hashable {
    enum Format: String, Codable, CaseIterable { case wav, caf, m4a }
    var directory: String = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mixdeck Recordings").path
    var prefix = "Record"
    var format = Format.wav
    var bits = 24            // wav/caf: 16, 24, 32 (float)
    var kbps = 192           // m4a
    var mono = false
    var preRecordSeconds = 0
    var timerMinutes = 0     // 0 = off
    var armStrips: [Bool] = Array(repeating: false, count: 8)
    var armBuses: [Bool] = [false, false, false, true, false, false]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecorderSettings()
        directory = c.get(.directory, d.directory); prefix = c.get(.prefix, d.prefix)
        format = c.get(.format, d.format); bits = c.get(.bits, d.bits); kbps = c.get(.kbps, d.kbps)
        mono = c.get(.mono, d.mono); preRecordSeconds = c.get(.preRecordSeconds, 0); timerMinutes = c.get(.timerMinutes, 0)
        armStrips = c.get(.armStrips, d.armStrips); armBuses = c.get(.armBuses, d.armBuses)
        if armStrips.count != 8 { armStrips = d.armStrips }
        if armBuses.count != 6 { armBuses = d.armBuses }
    }
}

struct ControlSettings: Codable, Hashable {
    var apiOn = false
    var apiPort = 9040
    var oscOn = false
    var oscPort = 9000

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiOn = c.get(.apiOn, false); apiPort = c.get(.apiPort, 9040)
        oscOn = c.get(.oscOn, false); oscPort = c.get(.oscPort, 9000)
    }
}

struct MidiMapping: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case cc, note }
    var id = UUID()
    var channel: Int        // 0...15
    var kind: Kind
    var number: Int         // CC or note number
    var path: String
    var momentary = false   // notes on boolean paths

    var label: String { "Ch \(channel + 1) " + (kind == .cc ? "CC \(number)" : "Note \(number)") }
}

struct Hotkey: Codable, Hashable, Identifiable {
    enum Action: Codable, Hashable {
        case toggle(path: String)
        case set(path: String, value: String)
        case scene(name: String)

        var label: String {
            switch self {
            case .toggle(let p): return "Toggle \(p)"
            case .set(let p, let v): return "\(p) = \(v)"
            case .scene(let n): return "Load scene “\(n)”"
            }
        }
    }
    var id = UUID()
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier flags
    var display: String
    var action: Action
}

/// Mixing state without sources or devices (spec §8).
struct MixScene: Codable, Hashable {
    var strips: [StripSetting]
    var buses: [BusSetting]
}
