import AppKit
import AudioIO
import AVFoundation
import CMixEngine
import CoreAudio
import Foundation
import ServiceManagement

/// Owns the engine and the settings; the single control thread is the main thread.
@MainActor
final class MixerModel: ObservableObject {
    enum StripStatus: Equatable { case empty, ok, missing, error(String) }

    struct Meter: Equatable { var l: Float = 0; var r: Float = 0 }

    @Published var settings: AppSettings
    @Published private(set) var status: [UUID: StripStatus] = [:]
    @Published private(set) var stripMeters: [Meter] = Array(repeating: Meter(), count: Int(MIXER_MAX_STRIPS))
    @Published private(set) var busMeters: [Meter] = Array(repeating: Meter(), count: 6)
    @Published private(set) var stripFx: [FxMeters] = Array(repeating: FxMeters(), count: Int(MIXER_MAX_STRIPS))
    @Published private(set) var busFx: [FxMeters] = Array(repeating: FxMeters(), count: 6)
    @Published private(set) var stripUnderruns: [UInt64] = Array(repeating: 0, count: Int(MIXER_MAX_STRIPS))
    @Published private(set) var busStatus: [String?] = [nil, nil, nil]
    @Published var engineError: String?
    @Published private(set) var load: Double = 0
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var apps: [(bundleID: String, name: String)] = []

    struct PlayerInfo: Equatable { var playing = false; var position: Double = 0; var duration: Double = 0 }
    enum RecorderState: Equatable { case idle, armed, recording, paused, saving }

    // Phase 4 state (spec/features/control-and-recording.md); logic in MixerModel+Control.swift.
    @Published var playerInfo: [UUID: PlayerInfo] = [:]
    @Published var recorderState = RecorderState.idle
    @Published var recElapsed: Double = 0
    @Published var recDropped: UInt64 = 0
    @Published var recError: String?
    @Published var lastRecording: URL?
    @Published var midiLearnPath: String?
    @Published var lastMidi: String = "—"
    @Published var controlStatus: [String: String] = [:]
    @Published var hotkeyFailures: Set<UUID> = []
    var players: [Int: FilePlayer] = [:]
    var writer: RecordWriter?
    var api: ApiServer?
    var osc: OscServer?
    var midi: MidiInput?
    var hotkeyCenter: HotkeyCenter?

