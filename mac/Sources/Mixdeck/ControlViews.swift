import AppKit
import SwiftUI

// Phase 4 UI (spec/features/control-and-recording.md).

func timeString(_ t: Double) -> String {
    let s = Int(max(0, t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Transport for a file-player strip.
struct PlayerRow: View {
    @EnvironmentObject var model: MixerModel
    let strip: StripSetting

    var body: some View {
        let info = model.playerInfo[strip.id] ?? .init()
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                iconButton(info.playing ? "pause.fill" : "play.fill", info.playing ? "Pause" : "Play") { model.togglePlay(strip.id) }
                iconButton("stop.fill", "Stop") { model.stopPlayer(strip.id) }
                iconButton("repeat", strip.loop ? "Loop on" : "Loop off", on: strip.loop) { model.setLoop(strip.id, !strip.loop) }
            }
            Text("\(timeString(info.position)) / \(timeString(info.duration))")
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.dim)
        }
    }

    private func iconButton(_ name: String, _ label: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 20)
                .foregroundStyle(on ? Color.black : Theme.text)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.accent : Color(white: 0.25)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct RecorderBar: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let st = model.recorderState
        let busy = st == .recording || st == .paused || st == .saving
        HStack(spacing: 8) {
            Menu {
                Section("Buses") {
                    ForEach(0..<6, id: \.self) { b in
                        Toggle(AppSettings.busNames[b], isOn: Binding(get: { model.settings.recorder.armBuses[b] },
                                                                      set: { try? model.setArm(bus: true, b, $0) }))
                    }
                }
                Section("Strips (post-fader)") {
                    ForEach(Array(model.settings.strips.enumerated()), id: \.element.id) { i, s in
                        Toggle(s.name, isOn: Binding(get: { model.settings.recorder.armStrips[i] },
                                                     set: { try? model.setArm(bus: false, i, $0) }))
                    }
                }
            } label: {
                Text(model.armedCount == 0 ? "Arm…" : "Armed \(armedSummary)").lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
            .help("Choose what to record. Several items record one file each, sample-aligned.")

            Button { model.toggleRecord() } label: {
                Image(systemName: st == .recording ? "pause.circle.fill" : "record.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(st == .recording ? Theme.danger : st == .paused ? Theme.warn : Theme.text)
            }
            .buttonStyle(.plain)
            .disabled(model.armedCount == 0 || st == .saving)
            .help(st == .recording ? "Pause recording" : st == .paused ? "Resume recording" : "Record")
            .accessibilityLabel(st == .recording ? "Pause recording" : "Record")

            Button { model.stopRecording() } label: { Image(systemName: "stop.circle").font(.system(size: 16)) }
                .buttonStyle(.plain)
                .disabled(!(st == .recording || st == .paused))
                .help("Stop and save")
                .accessibilityLabel("Stop recording")

            Group {
                switch st {
                case .recording: Text("● \(timeString(model.recElapsed))").foregroundStyle(Theme.danger)
                case .paused: Text("paused \(timeString(model.recElapsed))").foregroundStyle(Theme.warn)
                case .saving: Text("saving…").foregroundStyle(Theme.dim)
                default: Text(model.settings.recorder.formatLabel).foregroundStyle(Theme.dim)
                }
            }
            .font(.caption.monospacedDigit())
            if model.recDropped > 0 {
                Text("⚠︎ \(model.recDropped) frames dropped").font(.caption2).foregroundStyle(Theme.warn)
            }
            if let e = model.recError {
                Text(e).font(.caption2).foregroundStyle(Theme.danger).lineLimit(1).help(e)
            }
            Button { model.revealRecordings() } label: { Image(systemName: "folder") }
                .buttonStyle(.plain)
                .help("Show recordings in Finder")
                .accessibilityLabel("Show recordings")
        }
    }

    private var armedSummary: String {
        let r = model.settings.recorder
        let buses = (0..<6).filter { r.armBuses[$0] }.map { AppSettings.busNames[$0] }
        let strips = model.settings.strips.indices.filter { r.armStrips[$0] }.map { model.settings.strips[$0].name }
        let all = buses + strips
        return all.count <= 2 ? all.joined(separator: ", ") : "\(all.count) tracks"
    }
}

struct ScenesMenu: View {
    @EnvironmentObject var model: MixerModel
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Menu("Scenes") {
            let names = model.settings.scenes.keys.sorted()
            if names.isEmpty { Text("No scenes yet") }
            ForEach(names, id: \.self) { n in Button("Load “\(n)”") { try? model.loadScene(n) } }
            Divider()
            Button("Save current mix as…") { naming = true }
            if !names.isEmpty {
                Menu("Delete") { ForEach(names, id: \.self) { n in Button(n, role: .destructive) { model.deleteScene(n) } } }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $naming) {
            HStack {
                TextField("Scene name", text: $name).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit(save)
                Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    private func save() {
        model.saveScene(name)
        name = ""
        naming = false
    }
}

// MARK: Settings window

struct ControlSettingsView: View {
    var body: some View {
        TabView {
            RecordingSettingsTab().tabItem { Label("Recording", systemImage: "record.circle") }
            RemoteSettingsTab().tabItem { Label("Remote", systemImage: "network") }
            MidiSettingsTab().tabItem { Label("MIDI", systemImage: "pianokeys") }
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 560, height: 460)
    }
}

struct RecordingSettingsTab: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let r = model.settings.recorder
        Form {
            HStack {
                TextField("Folder", text: Binding(get: { r.directory }, set: { v in model.updateRecorder { $0.directory = v } }))
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    if p.runModal() == .OK, let u = p.url { model.updateRecorder { $0.directory = u.path } }
                }
            }
            TextField("File name prefix", text: Binding(get: { r.prefix }, set: { v in model.updateRecorder { $0.prefix = v } }))
            Text("Files are named “\(RecorderSettings.baseName(prefix: r.prefix)).\(r.fileExtension)”.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Format", selection: Binding(get: { r.format }, set: { v in model.updateRecorder { $0.format = v } })) {
                Text("WAV").tag(RecorderSettings.Format.wav)
                Text("CAF").tag(RecorderSettings.Format.caf)
                Text("M4A (AAC)").tag(RecorderSettings.Format.m4a)
            }
            if r.format == .m4a {
                Picker("Bit rate", selection: Binding(get: { r.kbps }, set: { v in model.updateRecorder { $0.kbps = v } })) {
                    ForEach([96, 128, 192, 256], id: \.self) { Text("\($0) kbps").tag($0) }
                }
            } else {
                Picker("Bit depth", selection: Binding(get: { r.bits }, set: { v in model.updateRecorder { $0.bits = v } })) {
                    Text("16-bit").tag(16); Text("24-bit").tag(24); Text("32-bit float").tag(32)
                }
            }
            Picker("Channels", selection: Binding(get: { r.mono }, set: { v in model.updateRecorder { $0.mono = v } })) {
                Text("Stereo").tag(false); Text("Mono").tag(true)
            }
            Stepper("Pre-record: \(r.preRecordSeconds) s", value: Binding(get: { r.preRecordSeconds },
                                                                       set: { v in model.updateRecorder { $0.preRecordSeconds = v } }), in: 0...10)
            Stepper(r.timerMinutes == 0 ? "Timer stop: off" : "Timer stop: after \(r.timerMinutes) min",
                    value: Binding(get: { r.timerMinutes }, set: { v in model.updateRecorder { $0.timerMinutes = v } }), in: 0...600)
            Text("Recorded at 48 kHz. Arm buses and strips from the mixer window.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(model.recorderState == .recording || model.recorderState == .paused)
    }
}

struct RemoteSettingsTab: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let c = model.settings.control
        Form {
            Section("Text API (TCP, this Mac only)") {
                Toggle("Enabled", isOn: Binding(get: { c.apiOn }, set: { v in model.updateControl { $0.apiOn = v } }))
                port("Port", c.apiPort) { v in model.updateControl { $0.apiPort = v } }
                Text(model.controlStatus["api"] ?? "").font(.caption).foregroundStyle(.secondary)
                Text("printf 'Strip[0].Gain = -10;\\nStrip[0].Gain;\\n' | nc 127.0.0.1 \(c.apiPort)")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("OSC (UDP, this Mac only)") {
                Toggle("Enabled", isOn: Binding(get: { c.oscOn }, set: { v in model.updateControl { $0.oscOn = v } }))
                port("Port", c.oscPort) { v in model.updateControl { $0.oscPort = v } }
                Text(model.controlStatus["osc"] ?? "").font(.caption).foregroundStyle(.secondary)
                Text("Addresses: /strip/0/gain, /bus/3/mute … (no argument = query)").font(.caption).foregroundStyle(.secondary)
            }
            Section("Parameters") {
                Text("Strip[i]: Gain Pan Mute Solo Mono A1–A3 B1–B3 Denoiser Gate EQ PEQ Comp Limiter Gate.Threshold Comp.Ratio … Play Loop Label · Bus[i]: Gain Mute Mono PEQ Limiter · Recorder: Record Pause ArmBus[i] ArmStrip[i] · Scene: Load Save")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshControlStatus() }
    }

    private func port(_ title: String, _ value: Int, _ set: @escaping (Int) -> Void) -> some View {
        TextField(title, value: Binding(get: { value }, set: { set(min(max($0, 1024), 65535)) }), format: .number.grouping(.never))
    }
}

struct MidiSettingsTab: View {
    @EnvironmentObject var model: MixerModel
    @State private var target = "Strip[0].Gain"

    var body: some View {
        let paths = ControlRouter.allPaths(stripCount: model.settings.strips.count)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.controlStatus["midi"] ?? "").foregroundStyle(.secondary)
                Spacer()
                Text("Last: \(model.lastMidi)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let names = model.controlStatus["midiSources"], !names.isEmpty {
                Text(names).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Control", selection: $target) { ForEach(paths, id: \.self) { Text($0).tag($0) } }
                    .frame(width: 300)
                if model.midiLearnPath != nil {
                    Text("Move a control…").foregroundStyle(.orange)
                    Button("Cancel") { model.midiLearnPath = nil }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Learn") { model.midiLearnPath = target }
                }
            }
            List {
                ForEach(model.settings.midiMappings) { m in
                    HStack {
                        Text(m.label).font(.body.monospaced()).frame(width: 130, alignment: .leading)
                        Text("→ \(m.path)")
                        Spacer()
                        if m.kind == .note {
                            Toggle("Momentary", isOn: Binding(get: { m.momentary }, set: { v in
                                if let i = model.settings.midiMappings.firstIndex(where: { $0.id == m.id }) {
                                    model.settings.midiMappings[i].momentary = v; model.scheduleSave()
                                }
                            })).toggleStyle(.checkbox).controlSize(.small)
                        }
                        Button { model.settings.midiMappings.removeAll { $0.id == m.id }; model.scheduleSave() } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.plain).accessibilityLabel("Remove mapping")
                    }
                }
            }
            Text("CC moves a value across its range (gain follows the fader law); CC ≥ 64 or a note toggles on/off controls.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { model.midi?.connectAll(); model.refreshControlStatus() }
    }
}

struct ShortcutsTab: View {
    @EnvironmentObject var model: MixerModel
    @State private var kind = 0          // 0 toggle, 1 set, 2 scene
    @State private var path = "Bus[3].Mute"
    @State private var value = "0"
    @State private var scene = ""
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message = ""

    var body: some View {
        let paths = ControlRouter.allPaths(stripCount: model.settings.strips.count)
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(model.settings.hotkeys) { k in
                    HStack {
                        Text(k.display).font(.body.monospaced()).frame(width: 90, alignment: .leading)
                        Text(k.action.label)
                        Spacer()
                        if model.hotkeyFailures.contains(k.id) { Text("taken by another app").font(.caption).foregroundStyle(.orange) }
                        Button { model.removeHotkey(k.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Remove shortcut")
                    }
                }
            }
            GroupBox("New shortcut") {
                VStack(alignment: .leading) {
                    Picker("Action", selection: $kind) {
                        Text("Toggle").tag(0); Text("Set value").tag(1); Text("Load scene").tag(2)
                    }.pickerStyle(.segmented)
                    if kind == 2 {
                        Picker("Scene", selection: $scene) {
                            ForEach(model.settings.scenes.keys.sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        HStack {
                            Picker("Control", selection: $path) { ForEach(paths, id: \.self) { Text($0).tag($0) } }
                            if kind == 1 { TextField("Value", text: $value).frame(width: 70) }
                        }
                    }
                    HStack {
                        Button(recording ? "Press the keys… (Esc cancels)" : "Record shortcut") { recording ? stopRecording() : startRecording() }
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Shortcuts work while other apps are in front. Use at least one of ⌘ ⌥ ⌃ ⇧.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        message = ""
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); return nil }   // Esc
            guard let d = HotkeyCenter.describe(e) else { message = "add ⌘, ⌥, ⌃ or ⇧"; return nil }
            let action: Hotkey.Action
            switch kind {
            case 0: action = .toggle(path: path)
            case 1: action = .set(path: path, value: value)
            default:
                guard !scene.isEmpty else { message = "choose a scene first"; stopRecording(); return nil }
                action = .scene(name: scene)
            }
            model.addHotkey(Hotkey(keyCode: d.keyCode, modifiers: d.modifiers, display: d.display, action: action))
            message = "added \(d.display)"
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }
}
