import AppKit
import AudioToolbox
import AVFoundation
import CMixEngine
import CoreAudioKit
import SwiftUI

/// Installed Audio Unit effects (spec/features/plugins-and-balance.md §1).
enum PluginCatalog {
    struct Entry: Hashable {
        let name: String
        let vendor: String
        let type: UInt32, subType: UInt32, manufacturer: UInt32
    }

    static func effects() -> [Entry] {
        var out: [Entry] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                                 componentFlags: 0, componentFlagsMask: 0)
            for c in AVAudioUnitComponentManager.shared().components(matching: desc) {
                let d = c.audioComponentDescription
                out.append(Entry(name: c.name, vendor: c.manufacturerName, type: d.componentType,
                                 subType: d.componentSubType, manufacturer: d.componentManufacturer))
            }
        }
        return out.sorted { ($0.vendor, $0.name) < ($1.vendor, $1.name) }
    }

    static func byVendor() -> [(vendor: String, entries: [Entry])] {
        Dictionary(grouping: effects(), by: \.vendor)
            .map { ($0.key, $0.value) }
            .sorted { $0.vendor.localizedCaseInsensitiveCompare($1.vendor) == .orderedAscending }
    }
}

/// A loaded plug-in and the engine slot object that renders it.
@MainActor
final class PluginInstance {
    enum LoadError: Error, CustomStringConvertible {
        case notInstalled, notStereo, failed(String)
        var description: String {
            switch self {
            case .notInstalled: return "not installed"
            case .notStereo: return "does not support stereo 48 kHz"
            case .failed(let s): return s
            }
        }
    }

    let au: AUAudioUnit
    let insert: OpaquePointer
    var window: NSWindow?
    private var windowDelegate: WindowDelegate?

    private init(au: AUAudioUnit, insert: OpaquePointer) { self.au = au; self.insert = insert }

    var latencyMs: Double { au.latency * 1000 }

    static func load(_ s: InsertSetting) async throws -> PluginInstance {
        let desc = AudioComponentDescription(componentType: s.type, componentSubType: s.subType, componentManufacturer: s.manufacturer,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, [desc]) != nil else { throw LoadError.notInstalled }
        let au: AUAudioUnit
        do { au = try await AUAudioUnit.instantiate(with: desc, options: []) } catch { throw LoadError.failed("could not load: \(error.localizedDescription)") }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
              au.inputBusses.count > 0, au.outputBusses.count > 0 else { throw LoadError.notStereo }
        do {
            try au.inputBusses[0].setFormat(fmt)
            try au.outputBusses[0].setFormat(fmt)
        } catch { throw LoadError.notStereo }
        au.maximumFramesToRender = 4096
        // Busses of a freshly instantiated unit start disabled; a disabled input is never pulled.
        au.inputBusses[0].isEnabled = true
        au.outputBusses[0].isEnabled = true
        let render = au.renderBlock
        do { try au.allocateRenderResources() } catch { throw LoadError.failed("could not start: \(error.localizedDescription)") }
        if let data = s.state,
           let st = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            au.fullState = st
        }
        // AURenderBlock and MixerAURender are both blocks with the same signature.
        guard let ins = MixerInsertCreate(unsafeBitCast(render, to: MixerAURender.self)) else { throw LoadError.failed("out of memory") }
        let p = PluginInstance(au: au, insert: ins)
        MixerInsertSetBypass(ins, s.bypass)
        return p
    }

    /// Current state as a binary property list.
    var stateData: Data? {
        guard let st = au.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: st, format: .binary, options: 0)
    }

    /// Call after the instance was removed from its engine slot.
    func dispose() {
        window?.close()
        window = nil
        au.deallocateRenderResources()
        MixerInsertDestroy(insert)
    }

    func showEditor(title: String, onClose: @escaping () -> Void) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        au.requestViewController { [weak self] vc in
            Task { @MainActor in
                guard let self else { return }
                let controller: NSViewController
                if let vc {
                    controller = vc
                    if vc.preferredContentSize == .zero, vc.view.frame.size == .zero { vc.preferredContentSize = NSSize(width: 600, height: 400) }
                } else {
                    controller = NSHostingController(rootView: GenericPluginView(au: self.au))
                }
                let w = NSWindow(contentViewController: controller)
                w.title = title
                w.styleMask.insert(.closable)
                w.isReleasedWhenClosed = false
                let d = WindowDelegate { [weak self] in self?.window = nil; onClose() }
                w.delegate = d
                self.windowDelegate = d
                self.window = w
                w.center()
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}

/// Parameter sliders for plug-ins without their own window.
struct GenericPluginView: View {
    let au: AUAudioUnit
    @State private var tick = 0

    var body: some View {
        let params = au.parameterTree?.allParameters ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if params.isEmpty { Text("This plug-in has no editable parameters.").foregroundStyle(.secondary) }
                ForEach(params, id: \.address) { p in
                    HStack {
                        Text(p.displayName).frame(width: 160, alignment: .leading)
                        Slider(value: Binding(get: { Double(p.value) }, set: { p.value = AUValue($0); tick += 1 }),
                               in: Double(p.minValue)...Double(max(p.maxValue, p.minValue + 0.0001)))
                        Text(p.string(fromValue: nil)).font(.caption.monospacedDigit()).frame(width: 80, alignment: .trailing)
                    }
                }
            }
            .padding()
            .id(tick)
        }
        .frame(minWidth: 460, minHeight: 200)
    }
}
