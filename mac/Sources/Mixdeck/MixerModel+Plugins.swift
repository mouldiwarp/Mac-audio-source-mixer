import AppKit
import CMixEngine
import Foundation

// Plug-in inserts and level balance (spec/features/plugins-and-balance.md).
extension MixerModel {
    enum InsertTarget: Hashable {
        case strip(Int)
        case bus(Int)
    }

    func insertSettings(_ t: InsertTarget) -> [InsertSetting] {
        switch t {
        case .strip(let i): return settings.strips.indices.contains(i) ? settings.strips[i].inserts : []
        case .bus(let b): return settings.buses[b].inserts
        }
    }

    private func setInsertSettings(_ t: InsertTarget, _ v: [InsertSetting]) {
        switch t {
        case .strip(let i): settings.strips[i].inserts = v
        case .bus(let b): settings.buses[b].inserts = v
        }
    }

    /// Puts the loaded instances of a target into its engine slots, in order.
    func placeInserts(_ t: InsertTarget) {
        guard let m = mixer else { return }
        let list = insertSettings(t)
        for k in 0..<Int(MIXER_INSERT_SLOTS) {
            let ins = k < list.count ? plugins[list[k].id]?.insert : nil
            switch t {
            case .strip(let i): MixerStripSetInsert(m, Int32(i), Int32(k), ins)
            case .bus(let b): MixerBusSetInsert(m, Int32(b), Int32(k), ins)
            }
        }
    }

    func loadAllInserts() {
        for i in settings.strips.indices { for s in settings.strips[i].inserts where plugins[s.id] == nil { load(s, into: .strip(i), openEditor: false) } }
        for b in 0..<6 { for s in settings.buses[b].inserts where plugins[s.id] == nil { load(s, into: .bus(b), openEditor: false) } }
    }

    private func target(of id: UUID) -> InsertTarget? {
        if let i = settings.strips.firstIndex(where: { $0.inserts.contains { $0.id == id } }) { return .strip(i) }
        if let b = settings.buses.firstIndex(where: { $0.inserts.contains { $0.id == id } }) { return .bus(b) }
        return nil
    }

    private func load(_ s: InsertSetting, into t: InsertTarget, openEditor: Bool) {
        insertStatus[s.id] = .loading
        Task { @MainActor in
            do {
                let p = try await PluginInstance.load(s)
                // The slot may have been removed while loading.
                guard let now = target(of: s.id) else { p.dispose(); return }
                plugins[s.id] = p
                insertStatus[s.id] = .ok
                placeInserts(now)
                if openEditor { showEditor(s.id) }
            } catch let e as PluginInstance.LoadError {
                if case .notInstalled = e { insertStatus[s.id] = .missing } else { insertStatus[s.id] = .failed(e.description) }
            } catch {
                insertStatus[s.id] = .failed("\(error)")
            }
        }
    }

    func addInsert(_ e: PluginCatalog.Entry, to t: InsertTarget) {
        var list = insertSettings(t)
        guard list.count < Int(MIXER_INSERT_SLOTS) else { return }
        let s = InsertSetting(type: e.type, subType: e.subType, manufacturer: e.manufacturer, name: e.name, vendor: e.vendor)
        list.append(s)
        setInsertSettings(t, list)
        load(s, into: t, openEditor: true)
        scheduleSave()
    }

    func removeInsert(_ id: UUID) {
        guard let t = target(of: id) else { return }
        setInsertSettings(t, insertSettings(t).filter { $0.id != id })
        placeInserts(t)                      // returns once the audio thread no longer uses it
        plugins.removeValue(forKey: id)?.dispose()
        insertStatus[id] = nil
        scheduleSave()
    }