    private(set) var mixer: OpaquePointer?
    private var taps: [Int: ProcessTap] = [:]
    private var saveWork: DispatchWorkItem?
    private var meterTimer: Timer?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init() {
        settings = AppSettings.load()
        refreshDevices()
        startEngine()
        listenForDeviceChanges()
        syncLoginItem()
        startControl()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMeters() }
        }
    }

    // MARK: Engine

    private func startEngine() {
        guard let feed = AudioDevices.device(uid: AudioDevices.feedUID) else {
            engineError = "The Mixdeck driver is not installed. Run: sudo mac/scripts/install-driver.sh"
            return
        }
        var err = [CChar](repeating: 0, count: 256)
        guard let m = MixerCreate(feed.id, 256, &err, err.count) else {
            engineError = "Engine failed to start: " + String(cString: err)
            return
        }
        mixer = m
        engineError = nil
        for i in settings.strips.indices { applyStrip(i) }
        for b in 0..<6 { applyBus(b) }
        if MixerStart(m) != noErr { engineError = "Engine failed to start (feed device)" }
        rearmRecorder()
    }

    func shutdown() {
        meterTimer?.invalidate()
        if recorderState == .recording || recorderState == .paused { stopRecording(); writerDrainForQuit() }
        saveNow()
        if let m = mixer { MixerDestroy(m) }
        mixer = nil
        writer?.shutdown(); writer = nil
        taps.removeAll()
        players.removeAll()
    }

    // MARK: Strips

    func applyStrip(_ i: Int) {
        guard let m = mixer, i < Int(MIXER_MAX_STRIPS) else { return }
        let s = settings.strips[i]
        MixerStripSetGainDB(m, Int32(i), s.gainDB)
        MixerStripSetPan(m, Int32(i), s.pan)
        MixerStripSetMono(m, Int32(i), s.mono)
        MixerStripSetMute(m, Int32(i), s.mute)
        MixerStripSetSolo(m, Int32(i), s.solo)
        for b in 0..<6 { MixerStripSetAssign(m, Int32(i), Int32(b), s.assign[b]) }
        var fx = s.fx.cParams
        MixerStripSetFx(m, Int32(i), &fx)
        attachSource(i)
    }

    private func attachSource(_ i: Int) {
        guard let m = mixer else { return }
        let s = settings.strips[i]
        MixerStripDetach(m, Int32(i))
        taps[i] = nil
        players[i] = nil
        playerInfo[s.id] = nil
        guard let source = s.source else { status[s.id] = .empty; return }
        var err = [CChar](repeating: 0, count: 256)
        switch source {
        case .device(let uid, _, let a, let b):
            guard let dev = AudioDevices.device(uid: uid) else { status[s.id] = .missing; return }
            let st = MixerStripAttachDevice(m, Int32(i), dev.id, UInt32(a), UInt32(b), &err, err.count)
            status[s.id] = st == noErr ? .ok : .error(String(cString: err))
        case .file(let path, _):
            do {
                let p = try FilePlayer(url: URL(fileURLWithPath: path))
                p.setLoop(s.loop)
                let id = s.id
                p.onFinished = { [weak self] in self?.playerInfo[id]?.playing = false }
                MixerStripAttachRing(m, Int32(i), p.ring)
                players[i] = p
                playerInfo[s.id] = PlayerInfo(playing: false, position: 0, duration: p.duration)
                status[s.id] = .ok
            } catch {
                status[s.id] = FileManager.default.fileExists(atPath: path) ? .error("\(error)") : .missing
            }
        case .systemAudio, .app:
            do {
                let target: ProcessTap.Target
                if case .app(let ids, _) = source { target = .apps(ids) } else { target = .system }
                let tap = try ProcessTap(target)
                let st = MixerStripAttachDevice(m, Int32(i), tap.deviceID, tap.channelA, tap.channelB, &err, err.count)
                if st == noErr { taps[i] = tap; status[s.id] = .ok } else { status[s.id] = .error(String(cString: err)) }
            } catch ProcessTap.TapError.noMatchingProcess {
                status[s.id] = .missing
            } catch {
                status[s.id] = .error("\(error)")
            }
        }
    }

    func addStrip() {
        guard settings.strips.count < Int(MIXER_MAX_STRIPS) else { return }
        settings.strips.append(StripSetting(name: "Strip \(settings.strips.count + 1)"))
        applyStrip(settings.strips.count - 1)
        scheduleSave()
    }

    func removeStrip(_ id: UUID) {
        guard let m = mixer, let idx = settings.strips.firstIndex(where: { $0.id == id }) else { return }
        if recorderState == .recording || recorderState == .paused || recorderState == .saving {
            recError = "Stop recording before removing a strip"
            return
        }
        // Engine slots follow array order: detach everything from idx on, then re-apply.
        for i in idx..<settings.strips.count { MixerStripDetach(m, Int32(i)); taps[i] = nil; players[i] = nil }
        settings.strips.remove(at: idx)
        playerInfo[id] = nil
        // Arms follow strip positions.
        settings.recorder.armStrips.remove(at: idx)
        settings.recorder.armStrips.append(false)
        rearmRecorder()
        status[id] = nil
        for i in idx..<settings.strips.count { applyStrip(i) }
        scheduleSave()
    }

    func setSource(_ id: UUID, _ source: SourceSetting?) {
        guard let i = index(id) else { return }
        // The name follows the source unless the user typed their own.
        let current = settings.strips[i].name
        let auto = current.isEmpty || current.hasPrefix("Strip ") || current == "Mic"
            || settings.strips[i].source.map { shortName($0) == current } == true
        settings.strips[i].source = source
        if auto { settings.strips[i].name = source.map(shortName) ?? "Strip \(i + 1)" }
        attachSource(i)
        scheduleSave()
    }

    func update(_ id: UUID, _ change: (inout StripSetting) -> Void) {
        guard let i = index(id), let m = mixer else { return }
        change(&settings.strips[i])
        let s = settings.strips[i]
        MixerStripSetGainDB(m, Int32(i), s.gainDB)
        MixerStripSetPan(m, Int32(i), s.pan)
        MixerStripSetMono(m, Int32(i), s.mono)
        MixerStripSetMute(m, Int32(i), s.mute)
        MixerStripSetSolo(m, Int32(i), s.solo)
        for b in 0..<6 { MixerStripSetAssign(m, Int32(i), Int32(b), s.assign[b]) }
        var fx = s.fx.cParams
        MixerStripSetFx(m, Int32(i), &fx)
        scheduleSave()
    }

    // MARK: Presets

    func applyPreset(_ id: UUID, _ preset: FxSetting) { update(id) { $0.fx = preset.stripPreset } }

    func savePreset(_ name: String, from id: UUID) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = index(id) else { return }
        settings.userPresets[name] = settings.strips[i].fx.stripPreset
        scheduleSave()
    }

    func deletePreset(_ name: String) {
        settings.userPresets[name] = nil
        scheduleSave()
    }

    func index(_ id: UUID) -> Int? { settings.strips.firstIndex { $0.id == id } }

    private func shortName(_ s: SourceSetting) -> String {
        switch s {
        case .device(_, let name, _, _): return String(name.prefix(14))
        case .systemAudio: return "System"
        case .app(_, let name): return String(name.prefix(14))
        case .file(_, let name): return String((name as NSString).deletingPathExtension.prefix(14))
        }
    }

    // MARK: Buses

    private func applyBus(_ b: Int) {
        guard let m = mixer else { return }
        let s = settings.buses[b]
        MixerBusSetGainDB(m, Int32(b), s.gainDB)
        MixerBusSetMute(m, Int32(b), s.mute)
        var fx = s.fx.cParams
        MixerBusSetFx(m, Int32(b), &fx)
        if b < 3 { attachBusDevice(b) }
    }

    private func attachBusDevice(_ b: Int) {
        guard let m = mixer else { return }
        var err = [CChar](repeating: 0, count: 256)
        guard let uid = settings.buses[b].deviceUID else {
            MixerBusSetDevice(m, Int32(b), 0, &err, err.count)
            busStatus[b] = nil
            return
        }
        guard let dev = AudioDevices.device(uid: uid) else {
            MixerBusSetDevice(m, Int32(b), 0, &err, err.count)
            busStatus[b] = "missing"
            return
        }
        busStatus[b] = MixerBusSetDevice(m, Int32(b), dev.id, &err, err.count) == noErr ? nil : String(cString: err)
    }

    func setBusDevice(_ b: Int, _ dev: AudioDevice?) {
        settings.buses[b].deviceUID = dev?.uid
        settings.buses[b].deviceName = dev?.name
        attachBusDevice(b)
        scheduleSave()
    }

    func updateBus(_ b: Int, _ change: (inout BusSetting) -> Void) {
        guard let m = mixer else { return }
        change(&settings.buses[b])
        MixerBusSetGainDB(m, Int32(b), settings.buses[b].gainDB)
        MixerBusSetMute(m, Int32(b), settings.buses[b].mute)
        var fx = settings.buses[b].fx.cParams
        MixerBusSetFx(m, Int32(b), &fx)
        scheduleSave()
    }

    var allVirtualMuted: Bool { (3..<6).allSatisfy { settings.buses[$0].mute } }

    func toggleVirtualMute() {
        let target = !allVirtualMuted
        for b in 3..<6 { updateBus(b) { $0.mute = target } }
    }

    // MARK: Devices

    func refreshDevices() {
        let all = AudioDevices.all()
        inputs = all.filter { $0.inputChannels > 0 && !AudioDevices.isMixdeck($0) }
        outputs = all.filter { $0.outputChannels > 0 && !AudioDevices.isMixdeck($0) }
        let me = Bundle.main.bundleIdentifier ?? ""
        var seen = Set<String>()
        apps = ProcessTap.audioProcesses().compactMap { p in
            guard !p.bundleID.isEmpty, p.bundleID != me, seen.insert(p.bundleID).inserted else { return nil }
            let name = NSRunningApplication(processIdentifier: p.pid)?.localizedName ?? p.bundleID
            return (p.bundleID, name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func listenForDeviceChanges() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.devicesChanged() }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func devicesChanged() {
        refreshDevices()
        if mixer == nil { startEngine(); return }
        // Reconnect anything that was missing.
        for (i, s) in settings.strips.enumerated() where status[s.id] == .missing { attachSource(i) }
        for b in 0..<3 where busStatus[b] == "missing" { attachBusDevice(b) }
    }

    // MARK: Meters

    private func pollMeters() {
        guard let m = mixer else { return }
        var s = MixerStats()
        MixerGetStats(m, &s)
        let strips = withUnsafeBytes(of: &s.strip) { Array($0.bindMemory(to: MixerChannelStats.self)) }
        let buses = withUnsafeBytes(of: &s.bus) { Array($0.bindMemory(to: MixerChannelStats.self)) }
        // Peak hold with a fall-off of about 20 dB per second.
        let fall: Float = 0.79
        stripMeters = zip(stripMeters, strips).map { Meter(l: max($1.peakL, $0.l * fall), r: max($1.peakR, $0.r * fall)) }
        busMeters = zip(busMeters, buses).map { Meter(l: max($1.peakL, $0.l * fall), r: max($1.peakR, $0.r * fall)) }
        stripUnderruns = strips.map(\.underruns)
        // Indicators: hold the gain-reduction peak and let it fall back gently.
        stripFx = zip(stripFx, strips).map { old, new in smoothFx(old, new.fx) }
        busFx = zip(busFx, buses).map { old, new in smoothFx(old, new.fx) }
        load = s.load
        pollPhase4()
    }

    private func smoothFx(_ old: FxMeters, _ new: FxMeters) -> FxMeters {
        var m = new
        m.compGainReductionDB = max(new.compGainReductionDB, old.compGainReductionDB - 1.5)
        m.limiterGainReductionDB = max(new.limiterGainReductionDB, old.limiterGainReductionDB - 1.5)
        m.compInputDB = max(new.compInputDB, old.compInputDB - 1.5)
        return m
    }

    // MARK: Persistence and login item

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() { try? settings.save() }

    /// Makes the system login item match the setting (e.g. after the app was reinstalled).
    private func syncLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        if settings.launchAtLogin && !enabled { try? SMAppService.mainApp.register() }
        if !settings.launchAtLogin && enabled { try? SMAppService.mainApp.unregister() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = on
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            engineError = "Launch at login: \(error.localizedDescription)"
        }
        scheduleSave()
    }

    // MARK: Permissions

    var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in
                self.objectWillChange.send()
                for i in self.settings.strips.indices { self.attachSource(i) }
            }
        }
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
