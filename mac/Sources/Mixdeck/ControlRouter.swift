import Foundation

/// Parameter paths shared by the control API, OSC, MIDI and shortcuts
/// (spec/features/control-and-recording.md §3).
enum ControlValue: Equatable {
    case number(Double)
    case string(String)

    var double: Double? { if case .number(let d) = self { return d }; return nil }
    var bool: Bool { (double ?? 0) > 0.5 }

    /// Text form used by the API: numbers with one decimal (integers for booleans), strings quoted.
    func text(boolean: Bool) -> String {
        switch self {
        case .number(let d): return boolean ? (d > 0.5 ? "1" : "0") : String(format: "%.1f", d)
        case .string(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }

    /// Parses `-6`, `1`, `true`, `"text"`.
    static func parse(_ raw: String) -> ControlValue? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            return .string(String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\""))
        }
        switch t.lowercased() {
        case "true", "on": return .number(1)
        case "false", "off": return .number(0)
        default: break
        }
        if let d = Double(t) { return .number(d) }
        return nil
    }
}

struct ControlError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

/// A parsed path, e.g. `Strip[0].Comp.Ratio` -> scope strip, index 0, key "comp.ratio".
struct ControlPath: Hashable {
    enum Scope: String { case strip, bus, recorder, scene }
    let scope: Scope
    let index: Int?
    let key: String          // lower-case, may itself contain "[n]" (recorder arms)

    var canonical: String {
        let head: String
        switch scope {
        case .strip: head = "Strip[\(index ?? 0)]"
        case .bus: head = "Bus[\(index ?? 0)]"
        case .recorder: head = "Recorder"
        case .scene: head = "Scene"
        }
        return head + "." + ControlRouter.displayKey(key)
    }

    static func parse(_ raw: String) throws -> ControlPath {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let dot = s.firstIndex(of: ".") else { throw ControlError("bad path '\(s)'") }
        var head = s[..<dot].lowercased()
        let key = s[s.index(after: dot)...].lowercased().replacingOccurrences(of: " ", with: "")
        var index: Int?
        if let open = head.firstIndex(of: "["), head.hasSuffix("]") {
            guard let n = Int(head[head.index(after: open)..<head.index(before: head.endIndex)]) else { throw ControlError("bad index in '\(s)'") }
            index = n
            head = String(head[..<open])
        }
        guard let scope = Scope(rawValue: head) else { throw ControlError("unknown object '\(head)'") }
        if (scope == .strip || scope == .bus) && index == nil { throw ControlError("'\(head)' needs an index, e.g. \(head.capitalized)[0]") }
        guard !key.isEmpty else { throw ControlError("bad path '\(s)'") }
        return ControlPath(scope: scope, index: index, key: key)
    }

    /// OSC address -> path: `/strip/0/comp/ratio` -> `strip[0].comp.ratio`.
    static func fromOSC(_ address: String) throws -> ControlPath {
        var parts: [String] = []
        for seg in address.split(separator: "/") {
            if let n = Int(seg), let last = parts.popLast() { parts.append("\(last)[\(n)]") } else { parts.append(String(seg)) }
        }
        return try parse(parts.joined(separator: "."))
    }
}

enum ParamKind {
    case bool
    case number(ClosedRange<Double>, gain: Bool)
    case string
}

@MainActor
struct ControlRouter {
    unowned let model: MixerModel

    // MARK: Tables

    private struct StripParam {
        let kind: ParamKind
        let get: (StripSetting) -> Double
        let set: (inout StripSetting, Double) -> Void
    }

    private static func b(_ kp: WritableKeyPath<StripSetting, Bool>) -> StripParam {
        StripParam(kind: .bool, get: { $0[keyPath: kp] ? 1 : 0 }, set: { $0[keyPath: kp] = $1 > 0.5 })
    }
    private static func n(_ kp: WritableKeyPath<StripSetting, Float>, _ r: ClosedRange<Double>, gain: Bool = false) -> StripParam {
        StripParam(kind: .number(r, gain: gain), get: { Double($0[keyPath: kp]) },
                   set: { $0[keyPath: kp] = Float(min(max($1, r.lowerBound), r.upperBound)) })
    }
    private static func assign(_ i: Int) -> StripParam {
        StripParam(kind: .bool, get: { $0.assign[i] ? 1 : 0 }, set: { $0.assign[i] = $1 > 0.5 })
    }

