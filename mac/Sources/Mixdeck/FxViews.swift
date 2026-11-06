import CMixEngine
import SwiftUI

// Editors for the voice chain (spec/features/voice-dsp.md).

/// Labelled slider with a value readout. `log` maps the travel logarithmically (frequencies, times).
struct ParamSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var unit = ""
    var format = "%.1f"
    var log = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 74, alignment: .leading).foregroundStyle(Theme.dim)
            Slider(value: Binding(get: { toPos(value) }, set: { value = fromPos($0) }), in: 0...1)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(readout)
            Text(readout).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
        .font(.caption)
    }

    private var readout: String {
        if unit == "Hz", value >= 1000 { return String(format: "%.2f kHz", value / 1000) }
        return String(format: format, value) + (unit.isEmpty ? "" : " " + unit)
    }
    private func toPos(_ v: Float) -> Double {
        let v = min(max(v, range.lowerBound), range.upperBound)
        if log { return Double(Foundation.log(v / range.lowerBound) / Foundation.log(range.upperBound / range.lowerBound)) }
        return Double((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
    private func fromPos(_ p: Double) -> Float {
        let p = Float(p)
        let v = log ? range.lowerBound * pow(range.upperBound / range.lowerBound, p)
                    : range.lowerBound + p * (range.upperBound - range.lowerBound)
        // Keep stored values tidy.
        if log { return v >= 100 ? v.rounded() : (v * 10).rounded() / 10 }
        return (v * 10).rounded() / 10
    }
}

/// A block with an on/off switch. Controls stay editable while off.
struct FxSection<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: $isOn) { Text(title.uppercased()).font(Theme.heading(12)).tracking(1.4).foregroundStyle(isOn ? Theme.gold : Theme.text) }
                    .toggleStyle(.switch).controlSize(.mini)
                Spacer()
                if let trailing { trailing }
            }
            content.opacity(isOn ? 1 : 0.45)
        }
        .padding(10)
        .gmCard()
    }
}

/// Transfer curve of the compressor with the live input level.
struct CompGraph: View {
    let fx: FxSetting
    let inputDB: Float
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let lo: Float = -60
            func pt(_ inDB: Float, _ outDB: Float) -> CGPoint {
                CGPoint(x: CGFloat((inDB - lo) / -lo) * size.width, y: CGFloat(1 - (outDB - lo) / -lo) * size.height)
            }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.track))
            var grid = Path()
            for d in stride(from: lo, through: 0, by: 12) {
                grid.move(to: pt(d, lo)); grid.addLine(to: pt(d, 0))
                grid.move(to: pt(lo, d)); grid.addLine(to: pt(0, d))
            }
            ctx.stroke(grid, with: .color(Color.white.opacity(0.07)), lineWidth: 1)
            var unity = Path(); unity.move(to: pt(lo, lo)); unity.addLine(to: pt(0, 0))
            ctx.stroke(unity, with: .color(Color.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var curve = Path()
            for i in 0...120 {
                let x = lo + Float(i) / 120 * -lo
                let p = pt(x, fx.compCurve(x))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(Theme.accent), lineWidth: 2)
            if active, inputDB > lo {
                let x = min(inputDB, 0)
                let p = pt(x, fx.compCurve(x))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(Theme.warn))
            }
        }
        .frame(width: 120, height: 120)
        .accessibilityLabel("Compressor transfer curve")
    }
}

/// Horizontal gain-reduction bar, 0...24 dB.
struct ReductionBar: View {
    let dB: Float
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.track))
            let w = size.width * CGFloat(min(max(dB, 0), 24) / 24)
            ctx.fill(Path(CGRect(x: size.width - w, y: 0, width: w, height: size.height)), with: .color(Theme.warn))
        }
        .frame(height: 6)
        .accessibilityLabel("Gain reduction")
        .accessibilityValue(String(format: "%.1f dB", dB))
    }
}

