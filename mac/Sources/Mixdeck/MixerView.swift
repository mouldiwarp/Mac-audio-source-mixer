import AppKit
import AudioIO
import SwiftUI

struct MixerView: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        VStack(spacing: 0) {
            if let err = model.engineError { banner(err, color: Theme.danger) }
            if !model.microphoneAuthorized {
                banner("Mixdeck needs Microphone access to read input devices.", color: Theme.warn,
                       action: ("Allow…", { model.requestMicrophone() }))
            }
            let layout = StripLayout.fit(count: model.settings.strips.count)
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: StripLayout.spacing) {
                        ForEach(Array(model.settings.strips.enumerated()), id: \.element.id) { i, strip in
                            StripView(strip: strip, index: i, width: layout.stripWidth)
                        }
                        if model.settings.strips.count < 8 {
                            Button { model.addStrip() } label: {
                                Image(systemName: "plus").font(.title2).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.gold)
                            .gmCard(radius: 22)
                            .help("Add strip")
                            .accessibilityLabel("Add strip")
                        }
                    }
                    .padding(10)
                }
                .scrollDisabled(!layout.needsScroll)
                // The window sizes itself to the strips (see StripLayout); it only
                // scrolls if even the narrowest strips do not fit on the screen.
                .frame(width: layout.areaWidth)
                Rectangle().fill(Theme.gold.opacity(0.22)).frame(width: 1).padding(.vertical, 14)
                BusSection().padding(10)
            }
            footer
        }
        .background(Backdrop())
        .background(WindowTint())
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: model.settings.strips.count)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            RecorderBar()
            Divider().frame(height: 18)
            ScenesMenu()
            BalanceButton()
            Spacer()
            Text(String(format: "Engine load %.1f%%", model.load * 100)).foregroundStyle(Theme.dim)
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Recording, remote control, MIDI and shortcuts")
                .accessibilityLabel("Settings")
            Toggle("Launch at login", isOn: Binding(get: { model.settings.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.obsidian.opacity(0.88))
        .overlay(alignment: .top) { Rectangle().fill(Theme.gold.opacity(0.4)).frame(height: 1) }
    }

    private func banner(_ text: String, color: Color, action: (String, () -> Void)? = nil) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(2)
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
        .font(.callout)
        .foregroundStyle(.black)
        .padding(8)
        .background(color)
    }
}

/// Strip widths that make the mixer window fit its strips on the current screen.
struct StripLayout {
    static let fullWidth: CGFloat = 132
    static let minWidth: CGFloat = 104
    static let spacing: CGFloat = 8
    static let addButton: CGFloat = 44
    static let busSection: CGFloat = 6 * 78 + 5 * 6 + 20
    static let padding: CGFloat = 20

    let stripWidth: CGFloat
    let areaWidth: CGFloat
    let needsScroll: Bool

    static func fit(count: Int) -> StripLayout {
        let screen = (NSScreen.main?.visibleFrame.width ?? 1440) - 40
        let n = CGFloat(max(count, 1))
        let extra = (count < 8 ? addButton + spacing : 0) + padding
        func area(_ w: CGFloat) -> CGFloat { n * w + (n - 1) * spacing + extra }
        let available = screen - busSection
        if area(fullWidth) <= available {
            return StripLayout(stripWidth: fullWidth, areaWidth: area(fullWidth), needsScroll: false)
        }
        let w = floor((available - extra - (n - 1) * spacing) / n)
        if w >= minWidth { return StripLayout(stripWidth: w, areaWidth: area(w), needsScroll: false) }
        return StripLayout(stripWidth: minWidth, areaWidth: max(available, 200), needsScroll: true)
    }
}

struct StripView: View {
    @EnvironmentObject var model: MixerModel
    let strip: StripSetting
    let index: Int
    var width: CGFloat = StripLayout.fullWidth
    @State private var showFx = false

