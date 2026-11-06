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
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentSize)   // window follows the strips

        MenuBarExtra("Mixdeck", systemImage: "slider.vertical.3") {
            MenuBarContent().environmentObject(model)
        }

        Settings {
            ControlSettingsView().environmentObject(model)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: MixerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Mixer") {
            openWindow(id: "mixer")
            NSApp.activate(ignoringOtherApps: true)
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
                ForEach(model.settings.scenes.keys.sorted(), id: \.self) { n in Button(n) { try? model.loadScene(n) } }
            }
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Mixdeck") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MixerModel?

    // Keep mixing when the window is closed; quit from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}