struct PeqEditor: View {
    @Binding var bands: [PeqBand]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(bands.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Toggle("", isOn: $bands[i].on).toggleStyle(.checkbox).labelsHidden()
                        .accessibilityLabel("Band \(i + 1)")
                    Picker("", selection: $bands[i].type) {
                        ForEach(PeqType.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 96).controlSize(.small)
                    VStack(spacing: 0) {
                        ParamSlider(title: "Freq", value: $bands[i].freq, range: 20...20000, unit: "Hz", format: "%.0f", log: true)
                        if bands[i].type.hasGain {
                            ParamSlider(title: "Gain", value: $bands[i].gainDB, range: -18...18, unit: "dB")
                        }
                        ParamSlider(title: "Q", value: $bands[i].q, range: 0.1...10, format: "%.2f", log: true)
                    }
                }
                .opacity(bands[i].on ? 1 : 0.55)
                if i < bands.count - 1 { Divider() }
            }
        }
    }
}

struct StripFxEditor: View {
    @EnvironmentObject var model: MixerModel
    let stripID: UUID
    let index: Int
    @State private var presetName = ""

    private var fx: FxSetting { model.settings.strips.first { $0.id == stripID }?.fx ?? FxSetting() }
    private func bind<T>(_ kp: WritableKeyPath<FxSetting, T>) -> Binding<T> {
        Binding(get: { fx[keyPath: kp] }, set: { v in model.update(stripID) { $0.fx[keyPath: kp] = v } })
    }

    var body: some View {
        let meters = model.stripFx[index]
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                presets
                if let i = model.settings.strips.firstIndex(where: { $0.id == stripID }) {
                    InsertsSection(target: .strip(i))
                }
                FxSection(title: "Denoiser", isOn: bind(\.denoiseOn)) {
                    ParamSlider(title: "Amount", value: Binding(get: { fx.denoiseAmount * 100 },
                                                               set: { v in model.update(stripID) { $0.fx.denoiseAmount = v / 100 } }),
                                range: 0...100, unit: "%", format: "%.0f")
                    Text("Removes steady noise (fans, hiss). Adds 10.7 ms delay.").font(.caption2).foregroundStyle(Theme.dim)
                }
                FxSection(title: "Gate", isOn: bind(\.gateOn), trailing: AnyView(gateLED(meters))) {
                    ParamSlider(title: "Threshold", value: bind(\.gateThresholdDB), range: -80...0, unit: "dB")
                    ParamSlider(title: "Range", value: bind(\.gateRangeDB), range: 0...80, unit: "dB")
                    ParamSlider(title: "Attack", value: bind(\.gateAttackMs), range: 0.1...50, unit: "ms", log: true)
                    ParamSlider(title: "Hold", value: bind(\.gateHoldMs), range: 0...500, unit: "ms", format: "%.0f")
                    ParamSlider(title: "Release", value: bind(\.gateReleaseMs), range: 5...2000, unit: "ms", format: "%.0f", log: true)
                }
                FxSection(title: "EQ", isOn: bind(\.eq3On)) {
                    ParamSlider(title: "Low 100 Hz", value: bind(\.eqLowDB), range: -12...12, unit: "dB")
                    ParamSlider(title: "Mid 1 kHz", value: bind(\.eqMidDB), range: -12...12, unit: "dB")
                    ParamSlider(title: "High 8 kHz", value: bind(\.eqHighDB), range: -12...12, unit: "dB")
                }
                FxSection(title: "Parametric EQ", isOn: bind(\.peqOn)) {
                    PeqEditor(bands: bind(\.peq))
                }
                FxSection(title: "Compressor", isOn: bind(\.compOn),
                          trailing: AnyView(Text(String(format: "GR %.1f dB", fx.compOn ? meters.compGainReductionDB : 0))
                                                .font(.caption.monospacedDigit()).foregroundStyle(Theme.warn))) {
                    HStack(alignment: .top, spacing: 10) {
                        CompGraph(fx: fx, inputDB: meters.compInputDB, active: fx.compOn)
                        VStack(spacing: 2) {
                            ParamSlider(title: "Threshold", value: bind(\.compThresholdDB), range: -60...0, unit: "dB")
                            ParamSlider(title: "Ratio", value: bind(\.compRatio), range: 1...20, unit: ": 1", log: true)
                            ParamSlider(title: "Knee", value: bind(\.compKneeDB), range: 0...12, unit: "dB")
                            ParamSlider(title: "Attack", value: bind(\.compAttackMs), range: 0.1...200, unit: "ms", log: true)
                            ParamSlider(title: "Release", value: bind(\.compReleaseMs), range: 10...2000, unit: "ms", format: "%.0f", log: true)
                            ParamSlider(title: "Make-up", value: bind(\.compMakeupDB), range: -12...24, unit: "dB")
                        }
                    }
                    ReductionBar(dB: fx.compOn ? meters.compGainReductionDB : 0)
                }
                FxSection(title: "Limiter (after fader)", isOn: bind(\.limiterOn),
                          trailing: AnyView(Text(String(format: "GR %.1f dB", fx.limiterOn ? meters.limiterGainReductionDB : 0))
                                                .font(.caption.monospacedDigit()).foregroundStyle(Theme.warn))) {
                    ParamSlider(title: "Ceiling", value: bind(\.limiterCeilingDB), range: -24...0, unit: "dB")
                    ParamSlider(title: "Release", value: bind(\.limiterReleaseMs), range: 10...1000, unit: "ms", format: "%.0f", log: true)
                }
            }
            .padding(10)
        }
        .frame(width: 470, height: 640)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }

    private func gateLED(_ m: FxMeters) -> some View {
        let open = !fx.gateOn || m.gateOpen
        return HStack(spacing: 4) {
            LedDot(on: true, color: open ? Theme.ok : Theme.danger, size: 8)
            Text(open ? "open" : "closed").font(.caption2).foregroundStyle(Theme.dim)
        }
        .accessibilityElement(children: .combine)
    }

    private var presets: some View {
        HStack(spacing: 6) {
            Menu("Presets") {
                Section("Built-in") {
                    ForEach(FxPresets.builtIn, id: \.name) { p in Button(p.name) { model.applyPreset(stripID, p.fx) } }
                }
                if !model.settings.userPresets.isEmpty {
                    Section("Mine") {
                        ForEach(model.settings.userPresets.keys.sorted(), id: \.self) { name in
                            Button(name) { if let p = model.settings.userPresets[name] { model.applyPreset(stripID, p) } }
                        }
                    }
                    Menu("Delete") {
                        ForEach(model.settings.userPresets.keys.sorted(), id: \.self) { name in
                            Button(name, role: .destructive) { model.deletePreset(name) }
                        }
                    }
                }
            }
            .frame(width: 100)
            TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder).controlSize(.small)
            Button("Save") { model.savePreset(presetName, from: stripID); presetName = "" }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                .controlSize(.small)
        }
    }
}