    var body: some View {
        let meter = model.stripMeters[index]
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                TextField("Name", text: Binding(get: { strip.name }, set: { v in model.update(strip.id) { $0.name = v } }))
                    .textFieldStyle(.plain)
                    .font(Theme.heading(12.5))
                    .multilineTextAlignment(.center)
                Button { model.setBalanceSelected(strip.id, !strip.balanceSelected) } label: {
                    Text("⚖").font(.system(size: 11)).foregroundStyle(strip.balanceSelected ? Theme.warn : Theme.dim)
                }
                .buttonStyle(.plain)
                .help(strip.balanceSelected ? "In the level-balance group" : "Add to the level-balance group")
                .accessibilityLabel(strip.balanceSelected ? "Remove from balance" : "Add to balance")
                Button { model.removeStrip(strip.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.dim)
                .help("Remove strip")
                .accessibilityLabel("Remove strip \(strip.name)")
            }
            SourcePicker(strip: strip)
            statusLine
            if case .file = strip.source { PlayerRow(strip: strip) }
            fxRow
            HStack(alignment: .bottom, spacing: 6) {
                MeterView(l: meter.l, r: meter.r)
                Fader(dB: Binding(get: { strip.gainDB }, set: { v in model.update(strip.id) { $0.gainDB = v } }))
            }
            .frame(height: 210)
            LedReadout(text: FaderLaw.label(strip.gainDB) + " dB")
            if strip.balanceSelected { TrimRow(strip: strip) }
            PanControl(pan: Binding(get: { strip.pan }, set: { v in model.update(strip.id) { $0.pan = v } }))
            HStack(spacing: 3) {
                LatchButton(title: "MONO", on: strip.mono) { model.update(strip.id) { $0.mono.toggle() } }
                LatchButton(title: "S", on: strip.solo, tint: Theme.warn) { model.update(strip.id) { $0.solo.toggle() } }
                LatchButton(title: "M", on: strip.mute, tint: Theme.danger) { model.update(strip.id) { $0.mute.toggle() } }
            }
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    ForEach(0..<3, id: \.self) { b in assignButton(b, tint: Theme.hardwareBus) }
                }
                GridRow {
                    ForEach(3..<6, id: \.self) { b in assignButton(b, tint: Theme.virtualBus) }
                }
            }
        }
        .padding(8)
        .frame(width: width)
        .gmCard()
        .contextMenu {
            Button("Remove strip", role: .destructive) { model.removeStrip(strip.id) }
        }
    }

    /// FX button plus the gate and compressor indicators.
    private var fxRow: some View {
        let fx = strip.fx, m = model.stripFx[index]
        return HStack(spacing: 5) {
            LatchButton(title: "FX", on: fx.anyStripBlockOn || strip.inserts.contains { !$0.bypass }) { showFx.toggle() }
                .frame(width: 34)
                .help("Voice processing: denoiser, gate, EQ, compressor, limiter")
                .popover(isPresented: $showFx, arrowEdge: .trailing) {
                    StripFxEditor(stripID: strip.id, index: index).environmentObject(model)
                }
            LedDot(on: fx.gateOn, color: m.gateOpen ? Theme.ok : Theme.danger)
                .help(fx.gateOn ? (m.gateOpen ? "Gate open" : "Gate closed") : "Gate off")
                .accessibilityLabel(fx.gateOn ? (m.gateOpen ? "Gate open" : "Gate closed") : "Gate off")
            ReductionBar(dB: fx.compOn ? m.compGainReductionDB : 0)
                .help(String(format: "Compressor reduction %.1f dB", m.compGainReductionDB))
        }
    }

    private func assignButton(_ b: Int, tint: Color) -> some View {
        LatchButton(title: AppSettings.busNames[b], on: strip.assign[b], tint: tint) {
            model.update(strip.id) { $0.assign[b].toggle() }
        }
        .accessibilityLabel("Send to \(AppSettings.busNames[b])")
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status[strip.id] ?? .empty {
        case .ok:
            let u = model.stripUnderruns[index]
            Text(u == 0 ? "live" : "live · \(u) dropouts").font(.caption2).foregroundStyle(u == 0 ? Theme.ok : Theme.warn)
        case .empty: Text("no source").font(.caption2).foregroundStyle(Theme.dim)
        case .missing: Text("missing; waiting").font(.caption2).foregroundStyle(Theme.warn)
        case .error(let e): Text(e).font(.caption2).foregroundStyle(Theme.danger).lineLimit(2).help(e)
        }
    }
}

