import AppKit
import SwiftUI

@main
struct MixdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = MixerModel()

    var body: some Scene {
        Window("Mixdeck", id: "mixer") {
            MixerView()
                .environmentObject(model)
                .background(MainWindowHook(delegate: delegate))
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentSize)   // window follows the strips

        MenuBarExtra("Mixdeck", systemImage: "slider.vertical.3") {
            MenuBarContent(delegate: delegate).environmentObject(model)
        }

        Settings {
            ControlSettingsView().environmentObject(model)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: MixerModel
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var body: some View {
        Button("Show Mixer") {
            delegate.showMixer(open: { openWindow(id: "mixer") })
        }
        Button(model.allVirtualMuted ? "Unmute Virtual Mics (B1–B3)" : "Mute Virtual Mics (B1–B3)") {
            model.toggleVirtualMute()
        }
        Divider()
        switch model.recorderState {
        case .recording, .paused: Button("Stop Recording") { model.stopRecording() }
        case .armed: Button("Start Recording") { model.recordOrResume() }
        default: Button("Start Recording (arm in mixer)") {}.disabled(true)
        }
        if !model.settings.scenes.isEmpty {
            Menu("Load Scene") {
                ForEach(model.settings.scenes.keys.sorted(), id: \.self) { n in Button(n) { model.attempt("Scene “\(n)”", key: "scene") { try model.loadScene(n) } } }
            }
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Mixdeck") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Hands the mixer's NSWindow to the app delegate so it can hide to the menu bar.
struct MainWindowHook: NSViewRepresentable {
    let delegate: AppDelegate
    func makeNSView(context: Context) -> NSView {
        let v = HookView()
        v.onWindow = { [weak delegate] w in delegate?.adopt(w) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
    private final class HookView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { if let w = window { onWindow?(w) } }
    }
}

/// Runs as a menu-bar utility: the Dock icon shows only while the mixer window is open.
/// Closing or minimising the window hides it to the menu bar; audio keeps running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MixerModel?
    private weak var mainWindow: NSWindow?
    private var openMixer: (() -> Void)?
    private var startHidden = false

    private static func isLoginLaunch() -> Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent, ev.eventID == kAEOpenApplication else { return false }
        return ev.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        startHidden = Self.isLoginLaunch() || CommandLine.arguments.contains("--hidden")
        if startHidden { NSApp.setActivationPolicy(.accessory) }
    }

    func adopt(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        // The yellow button hides to the menu bar instead of minimising to the Dock.
        if let mini = window.standardWindowButton(.miniaturizeButton) {
            mini.target = self
            mini.action = #selector(hideToTray)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            _ = self
        }
        if startHidden {
            startHidden = false
            DispatchQueue.main.async { [weak self] in self?.hideToTray() }
        }
    }

    @objc func hideToTray() {
        mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    /// Brings the mixer back, with its Dock icon. `open` recreates the window if it was closed.
    func showMixer(open: (() -> Void)? = nil) {
        if let open { openMixer = open }
        NSApp.setActivationPolicy(.regular)
        if let w = mainWindow, !w.isVisible { w.makeKeyAndOrderFront(nil) } else if mainWindow == nil { (open ?? openMixer)?() }
        DispatchQueue.main.async {
            if let w = self.mainWindow, !w.isVisible { (open ?? self.openMixer)?() }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMixer()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Development aid: write the mixer window to <dir>/mixer.png and quit.
        guard MixerModel.isPreview, let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
              i + 1 < CommandLine.arguments.count else { return }
        let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let view = NSApp.windows.first(where: { $0.title == "Mixdeck" })?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("mixer.png"))
            }
            exit(0)
        }
    }

    // Keep mixing when the window is closed; quit from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}