    private static let stripParams: [String: StripParam] = [
        "gain": n(\.gainDB, -60...12, gain: true),
        "pan": n(\.pan, -1...1),
        "mono": b(\.mono), "mute": b(\.mute), "solo": b(\.solo),
        "a1": assign(0), "a2": assign(1), "a3": assign(2), "b1": assign(3), "b2": assign(4), "b3": assign(5),
        "denoiser": b(\.fx.denoiseOn), "gate": b(\.fx.gateOn), "eq": b(\.fx.eq3On), "peq": b(\.fx.peqOn),
        "comp": b(\.fx.compOn), "limiter": b(\.fx.limiterOn),
        "denoiser.amount": n(\.fx.denoiseAmount, 0...1),
        "gate.threshold": n(\.fx.gateThresholdDB, -80...0),
        "eq.low": n(\.fx.eqLowDB, -12...12), "eq.mid": n(\.fx.eqMidDB, -12...12), "eq.high": n(\.fx.eqHighDB, -12...12),
        "comp.threshold": n(\.fx.compThresholdDB, -60...0),
        "comp.ratio": n(\.fx.compRatio, 1...20),
        "comp.makeup": n(\.fx.compMakeupDB, -12...24),
        "limiter.ceiling": n(\.fx.limiterCeilingDB, -24...0),
        "loop": b(\.loop),
    ]

    private struct BusParam {
        let kind: ParamKind
        let get: (BusSetting) -> Double
        let set: (inout BusSetting, Double) -> Void
    }
    private static let busParams: [String: BusParam] = [
        "gain": BusParam(kind: .number(-60...12, gain: true), get: { Double($0.gainDB) }, set: { $0.gainDB = Float(min(max($1, -60), 12)) }),
        "mute": BusParam(kind: .bool, get: { $0.mute ? 1 : 0 }, set: { $0.mute = $1 > 0.5 }),
        "mono": BusParam(kind: .bool, get: { $0.fx.monoOut ? 1 : 0 }, set: { $0.fx.monoOut = $1 > 0.5 }),
        "peq": BusParam(kind: .bool, get: { $0.fx.peqOn ? 1 : 0 }, set: { $0.fx.peqOn = $1 > 0.5 }),
        "limiter": BusParam(kind: .bool, get: { $0.fx.limiterOn ? 1 : 0 }, set: { $0.fx.limiterOn = $1 > 0.5 }),
    ]

    /// Display form of a key: "comp.ratio" -> "Comp.Ratio", "armstrip[2]" -> "ArmStrip[2]".
    nonisolated static func displayKey(_ key: String) -> String {
        let special = ["a1": "A1", "a2": "A2", "a3": "A3", "b1": "B1", "b2": "B2", "b3": "B3", "eq": "EQ", "peq": "PEQ",
                       "armstrip": "ArmStrip", "armbus": "ArmBus"]
        return key.split(separator: ".").map { part -> String in
            var p = String(part), suffix = ""
            if let i = p.firstIndex(of: "[") { suffix = String(p[i...]); p = String(p[..<i]) }
            return (special[p] ?? p.prefix(1).uppercased() + p.dropFirst()) + suffix
        }.joined(separator: ".")
    }

    /// Every path for pickers (MIDI learn, shortcuts), for the strips that exist now.
    static func allPaths(stripCount: Int) -> [String] {
        var out: [String] = []
        let order = ["gain", "pan", "mute", "solo", "mono", "a1", "a2", "a3", "b1", "b2", "b3",
                     "denoiser", "gate", "eq", "peq", "comp", "limiter",
                     "denoiser.amount", "gate.threshold", "eq.low", "eq.mid", "eq.high",
                     "comp.threshold", "comp.ratio", "comp.makeup", "limiter.ceiling", "play", "loop"]
        for i in 0..<stripCount { for k in order { out.append("Strip[\(i)].\(displayKey(k))") } }
        for i in 0..<6 { for k in ["gain", "mute", "mono", "peq", "limiter"] { out.append("Bus[\(i)].\(displayKey(k))") } }
        out += ["Recorder.Record", "Recorder.Pause"]
        out += (0..<stripCount).map { "Recorder.ArmStrip[\($0)]" } + (0..<6).map { "Recorder.ArmBus[\($0)]" }
        return out
    }

    func kind(_ p: ControlPath) throws -> ParamKind {
        switch p.scope {
        case .strip:
            if p.key == "play" { return .bool }
            if p.key == "label" { return .string }
            guard let sp = Self.stripParams[p.key] else { throw ControlError("unknown strip parameter '\(p.key)'") }
            return sp.kind
        case .bus:
            guard let bp = Self.busParams[p.key] else { throw ControlError("unknown bus parameter '\(p.key)'") }
            return bp.kind
        case .recorder:
            if ["record", "pause"].contains(p.key) || armIndex(p.key) != nil { return .bool }
            throw ControlError("unknown recorder parameter '\(p.key)'")
        case .scene:
            if ["load", "save"].contains(p.key) { return .string }
            throw ControlError("unknown scene parameter '\(p.key)'")
        }
    }

    private func armIndex(_ key: String) -> (bus: Bool, index: Int)? {
        for (prefix, bus) in [("armstrip[", false), ("armbus[", true)] where key.hasPrefix(prefix) && key.hasSuffix("]") {
            if let n = Int(key.dropFirst(prefix.count).dropLast()) { return (bus, n) }
        }
        return nil
    }

