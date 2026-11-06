// mixdeck-cli: command-line front end for the Mixdeck engine (testing and soak runs).
//
//   mixdeck-cli list
//   mixdeck-cli selftest
//   mixdeck-cli run --strip SPEC [--strip SPEC ...] [--a1 DEVICE] [--a2 DEVICE] [--a3 DEVICE]
//                   [--seconds N] [--buffer N] [--quiet]
//
// Strip SPEC:  SOURCE[:A,B][>BUS,BUS...][@GAIN_DB]
//   SOURCE  a device-name substring, "system", "app=<bundle-id prefix>", or "tone=<Hz>"
//   :A,B    device input channels (default 1,2, or 1,1 for mono devices)
//   >BUSES  any of A1 A2 A3 B1 B2 B3 (default B1)
// Example:
//   mixdeck-cli run --strip "AXE IO:1,1>B1,A1" --strip "BRIO>B2" --strip "system>B1,A1" --a1 "LU28R55"

import AudioIO
import CMixEngine
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}
func option(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func options(_ name: String, _ args: [String]) -> [String] {
    args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
}
func dB(_ x: Float) -> String { x <= 0.000_01 ? " -inf" : String(format: "%5.1f", 20 * log10(x)) }

let busNames = ["A1", "A2", "A3", "B1", "B2", "B3"]
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: mixdeck-cli list | selftest | run --strip SPEC ...   (see the header of main.swift)")
    exit(2)
}

if command == "list" {
    print("Inputs:")
    for d in AudioDevices.all() where d.inputChannels > 0 {
        print("  \(d.name.padding(toLength: max(d.name.count, 28), withPad: " ", startingAt: 0)) \(d.inputChannels) ch  \(Int(d.nominalRate)) Hz")
    }
    print("Outputs:")
    for d in AudioDevices.all() where d.outputChannels > 0 {
        print("  \(d.name.padding(toLength: max(d.name.count, 28), withPad: " ", startingAt: 0)) \(d.outputChannels) ch  \(Int(d.nominalRate)) Hz")
    }
    print("Apps known to Core Audio:")
    for p in ProcessTap.audioProcesses() where !p.bundleID.isEmpty { print("  \(p.bundleID) (pid \(p.pid))") }
    print("Mixdeck Feed (hidden): " + (AudioDevices.device(uid: AudioDevices.feedUID) != nil ? "found" : "NOT FOUND, install the driver"))
    exit(0)
}

guard let feed = AudioDevices.device(uid: AudioDevices.feedUID) else {
    fail("Mixdeck Feed not found. Build and install the driver: make -C Driver && sudo scripts/install-driver.sh")
}
let bufferFrames = UInt32(option("--buffer", args) ?? "256") ?? 256
var errBuf = [CChar](repeating: 0, count: 256)
guard let mixer = MixerCreate(feed.id, bufferFrames, &errBuf, errBuf.count) else { fail(String(cString: errBuf)) }
var taps: [ProcessTap] = []   // kept alive while running

func attach(strip: Int, spec: String) -> String {
    var src = spec, buses = ["B1"]
    if let at = src.lastIndex(of: "@"), let g = Float(src[src.index(after: at)...]) {
        MixerStripSetGainDB(mixer, Int32(strip), g)
        src = String(src[..<at])
    }
    if let gt = src.firstIndex(of: ">") {
        buses = src[src.index(after: gt)...].split(separator: ",").map { $0.uppercased() }
        src = String(src[..<gt])
    }
    var chans: [UInt32]? = nil
    if let colon = src.lastIndex(of: ":"), src[colon...].contains(",") {
        chans = src[src.index(after: colon)...].split(separator: ",").compactMap { UInt32($0) }
        src = String(src[..<colon])
    }
    let bad = buses.filter { !busNames.contains($0) }
    if !bad.isEmpty { fail("unknown bus \(bad.joined(separator: ",")) in \"\(spec)\"") }
    for b in 0..<6 { MixerStripSetAssign(mixer, Int32(strip), Int32(b), buses.contains(busNames[b])) }

    if src.hasPrefix("tone=") {
        let hz = Double(src.dropFirst(5)) ?? 440
        MixerStripAttachTone(mixer, Int32(strip), hz)
        return "tone \(Int(hz)) Hz"
    }
    let deviceID: AudioObjectID
    let label: String
    var a: UInt32 = 1, b: UInt32 = 2
    if src == "system" || src.hasPrefix("app=") {
        let target: ProcessTap.Target = src == "system" ? .system : .apps([String(src.dropFirst(4))])
        do {
            let tap = try ProcessTap(target)
            taps.append(tap)
            deviceID = tap.deviceID
            a = tap.channelA; b = tap.channelB
        } catch { fail("strip \(strip + 1): \(error)") }
        label = src == "system" ? "system audio" : "app \(src.dropFirst(4))"
    } else {
        let matches = AudioDevices.inputs(matching: src)
        guard let dev = matches.first(where: { !AudioDevices.isMixdeck($0) }) ?? matches.first else {
            fail("no input device matches \"\(src)\" (see: mixdeck-cli list)")
        }
        deviceID = dev.id
        if dev.inputChannels < 2 { b = 1 }
        label = dev.name
    }
    if let c = chans { guard c.count == 2 else { fail("channels must be A,B in \"\(spec)\"") }; a = c[0]; b = c[1] }
    let st = MixerStripAttachDevice(mixer, Int32(strip), deviceID, a, b, &errBuf, errBuf.count)
    if st != noErr { fail("strip \(strip + 1) (\(label)): \(String(cString: errBuf))") }
    return "\(label) ch \(a),\(b)"
}