struct SourcePicker: View {
    @EnvironmentObject var model: MixerModel
    let strip: StripSetting

    var body: some View {
        Menu {
            Section("Input devices") {
                ForEach(model.inputs, id: \.uid) { dev in
                    if dev.inputChannels <= 2 {
                        Button(dev.name) { pick(dev, 1, dev.inputChannels >= 2 ? 2 : 1) }
                    } else {
                        Menu(dev.name) {
                            ForEach(Array(stride(from: 1, through: dev.inputChannels - 1, by: 2)), id: \.self) { c in
                                Button("Channels \(c)-\(c + 1)") { pick(dev, c, c + 1) }
                            }
                            Divider()
                            ForEach(1...dev.inputChannels, id: \.self) { c in
                                Button("Channel \(c) (mono)") { pick(dev, c, c) }
                            }
                        }
                    }
                }
            }
            Section("Computer audio") {
                Button("System audio (all apps)") { model.setSource(strip.id, .systemAudio) }
                Menu("App") {
                    ForEach(model.apps, id: \.bundleID) { app in
                        Button(app.name) { model.setSource(strip.id, .app(bundleIDs: [app.bundleID], name: app.name)) }
                    }
                    Divider()
                    Button("Refresh list") { model.refreshDevices() }
                }
            }
            Section("File") {
                Button("Audio file…") { model.chooseFile(for: strip.id) }
            }
            Divider()
            Button("None") { model.setSource(strip.id, nil) }
        } label: {
            Text(strip.source?.label ?? "Choose source…").font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Source")
    }

    private func pick(_ dev: AudioDevice, _ a: Int, _ b: Int) {
        model.setSource(strip.id, .device(uid: dev.uid, name: dev.name, channelA: a, channelB: b))
    }
}

struct BusSection: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BUSES").font(Theme.caption(11)).tracking(2.4).foregroundStyle(Theme.gold)
            HStack(alignment: .top, spacing: 6) {
                ForEach(0..<6, id: \.self) { b in BusView(bus: b) }
            }
        }
    }
}

struct BusView: View {
    @EnvironmentObject var model: MixerModel
    let bus: Int
    @State private var showFx = false

    var body: some View {
        let s = model.settings.buses[bus]
        let meter = model.busMeters[bus]
        let tint = bus < 3 ? Theme.hardwareBus : Theme.virtualBus
        VStack(spacing: 6) {
            Text(AppSettings.busNames[bus]).font(Theme.headingBold(13)).tracking(1.2).foregroundStyle(tint)
                .shadow(color: tint.opacity(0.5), radius: 4)
            if bus < 3 {
                Menu {
                    Button("None") { model.setBusDevice(bus, nil) }
                    Divider()
                    ForEach(model.outputs, id: \.uid) { dev in Button(dev.name) { model.setBusDevice(bus, dev) } }
                } label: {
                    Text(s.deviceName ?? "No device").font(.caption2).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 70)
                if let st = model.busStatus[bus] { Text(st).font(.caption2).foregroundStyle(Theme.warn).lineLimit(1) }
            } else {
                Text("Mixer \(AppSettings.busNames[bus])").font(.caption2).foregroundStyle(Theme.dim)
            }
            HStack(alignment: .bottom, spacing: 4) {
                MeterView(l: meter.l, r: meter.r)
                Fader(dB: Binding(get: { s.gainDB }, set: { v in model.updateBus(bus) { $0.gainDB = v } }), tint: tint)
            }
            .frame(height: 210)
            LedReadout(text: FaderLaw.label(s.gainDB))
            LatchButton(title: "M", on: s.mute, tint: Theme.danger) { model.updateBus(bus) { $0.mute.toggle() } }
                .accessibilityLabel("Mute \(AppSettings.busNames[bus])")
            LatchButton(title: s.fx.monoOut ? "FX·MONO" : "FX", on: s.fx.anyBusBlockOn || s.inserts.contains { !$0.bypass }) { showFx.toggle() }
                .accessibilityLabel("Processing for \(AppSettings.busNames[bus])")
                .popover(isPresented: $showFx, arrowEdge: .leading) { BusFxEditor(bus: bus).environmentObject(model) }
        }
        .padding(6)
        .frame(width: 78)
        .gmCard()
    }
}