struct BusFxEditor: View {
    @EnvironmentObject var model: MixerModel
    let bus: Int

    private var fx: FxSetting { model.settings.buses[bus].fx }
    private func bind<T>(_ kp: WritableKeyPath<FxSetting, T>) -> Binding<T> {
        Binding(get: { fx[keyPath: kp] }, set: { v in model.updateBus(bus) { $0.fx[keyPath: kp] = v } })
    }

    var body: some View {
        let meters = model.busFx[bus]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BUS \(AppSettings.busNames[bus])").font(Theme.headingBold(15)).tracking(1.6).foregroundStyle(Theme.gold)
                Spacer()
                Picker("Mode", selection: bind(\.monoOut)) {
                    Text("Stereo").tag(false)
                    Text("Mono").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 150)
            }
            FxSection(title: "Parametric EQ", isOn: bind(\.peqOn)) { PeqEditor(bands: bind(\.peq)) }
            InsertsSection(target: .bus(bus))
            FxSection(title: "Limiter (after bus gain)", isOn: bind(\.limiterOn),
                      trailing: AnyView(Text(String(format: "GR %.1f dB", fx.limiterOn ? meters.limiterGainReductionDB : 0))
                                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.warn))) {
                ParamSlider(title: "Ceiling", value: bind(\.limiterCeilingDB), range: -24...0, unit: "dB")
                ParamSlider(title: "Release", value: bind(\.limiterReleaseMs), range: 10...1000, unit: "ms", format: "%.0f", log: true)
            }
        }
        .padding(10)
        .frame(width: 470)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }
}