    private func strip(_ p: ControlPath) throws -> StripSetting {
        guard let i = p.index, model.settings.strips.indices.contains(i) else { throw ControlError("no strip \(p.index ?? -1)") }
        return model.settings.strips[i]
    }
    private func busIndex(_ p: ControlPath) throws -> Int {
        guard let i = p.index, (0..<6).contains(i) else { throw ControlError("no bus \(p.index ?? -1)") }
        return i
    }

    // MARK: Get / set

    func get(_ p: ControlPath) throws -> ControlValue {
        switch p.scope {
        case .strip:
            let s = try strip(p)
            if p.key == "label" { return .string(s.name) }
            if p.key == "play" { return .number(model.isPlaying(s.id) ? 1 : 0) }
            guard let sp = Self.stripParams[p.key] else { throw ControlError("unknown strip parameter '\(p.key)'") }
            return .number(sp.get(s))
        case .bus:
            let i = try busIndex(p)
            guard let bp = Self.busParams[p.key] else { throw ControlError("unknown bus parameter '\(p.key)'") }
            return .number(bp.get(model.settings.buses[i]))
        case .recorder:
            let r = model.recorderState
            if p.key == "record" { return .number(r == .recording || r == .paused ? 1 : 0) }
            if p.key == "pause" { return .number(r == .paused ? 1 : 0) }
            if let a = armIndex(p.key) {
                let arms = a.bus ? model.settings.recorder.armBuses : model.settings.recorder.armStrips
                guard arms.indices.contains(a.index) else { throw ControlError("no such arm index") }
                return .number(arms[a.index] ? 1 : 0)
            }
            throw ControlError("unknown recorder parameter '\(p.key)'")
        case .scene:
            throw ControlError("Scene.\(Self.displayKey(p.key)) can only be set")
        }
    }

    func set(_ p: ControlPath, _ v: ControlValue) throws {
        let k = try kind(p)
        switch k {
        case .string: guard case .string = v else { throw ControlError("\(p.canonical) needs a quoted string") }
        case .bool, .number: guard v.double != nil else { throw ControlError("\(p.canonical) needs a number") }
        }
        switch p.scope {
        case .strip:
            let s = try strip(p)
            if p.key == "label", case .string(let name) = v { model.update(s.id) { $0.name = name }; return }
            if p.key == "play" {
                guard case .file = s.source else { throw ControlError("strip \(p.index!) is not a file player") }
                v.bool ? model.play(s.id) : model.pause(s.id)
                return
            }
            guard let sp = Self.stripParams[p.key], let d = v.double else { return }
            model.update(s.id) { sp.set(&$0, d) }
            if p.key == "loop" { model.syncLoop(s.id) }
        case .bus:
            let i = try busIndex(p)
            guard let bp = Self.busParams[p.key], let d = v.double else { return }
            model.updateBus(i) { bp.set(&$0, d) }
        case .recorder:
            if p.key == "record" { v.bool ? model.recordOrResume() : model.stopRecording(); return }
            if p.key == "pause" { model.setRecordingPaused(v.bool); return }
            if let a = armIndex(p.key) {
                let count = a.bus ? 6 : 8
                guard (0..<count).contains(a.index) else { throw ControlError("no such arm index") }
                try model.setArm(bus: a.bus, a.index, v.bool)
            }
        case .scene:
            guard case .string(let name) = v else { return }
            if p.key == "load" { try model.loadScene(name) } else { model.saveScene(name) }
        }
    }

    /// Toggles a boolean path (shortcuts, MIDI notes).
    func toggle(_ p: ControlPath) throws {
        guard case .bool = try kind(p) else { throw ControlError("\(p.canonical) is not on/off") }
        try set(p, .number(try get(p).bool ? 0 : 1))
    }

    // MARK: Text protocol (spec §4)

    /// Runs a script of `Path = value;` / `Path;` statements. Returns reply lines.
    func run(script: String) -> [String] {
        var replies: [String] = []
        for stmt in splitStatements(script) {
            do {
                if let eq = stmt.firstIndex(of: "=") {
                    let path = try ControlPath.parse(String(stmt[..<eq]))
                    guard let v = ControlValue.parse(String(stmt[stmt.index(after: eq)...])) else { throw ControlError("bad value in '\(stmt)'") }
                    try set(path, v)
                } else {
                    let path = try ControlPath.parse(stmt)
                    let v = try get(path)
                    let isBool: Bool = { if case .bool = (try? kind(path)) { return true }; return false }()
                    replies.append("\(path.canonical) = \(v.text(boolean: isBool));")
                }
            } catch {
                replies.append("error: \(error)")
            }
        }
        return replies
    }

    /// Splits on `;` and newlines, ignoring separators inside quotes.
    private func splitStatements(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle() }
            if !quoted && (ch == ";" || ch == "\n" || ch == "\r") {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
            } else { cur.append(ch) }
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }
}
