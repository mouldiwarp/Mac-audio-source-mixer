import AppKit
import SwiftUI

/// Visual language from the GM Guitars site (gm-guitars.net), shared with Axeio Silicon:
/// - a dim stage-and-bar photograph as the backdrop
/// - obsidian and slate surfaces with gold hairlines
/// - steel and off-white text, and Helvetica headings
/// - lamp-like glowing buttons and LEDs
enum Theme {
    // Site palette
    static let obsidian = Color(hex: 0x121212)
    static let slate    = Color(hex: 0x1E1E1E)
    static let gold     = Color(hex: 0xC5A059)
    static let steel    = Color(hex: 0x8E8E8E)
    static let offwhite = Color(hex: 0xE0E0E0)
    /// Smoky blue from the haze in the photograph.
    static let haze     = Color(hex: 0x86A2BD)
    static let amber    = Color(hex: 0xFFB54A)

    // Roles used across the app
    static let panel = obsidian                      // popover / sheet background
    static let track = Color(hex: 0x0A0A0A)          // fader slots, meter backs, graphs
    static let control = Color(hex: 0x0B0B0B).opacity(0.85)   // unlit button face
    static let text = offwhite
    static let dim = steel
    static let accent = gold
    static let ok = Color(hex: 0x9BD86A)
    static let warn = Color(hex: 0xF2C14E)
    static let danger = Color(hex: 0xE5533D)
    static let hardwareBus = gold
    static let virtualBus = haze

    // Fonts
    static func heading(_ size: CGFloat) -> Font { .custom("HelveticaNeue-Medium", size: size) }
    static func headingBold(_ size: CGFloat) -> Font { .custom("HelveticaNeue-Bold", size: size) }
    /// Small uppercase captions on buttons and section labels.
    static func caption(_ size: CGFloat) -> Font { .custom("HelveticaNeue-CondensedBold", size: size) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Backdrop

/// The stage-and-bar photograph, dimmed and vignetted as on the site.
struct Backdrop: View {
    static let image: NSImage? = {
        let candidates = [
            Bundle.main.url(forResource: "atmosphere-bar", withExtension: "jpg"),
            // `swift run` during development: use the copy in the repository.
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Assets/atmosphere-bar.jpg").standardized,
        ]
        return candidates.compactMap { $0 }.lazy.compactMap { NSImage(contentsOf: $0) }.first
    }()

    var body: some View {
        GeometryReader { g in
            ZStack {
                Theme.obsidian
                if let img = Self.image {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height, alignment: Alignment(horizontal: .leading, vertical: .center))
                        .clipped()
                        .opacity(0.85)
                }
                RadialGradient(stops: [.init(color: .clear, location: 0.45),
                                       .init(color: Theme.obsidian.opacity(0.85), location: 1)],
                               center: .center, startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.72)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Surfaces

/// Translucent slate card with a gold hairline, like the site's content panels.
struct GMCard: ViewModifier {
    var radius: CGFloat = 8
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(hex: 0x141414).opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: [.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center)))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.gold.opacity(0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 10, y: 3)
        )
    }
}

/// Recessed well behind readouts and fields.
struct GMWell: ViewModifier {
    var radius: CGFloat = 4
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Theme.track.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
        )
    }
}

extension View {
    func gmCard(radius: CGFloat = 8) -> some View { modifier(GMCard(radius: radius)) }
    func gmWell(radius: CGFloat = 4) -> some View { modifier(GMWell(radius: radius)) }
}

/// Amber LED-style numeric readout in a recessed well (fader levels, trims).
struct LedReadout: View {
    let text: String
    var color: Color = Theme.amber
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.7), radius: 3)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .gmWell()
    }
}

/// Small round LED with a glow when lit.
struct LedDot: View {
    let on: Bool
    var color: Color = Theme.ok
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(on ? color : color.opacity(0.15))
            .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(on ? 0.45 : 0.05), .clear],
                                                  startPoint: .top, endPoint: .center)))
            .shadow(color: on ? color.opacity(0.9) : .clear, radius: 4)
            .frame(width: size, height: size)
    }
}

/// Gives the hosting window the backdrop's base colour, so any space around the content
/// (for example after a restored window size) blends into the vignette.
struct WindowTint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.backgroundColor = NSColor(srgbRed: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 1) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
