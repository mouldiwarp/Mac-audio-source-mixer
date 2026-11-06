import AppKit
import AVFoundation
import CMixEngine
import Foundation

// Phase 4: file players, recorder, control API, OSC, MIDI, shortcuts and scenes
// (spec/features/control-and-recording.md).
extension MixerModel {
    var router: ControlRouter { ControlRouter(model: self) }

    // MARK: File player (§2)

    func isPlaying(_ id: UUID) -> Bool { playerInfo[id]?.playing ?? false }

    private func player(_ id: UUID) -> FilePlayer? { index(id).flatMap { players[$0] } }

    func play(_ id: UUID) { guard let p = player(id) else { return }; p.play(); playerInfo[id]?.playing = true }
    func pause(_ id: UUID) { guard let p = player(id) else { return }; p.pause(); playerInfo[id]?.playing = false }
    func stopPlayer(_ id: UUID) { guard let p = player(id) else { return }; p.stop(); playerInfo[id]?.playing = false }
    func togglePlay(_ id: UUID) { isPlaying(id) ? pause(id) : play(id) }
    func syncLoop(_ id: UUID) { if let i = index(id) { player(id)?.setLoop(settings.strips[i].loop) } }
    func setLoop(_ id: UUID, _ on: Bool) { update(id) { $0.loop = on }; syncLoop(id) }

    func chooseFile(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to play into this strip"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSource(id, .file(path: url.path, name: url.lastPathComponent))
    }

    // MARK: Recorder (§1)

    var armedCount: Int {
        settings.recorder.armBuses.filter { $0 }.count
            + settings.recorder.armStrips.prefix(settings.strips.count).filter { $0 }.count
    }

    /// Installs capture rings for the armed items (only while not recording).
    func rearmRecorder() {
        guard recorderState == .idle || recorderState == .armed else { return }
        if let m = mixer { MixerSetCaptures(m, nil, nil) }
        writer?.shutdown()
        writer = nil
        guard let m = mixer, armedCount > 0 else { recorderState = .idle; return }
        let r = settings.recorder
        let cap = UInt32((r.preRecordSeconds + 4) * 48000)
        var stripRings = [OpaquePointer?](repeating: nil, count: 8)
        var busRings = [OpaquePointer?](repeating: nil, count: 6)
        var tracks: [(String, OpaquePointer)] = []
        for i in 0..<min(8, settings.strips.count) where r.armStrips[i] {
            guard let ring = StereoRingCreate(cap) else { continue }
            stripRings[i] = ring
            tracks.append((settings.strips[i].name, ring))
        }
        for b in 0..<6 where r.armBuses[b] {
            guard let ring = StereoRingCreate(cap) else { continue }
            busRings[b] = ring
            tracks.append((AppSettings.busNames[b], ring))
        }
        let w = RecordWriter(tracks: tracks, preRecordSeconds: r.preRecordSeconds, mono: r.mono)
        w.onStopped = { [weak self] in
            guard let self else { return }
            self.recorderState = .armed
            self.rearmRecorder()   // picks up arm/format changes made while recording
        }
        writer = w
        MixerSetCaptures(m, stripRings, busRings)
        recorderState = .armed
    }

    func setArm(bus: Bool, _ i: Int, _ on: Bool) throws {
        guard recorderState != .recording, recorderState != .paused, recorderState != .saving else {
            throw ControlError("cannot change arms while recording")
        }
        if bus { settings.recorder.armBuses[i] = on } else { settings.recorder.armStrips[i] = on }
        rearmRecorder()
        scheduleSave()
    }

    func updateRecorder(_ change: (inout RecorderSettings) -> Void) {
        let before = settings.recorder
        change(&settings.recorder)
        if before.preRecordSeconds != settings.recorder.preRecordSeconds || before.mono != settings.recorder.mono { rearmRecorder() }
        scheduleSave()
    }