func setA(_ bus: Int, _ name: String?) {
    guard let name else { return }
    guard let dev = AudioDevices.outputs(matching: name).first else { fail("no output device matches \"\(name)\"") }
    if MixerBusSetDevice(mixer, Int32(bus), dev.id, &errBuf, errBuf.count) != noErr {
        fail("\(busNames[bus]) (\(dev.name)): \(String(cString: errBuf))")
    }
    print("\(busNames[bus]) -> \(dev.name)")
}

func stats() -> MixerStats { var s = MixerStats(); MixerGetStats(mixer, &s); return s }
func strips(_ s: MixerStats) -> [MixerChannelStats] { var c = s; return withUnsafeBytes(of: &c.strip) { Array($0.bindMemory(to: MixerChannelStats.self)) } }
func buses(_ s: MixerStats) -> [MixerChannelStats] { var c = s; return withUnsafeBytes(of: &c.bus) { Array($0.bindMemory(to: MixerChannelStats.self)) } }

switch command {
case "selftest":
    // Tone on strip 1 -> B2 only. Strips 2-4 capture Mixer B1/B2/B3 with no assignment,
    // so their meters show what each virtual mic carries.
    MixerStripAttachTone(mixer, 0, 1000)
    for b in 0..<6 { MixerStripSetAssign(mixer, 0, Int32(b), b == Int(MIXER_BUS_B2)) }
    for (i, uid) in AudioDevices.micUIDs.enumerated() {
        guard let mic = AudioDevices.device(uid: uid) else { fail("\(uid) missing") }
        for b in 0..<6 { MixerStripSetAssign(mixer, Int32(i + 1), Int32(b), false) }
        if MixerStripAttachDevice(mixer, Int32(i + 1), mic.id, 1, 2, &errBuf, errBuf.count) != noErr { fail(String(cString: errBuf)) }
    }
    guard MixerStart(mixer) == noErr else { fail("start failed") }
    _ = stats()
    Thread.sleep(forTimeInterval: 3)
    let s = stats()
    let st = strips(s)
    let peaks = (1...3).map { max(st[$0].peakL, st[$0].peakR) }
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }
    check(s.cycles > 100, "master clock running (\(s.cycles) cycles of \(s.bufferFrames) frames)")
    check(abs(peaks[1] - 0.25) < 0.01, "Mixer B2 carries the tone: peak \(dB(peaks[1])) dBFS (expected -12.0)")
    check(peaks[0] < 0.0001, "Mixer B1 silent: \(dB(peaks[0])) dBFS")
    check(peaks[2] < 0.0001, "Mixer B3 silent: \(dB(peaks[2])) dBFS")
    for i in 1...3 { check(st[i].underruns <= 1, "capture of Mixer B\(i): underruns \(st[i].underruns), drift \(String(format: "%.1f", st[i].ratioPPM)) ppm") }
    check(s.load < 0.25, "mix load \(String(format: "%.1f", s.load * 100))% of the cycle")
    MixerDestroy(mixer)
    print(failures == 0 ? "PASSED" : "FAILED (\(failures))")
    if peaks.allSatisfy({ $0 < 0.0001 }) { print("note: all mics silent; the terminal may lack Microphone permission") }
    exit(failures == 0 ? 0 : 1)

case "run":
    let specs = options("--strip", args)
    guard !specs.isEmpty, specs.count <= Int(MIXER_MAX_STRIPS) else { fail("give 1 to \(MIXER_MAX_STRIPS) --strip options") }
    for (i, spec) in specs.enumerated() { print("strip \(i + 1): \(attach(strip: i, spec: spec))   [\(spec)]") }
    setA(0, option("--a1", args)); setA(1, option("--a2", args)); setA(2, option("--a3", args))
    guard MixerStart(mixer) == noErr else { fail("start failed") }

    let seconds = Double(option("--seconds", args) ?? "0") ?? 0
    let quiet = args.contains("--quiet")
    let start = Date()
    var warm: MixerStats? = nil
    func report(final: Bool) {
        let s = stats()
        let st = strips(s), bs = buses(s)
        let t = Int(Date().timeIntervalSince(start))
        if !quiet || final || t % 60 == 0 {
            var line = String(format: "%5ds load %4.1f%% |", t, s.load * 100)
            for i in 0..<specs.count {
                let c = st[i]
                line += " S\(i + 1) \(dB(max(c.peakL, c.peakR))) u\(c.underruns) d\(c.droppedFrames) \(String(format: "%+.0f", c.ratioPPM))ppm |"
            }
            for b in 0..<6 where b >= 3 || bs[b].attached {
                line += " \(busNames[b]) \(dB(max(bs[b].peakL, bs[b].peakR)))"
                if b < 3 { line += " u\(bs[b].underruns) \(String(format: "%+.0f", bs[b].ratioPPM))ppm" }
            }
            print(line)
        }
        if t >= 10 && warm == nil { warm = s }
        if final, let w = warm {
            let w0 = strips(w), b0 = buses(w)
            let under = (0..<specs.count).map { st[$0].underruns - w0[$0].underruns } + (0..<3).map { bs[$0].underruns - b0[$0].underruns }
            let drops = (0..<specs.count).map { st[$0].droppedFrames - w0[$0].droppedFrames } + (0..<3).map { bs[$0].droppedFrames - b0[$0].droppedFrames }
            print("SUMMARY after 10 s warm-up: underruns \(under.reduce(0, +)), dropped frames \(drops.reduce(0, +))")
        }
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { report(final: true); MixerDestroy(mixer); exit(0) }
    sigint.resume()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        if seconds > 0 && Date().timeIntervalSince(start) >= seconds { report(final: true); MixerDestroy(mixer); exit(0) }
        report(final: false)
    }
    timer.resume()
    dispatchMain()

default:
    fail("unknown command \(command)")
}
