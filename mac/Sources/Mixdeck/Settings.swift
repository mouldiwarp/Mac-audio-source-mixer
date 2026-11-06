import Foundation

/// Where a strip's audio comes from (spec/features/mixer.md, Topology).
enum SourceSetting: Codable, Hashable {
    case device(uid: String, name: String, channelA: Int, channelB: Int)
    case systemAudio
    case app(bundleIDs: [String], name: String)

    var label: String {
        switch self {
        case .device(_, let name, let a, let b): return a == b ? "\(name) ch \(a)" : "\(name) \(a)-\(b)"
        case .systemAudio: return "System audio"
        case .app(_, let name): return name
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
}

struct BusSetting: Codable, Hashable {
    var gainDB: Float = 0
    var mute = false
    /// A buses only.
    var deviceUID: String?
    var deviceName: String?
}

struct AppSettings: Codable {
    static let busNames = ["A1", "A2", "A3", "B1", "B2", "B3"]

    var strips: [StripSetting] = [StripSetting(name: "Mic"), StripSetting(name: "System", source: .systemAudio)]
    var buses: [BusSetting] = Array(repeating: BusSetting(), count: 6)
    var launchAtLogin = false

    init() {}

    // Missing keys fall back to defaults, so older or hand-edited files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        strips = try c.decodeIfPresent([StripSetting].self, forKey: .strips) ?? d.strips
        buses = try c.decodeIfPresent([BusSetting].self, forKey: .buses) ?? d.buses
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
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
