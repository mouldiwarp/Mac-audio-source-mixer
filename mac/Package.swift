// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mixdeck",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "mixdeck-cli", targets: ["mixdeck-cli"]),
        .executable(name: "Mixdeck", targets: ["Mixdeck"]),
    ],
    targets: [
        // Real-time audio path (C: no Swift runtime on the audio threads).
        .target(name: "CMixEngine",
                linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"), .linkedFramework("Accelerate")]),
        // Core Audio device discovery (non-real-time).
        .target(name: "AudioIO",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(name: "mixdeck-cli", dependencies: ["CMixEngine", "AudioIO"]),
        // The mixer app (SwiftUI). Bundled into Mixdeck.app by scripts/build-app.sh.
        .executableTarget(name: "Mixdeck", dependencies: ["CMixEngine", "AudioIO"],
                          linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("AVFoundation")]),
        // Offline tests for the C engine (no audio hardware needed).
        .executableTarget(name: "cmix-tests", dependencies: ["CMixEngine"]),
    ]
)
