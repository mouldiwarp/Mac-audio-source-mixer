import SwiftUI

/// Insert slots for a strip or bus (spec/features/plugins-and-balance.md §1).
struct InsertsSection: View {
    @EnvironmentObject var model: MixerModel
    let target: MixerModel.InsertTarget
    @State private var catalog: [(vendor: String, entries: [PluginCatalog.Entry])] = []

    var body: some View {
        let list = model.insertSettings(target)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Plug-ins").font(.callout.weight(.semibold))
                Spacer()
                Menu("Add plug-in") {
                    if catalog.isEmpty { Text("No Audio Unit effects found") }
                    ForEach(catalog, id: \.vendor) { group in
                        Menu(group.vendor) {
                            ForEach(group.entries, id: \.self) { e in Button(e.name) { model.addInsert(e, to: target) } }
                        }
                    }
                }
                .fixedSize()
                .disabled(list.count >= 4)
            }
            if list.isEmpty {
                Text("Audio Unit effects (AmpliTube, T-RackS, …) run after the built-in blocks, before the fader.")
                    .font(.caption2).foregroundStyle(Theme.dim)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { k, s in row(k, s, count: list.count) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.strip))
        .onAppear { if catalog.isEmpty { catalog = PluginCatalog.byVendor() } }
    }

    private func row(_ k: Int, _ s: InsertSetting, count: Int) -> some View {
        let status = model.insertStatus[s.id] ?? .loading
        let errors = model.insertErrors[s.id] ?? 0
        return HStack(spacing: 6) {
            Text("\(k + 1)").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim).frame(width: 12)
            Toggle("", isOn: Binding(get: { !s.bypass }, set: { model.setInsertBypass(s.id, !$0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(s.bypass ? "Bypassed" : "Active")
                .accessibilityLabel("\(s.name) active")
            VStack(alignment: .leading, spacing: 0) {
                Text(s.name).font(.caption.weight(.semibold)).lineLimit(1)
                Group {
                    switch status {
                    case .loading: Text("loading…")
                    case .ok:
                        let lat = model.plugins[s.id]?.latencyMs ?? 0
                        Text(s.vendor + (lat > 0.05 ? String(format: " · %.1f ms latency", lat) : "")
                             + (errors > 0 ? " · \(errors) render errors" : ""))
                    case .missing: Text("missing — passing audio through").foregroundStyle(Theme.warn)
                    case .failed(let e): Text(e).foregroundStyle(Theme.danger)
                    }
                }
                .font(.caption2).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            Button("Edit") { model.showEditor(s.id) }.controlSize(.small).disabled(status != .ok)
            Button { model.moveInsert(s.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).disabled(k == 0).accessibilityLabel("Move up")
            Button { model.moveInsert(s.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).disabled(k == count - 1).accessibilityLabel("Move down")
            Button { model.removeInsert(s.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Theme.dim).accessibilityLabel("Remove \(s.name)")
        }
        .opacity(s.bypass ? 0.6 : 1)
    }
}

/// Footer control: measure the selected strips once and match their loudness
/// (spec/features/plugins-and-balance.md §2).
struct BalanceButton: View {
    @EnvironmentObject var model: MixerModel
    @State private var show = false

    var body: some View {
        let n = model.balanceSelection.count
        Button { show.toggle() } label: { Text("⚖ Balance\(n > 0 ? " (\(n))" : "")") }
            .buttonStyle(.borderless)
            .help("Match the loudness of the strips marked ⚖")
            .popover(isPresented: $show) { BalancePanel().environmentObject(model) }
    }
}

struct BalancePanel: View {
    @EnvironmentObject var model: MixerModel

    var body: some View {
        let sel = model.balanceSelection
        VStack(alignment: .leading, spacing: 10) {
            Text("Level balance").font(.headline)
            Text("Mark two or more strips with ⚖, then measure while they play or you speak normally. Faders are set so the strips are equally loud; your ±1 dB trims are kept on top.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Stepper("Measure for \(model.settings.balanceSeconds) s", value: Binding(get: { model.settings.balanceSeconds },
                                                                                set: { model.settings.balanceSeconds = $0; model.scheduleSave() }), in: 3...30)
            switch model.balanceState {
            case .measuring(let p):
                ProgressView(value: p) { Text("Measuring…") }
            case .done(let results):
                if results.isEmpty { Text("Select at least two strips with a source.").foregroundStyle(.orange) }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(results, id: \.name) { r in
                        GridRow {
                            Text(r.name)
                            Text(r.measured.map { String(format: "%.1f LUFS", $0) } ?? "no signal")
                                .foregroundStyle(r.measured == nil ? .orange : .secondary)
                            Text(r.newGain.map { String(format: "fader %+.1f dB", $0) } ?? "unchanged")
                            if r.clamped { Text("at limit").foregroundStyle(.orange) }
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
            case .idle: EmptyView()
            }
            HStack {
                Button("Measure & balance") { model.runBalance() }
                    .disabled(sel.count < 2 || model.balanceState.isMeasuring)
                    .keyboardShortcut(.defaultAction)
                Button("Undo") { model.undoBalance() }.disabled(model.balanceUndo.isEmpty || model.balanceState.isMeasuring)
                Spacer()
                Button("Reset trims") { model.resetTrims() }
            }
        }
        .padding(14)
        .frame(width: 400)
    }
}

/// −1 / trim / +1 under the fader of a strip marked for balance.
struct TrimRow: View {
    @EnvironmentObject var model: MixerModel
    let strip: StripSetting

    var body: some View {
        HStack(spacing: 3) {
            step("−", -1)
            Text(String(format: "%+.0f dB", strip.trimDB))
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 40)
                .foregroundStyle(strip.trimDB == 0 ? Theme.dim : Theme.warn)
                .help("Trim held on top of the balanced level")
            step("+", 1)
        }
    }

    private func step(_ t: String, _ d: Float) -> some View {
        Button(t) { model.nudgeTrim(strip.id, d) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 22, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.25)))
            .accessibilityLabel(d > 0 ? "Trim up 1 dB" : "Trim down 1 dB")
    }
}