    func recordOrResume() {
        recError = nil
        if recorderState == .paused { writer?.setPaused(false); recorderState = .recording; return }
        guard recorderState == .armed, let w = writer else {
            recError = recorderState == .idle ? "Arm a bus or strip first" : nil
            return
        }
        let r = settings.recorder
        let dir = URL(fileURLWithPath: (r.directory as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = RecorderSettings.baseName(prefix: r.prefix)
            var files: [AVAudioFile] = []
            for name in w.names {
                let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let file = w.names.count > 1 ? "\(base) - \(safe)" : base
                let url = dir.appendingPathComponent(file).appendingPathExtension(r.fileExtension)
                files.append(try AVAudioFile(forWriting: url, settings: r.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false))
                if files.count == 1 { lastRecording = url }
            }
            w.start(files: files)
            recorderState = .recording
            recElapsed = 0
        } catch {
            recError = "Cannot create the recording: \(error.localizedDescription)"
        }
    }

    func setRecordingPaused(_ p: Bool) {
        guard recorderState == .recording || recorderState == .paused else { return }
        writer?.setPaused(p)
        recorderState = p ? .paused : .recording
    }

    func toggleRecord() {
        switch recorderState {
        case .recording: setRecordingPaused(true)
        case .paused, .armed, .idle: recordOrResume()
        case .saving: break
        }
    }

    func stopRecording() {
        guard recorderState == .recording || recorderState == .paused else { return }
        writer?.stop()
        recorderState = .saving
    }

    /// At quit: wait (briefly) for the writer to finish the files.
    func writerDrainForQuit() {
        for _ in 0..<300 where writer?.currentMode == .stopping { usleep(10_000) }
    }

    func revealRecordings() {
        if let last = lastRecording, FileManager.default.fileExists(atPath: last.path) {
            NSWorkspace.shared.activateFileViewerSelecting([last])
        } else {
            let dir = URL(fileURLWithPath: (settings.recorder.directory as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
    }

    func pollPhase4() {
        for (i, p) in players where i < settings.strips.count {
            let id = settings.strips[i].id
            let info = PlayerInfo(playing: p.isPlaying, position: p.position, duration: p.duration)
            if playerInfo[id] != info { playerInfo[id] = info }
        }
        if let w = writer {
            if recorderState == .recording || recorderState == .paused {
                recElapsed = Double(w.framesWritten) / 48000
                let limit = settings.recorder.timerMinutes
                if limit > 0, recElapsed >= Double(limit * 60) { stopRecording() }
            }
            if w.dropped != recDropped { recDropped = w.dropped }
            if let e = w.error, recError != e { recError = e }
        }
    }

    // MARK: Scenes (§8)

    func saveScene(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        settings.scenes[n] = MixScene(strips: settings.strips, buses: settings.buses)
        scheduleSave()
    }

    func loadScene(_ name: String) throws {
        guard let scene = settings.scenes[name] else { throw ControlError("no scene named '\(name)'") }
        for (i, s) in scene.strips.enumerated() where i < settings.strips.count {
            update(settings.strips[i].id) {
                $0.name = s.name; $0.gainDB = s.gainDB; $0.pan = s.pan; $0.mono = s.mono
                $0.mute = s.mute; $0.solo = s.solo; $0.assign = s.assign; $0.fx = s.fx
            }
        }
        for (b, s) in scene.buses.enumerated() where b < 6 {
            updateBus(b) { $0.gainDB = s.gainDB; $0.mute = s.mute; $0.fx = s.fx }
        }
    }

    func deleteScene(_ name: String) { settings.scenes[name] = nil; scheduleSave() }

    // MARK: API, OSC, MIDI, shortcuts (§4–7)

    func startControl() {
        api = ApiServer { [weak self] script in self?.router.run(script: script) ?? [] }
        osc = OscServer { [weak self] msg in self?.handleOSC(msg) }
        midi = MidiInput { [weak self] e in self?.handleMidi(e) }
        hotkeyCenter = HotkeyCenter { [weak self] id in self?.fireHotkey(id) }
        applyControlSettings()
        registerHotkeys()
    }

    func applyControlSettings() {
        let c = settings.control
        c.apiOn ? api?.start(port: c.apiPort) : api?.stop()
        c.oscOn ? osc?.start(port: c.oscPort) : osc?.stop()
        refreshControlStatus()
        // Listener states arrive asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshControlStatus() }
    }

    func refreshControlStatus() {
        controlStatus = ["api": api?.status ?? "off", "osc": osc?.status ?? "off", "midi": midi?.status ?? "off",
                         "midiSources": midi?.sourceNames.joined(separator: ", ") ?? ""]
    }

    func updateControl(_ change: (inout ControlSettings) -> Void) {
        change(&settings.control)
        applyControlSettings()
        scheduleSave()
    }

    private func handleOSC(_ m: OscServer.Message) -> ControlValue? {
        do {
            let path = try ControlPath.fromOSC(m.address)
            if let v = m.args.first {
                if case .number(let d) = v, case .bool = try router.kind(path) { try router.set(path, .number(d > 0.5 ? 1 : 0)) }
                else { try router.set(path, v) }
                return nil
            }
            return try router.get(path)
        } catch {
            return nil
        }
    }

    private func handleMidi(_ e: MidiInput.Event) {
        lastMidi = "Ch \(e.channel + 1) " + (e.kind == .cc ? "CC \(e.number) = \(e.value)" : (e.isNoteOff ? "Note \(e.number) off" : "Note \(e.number) on"))
        if let path = midiLearnPath {
            guard e.kind == .cc || !e.isNoteOff else { return }
            settings.midiMappings.removeAll { $0.channel == e.channel && $0.kind == e.kind && $0.number == e.number }
            settings.midiMappings.append(MidiMapping(channel: e.channel, kind: e.kind, number: e.number, path: path))
            midiLearnPath = nil
            scheduleSave()
            return
        }
        for m in settings.midiMappings where m.channel == e.channel && m.kind == e.kind && m.number == e.number {
            guard let path = try? ControlPath.parse(m.path), let kind = try? router.kind(path) else { continue }
            switch (e.kind, kind) {
            case (.cc, .bool): try? router.set(path, .number(e.value >= 64 ? 1 : 0))
            case (.cc, .number(let r, let gain)):
                let f = Double(e.value) / 127
                let v = gain ? Double(FaderLaw.dB(f)) : r.lowerBound + f * (r.upperBound - r.lowerBound)
                try? router.set(path, .number(v))
            case (.note, .bool):
                if m.momentary { try? router.set(path, .number(e.isNoteOff ? 0 : 1)) }
                else if !e.isNoteOff { try? router.toggle(path) }
            case (.note, .number(let r, _)): if !e.isNoteOff { try? router.set(path, .number(r.upperBound)) }
            default: break
            }
        }
    }

    func registerHotkeys() {
        hotkeyCenter?.register(settings.hotkeys)
        hotkeyFailures = hotkeyCenter?.failures ?? []
    }

    func addHotkey(_ k: Hotkey) {
        settings.hotkeys.removeAll { $0.keyCode == k.keyCode && $0.modifiers == k.modifiers }
        settings.hotkeys.append(k)
        registerHotkeys()
        scheduleSave()
    }

    func removeHotkey(_ id: UUID) {
        settings.hotkeys.removeAll { $0.id == id }
        registerHotkeys()
        scheduleSave()
    }

    private func fireHotkey(_ id: UUID) {
        guard let k = settings.hotkeys.first(where: { $0.id == id }) else { return }
        do {
            switch k.action {
            case .toggle(let p): try router.toggle(try ControlPath.parse(p))
            case .set(let p, let v):
                guard let val = ControlValue.parse(v) else { throw ControlError("bad value \(v)") }
                try router.set(try ControlPath.parse(p), val)
            case .scene(let n): try loadScene(n)
            }
        } catch {
            engineError = "Shortcut \(k.display): \(error)"
        }
    }
}