    func moveInsert(_ id: UUID, by delta: Int) {
        guard let t = target(of: id) else { return }
        var list = insertSettings(t)
        guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + delta) else { return }
        list.swapAt(i, i + delta)
        // Clear the slots first so no instance is ever in two slots at once.
        if let m = mixer {
            for k in 0..<Int(MIXER_INSERT_SLOTS) {
                switch t {
                case .strip(let s): MixerStripSetInsert(m, Int32(s), Int32(k), nil)
                case .bus(let b): MixerBusSetInsert(m, Int32(b), Int32(k), nil)
                }
            }
        }
        setInsertSettings(t, list)
        placeInserts(t)
        scheduleSave()
    }

    func setInsertBypass(_ id: UUID, _ on: Bool) {
        guard let t = target(of: id) else { return }
        setInsertSettings(t, insertSettings(t).map { var s = $0; if s.id == id { s.bypass = on }; return s })
        if let p = plugins[id] { MixerInsertSetBypass(p.insert, on) }
        scheduleSave()
    }

    func showEditor(_ id: UUID) {
        guard let p = plugins[id], let t = target(of: id), let s = insertSettings(t).first(where: { $0.id == id }) else { return }
        let owner: String
        switch t {
        case .strip(let i): owner = settings.strips[i].name
        case .bus(let b): owner = AppSettings.busNames[b]
        }
        p.showEditor(title: "\(s.name) — \(owner)") { [weak self] in self?.saveNow() }
    }

    /// Copies every loaded plug-in's state into the settings (before saving).
    func captureInsertStates() {
        for i in settings.strips.indices {
            for k in settings.strips[i].inserts.indices {
                if let d = plugins[settings.strips[i].inserts[k].id]?.stateData { settings.strips[i].inserts[k].state = d }
            }
        }
        for b in 0..<6 {
            for k in settings.buses[b].inserts.indices {
                if let d = plugins[settings.buses[b].inserts[k].id]?.stateData { settings.buses[b].inserts[k].state = d }
            }
        }
    }

    /// "TR5 Brickwall Limiter: ok, 0 errors, bypass off" (diagnostics, control path Strip[i].Insert[k]).
    func insertDescription(_ s: InsertSetting) -> String {
        let st: String
        switch insertStatus[s.id] ?? .loading {
        case .loading: st = "loading"
        case .ok: st = "ok"
        case .missing: st = "missing"
        case .failed(let e): st = "failed (\(e))"
        }
        let errors = plugins[s.id].map { MixerInsertErrors($0.insert) } ?? 0
        let last = plugins[s.id].map { MixerInsertLastError($0.insert) } ?? 0
        let pulls = plugins[s.id].map { MixerInsertPulls($0.insert) } ?? 0
        return "\(s.name): \(st), \(errors) render errors (last \(last)), \(pulls) input pulls, bypass \(s.bypass ? "on" : "off")"
    }

    func pollInsertErrors() {
        for (id, p) in plugins {
            let e = MixerInsertErrors(p.insert)
            if insertErrors[id] != e { insertErrors[id] = e }
        }
    }

    // MARK: Level balance (§2)

    var balanceSelection: [Int] {
        settings.strips.indices.filter { settings.strips[$0].balanceSelected && settings.strips[$0].source != nil }
    }

    func setBalanceSelected(_ id: UUID, _ on: Bool) { update(id) { $0.balanceSelected = on } }

    /// Moves the fader by `delta` dB and records it as trim (held across re-balances).
    func nudgeTrim(_ id: UUID, _ delta: Float) {
        guard let i = index(id) else { return }
        let s = settings.strips[i]
        let newTrim = min(max(s.trimDB + delta, -24), 24)
        let applied = newTrim - s.trimDB
        update(id) { $0.trimDB = newTrim; $0.gainDB = min(max($0.gainDB + applied, -60), 12) }
    }

    func setTrim(_ id: UUID, _ value: Float) {
        guard let i = index(id) else { return }
        nudgeTrim(id, min(max(value, -24), 24) - settings.strips[i].trimDB)
    }

    func resetTrims() {
        for s in settings.strips where s.trimDB != 0 { update(s.id) { $0.trimDB = 0 } }
    }

    func runBalance() {
        guard let m = mixer, !balanceState.isMeasuring else { return }
        let sel = balanceSelection
        guard sel.count >= 2 else { balanceState = .done([]); return }
        let seconds = min(max(settings.balanceSeconds, 3), 30)
        var start: [Int: UInt64] = [:]
        var scratch = [Float](repeating: 0, count: Int(LOUD_RING_BLOCKS))
        for i in sel {
            var total: UInt64 = 0
            _ = MixerStripLoudnessBlocks(m, Int32(i), &scratch, 0, 0, &total)
            start[i] = total
        }
        let ids = sel.map { settings.strips[$0].id }
        balanceState = .measuring(0)
        Task { @MainActor in
            let steps = seconds * 10
            for k in 1...steps {
                try? await Task.sleep(nanoseconds: 100_000_000)
                balanceState = .measuring(Double(k) / Double(steps))
            }
            guard let m = self.mixer else { balanceState = .idle; return }
            var measured: [UUID: Double] = [:]
            for (i, id) in zip(sel, ids) where index(id) == i {
                var buf = [Float](repeating: 0, count: Int(LOUD_RING_BLOCKS))
                var total: UInt64 = 0
                let n = MixerStripLoudnessBlocks(m, Int32(i), &buf, UInt32(LOUD_RING_BLOCKS), start[i] ?? 0, &total)
                let l = LoudnessIntegrated(buf, n)
                if l.isFinite { measured[id] = l }
            }
            applyBalance(ids: ids, measured: measured)
        }
    }

    private func applyBalance(ids: [UUID], measured: [UUID: Double]) {
        // Target: mean post-fader loudness (pre-fader + current gain) of the strips with signal.
        let valid = ids.compactMap { id -> (UUID, Double)? in
            guard let l = measured[id], let i = index(id) else { return nil }
            return (id, l + Double(settings.strips[i].gainDB))
        }
        var results: [BalanceResult] = []
        balanceUndo = [:]
        let target = valid.isEmpty ? 0 : valid.map(\.1).reduce(0, +) / Double(valid.count)
        for id in ids {
            guard let i = index(id) else { continue }
            let s = settings.strips[i]
            guard valid.count >= 2, let l = measured[id] else {
                results.append(BalanceResult(name: s.name, measured: measured[id], newGain: nil))
                continue
            }
            let want = Float(target - l) + s.trimDB
            let g = min(max(want, -60), 12)
            balanceUndo[id] = s.gainDB
            update(id) { $0.gainDB = (g * 10).rounded() / 10 }
            results.append(BalanceResult(name: s.name, measured: l, newGain: g, clamped: g != want))
        }
        balanceState = .done(results)
    }

    func undoBalance() {
        for (id, g) in balanceUndo { update(id) { $0.gainDB = g } }
        balanceUndo = [:]
        balanceState = .idle
    }
}

extension MixerModel.BalanceState {
    var isMeasuring: Bool { if case .measuring = self { return true }; return false }
}
