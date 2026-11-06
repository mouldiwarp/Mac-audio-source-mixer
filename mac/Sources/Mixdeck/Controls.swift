import SwiftUI

enum Theme {
    static let panel = Color(white: 0.13)
    static let strip = Color(white: 0.17)
    static let track = Color(white: 0.08)
    static let text = Color(white: 0.85)
    static let dim = Color(white: 0.55)
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.64)
    static let warn = Color(red: 0.95, green: 0.72, blue: 0.25)
    static let danger = Color(red: 0.93, green: 0.36, blue: 0.33)
    static let virtualBus = Color(red: 0.45, green: 0.62, blue: 0.98)
    static let hardwareBus = Color(red: 0.86, green: 0.58, blue: 0.95)
}

/// Fader position (0...1) <-> dB. Top 70 % of travel covers -20...+12 dB.
enum FaderLaw {
    static func position(_ dB: Float) -> Double {
        if dB <= -60 { return 0 }
        if dB >= -20 { return 0.3 + 0.7 * Double((dB + 20) / 32) }
        return 0.3 * Double((dB + 60) / 40)
    }
    static func dB(_ p: Double) -> Float {
        let p = min(max(p, 0), 1)
        if p >= 0.3 { return Float(-20 + (p - 0.3) / 0.7 * 32) }
        return Float(-60 + p / 0.3 * 40)
    }
    static func label(_ dB: Float) -> String { dB <= -60 ? "-∞" : String(format: "%+.1f", dB) }
}

/// Vertical fader. Drag to move, double-click to reset to 0 dB.
struct Fader: View {
    @Binding var dB: Float
    var tint: Color = Theme.accent
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, thumbH: CGFloat = 22
            let travel = h - thumbH
            let p = FaderLaw.position(dB)
            ZStack(alignment: .top) {
                Canvas { ctx, size in
                    let x = size.width / 2
                    ctx.fill(Path(roundedRect: CGRect(x: x - 2, y: thumbH / 2, width: 4, height: travel), cornerRadius: 2), with: .color(Theme.track))
                    for mark: Float in [12, 6, 0, -6, -12, -20, -40] {
                        let y = thumbH / 2 + travel * (1 - FaderLaw.position(mark))
                        ctx.fill(Path(CGRect(x: x + 7, y: y, width: mark == 0 ? 9 : 5, height: 1)), with: .color(Theme.dim.opacity(0.6)))
                    }
                }
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(tint).frame(height: 2))
                    .frame(width: 30, height: thumbH)
                    .offset(y: travel * (1 - p))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = p }
                    let np = (dragStart ?? p) - Double(g.translation.height / max(travel, 1))
                    dB = (FaderLaw.dB(np) * 10).rounded() / 10
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { dB = 0 }
        }
        .frame(width: 36)
        .accessibilityElement()
        .accessibilityLabel("Gain")
        .accessibilityValue(FaderLaw.label(dB) + " dB")
        .accessibilityAdjustableAction { dir in dB = min(12, max(-60, dB + (dir == .increment ? 1 : -1))) }
    }
}

/// Stereo peak meter, -60...0 dBFS.
struct MeterView: View {
    var l: Float
    var r: Float

    var body: some View {
        Canvas { ctx, size in
            let w = (size.width - 2) / 2
            for (i, v) in [l, r].enumerated() {
                let x = CGFloat(i) * (w + 2)
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Theme.track))
                let db = v > 0 ? 20 * log10(Double(v)) : -100
                let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
                let hgt = size.height * frac
                let grad = Gradient(stops: [
                    .init(color: Theme.accent, location: 0),
                    .init(color: Theme.accent, location: 0.7),
                    .init(color: Theme.warn, location: 0.85),
                    .init(color: Theme.danger, location: 1),
                ])
                ctx.fill(Path(CGRect(x: x, y: size.height - hgt, width: w, height: hgt)),
                         with: .linearGradient(grad, startPoint: CGPoint(x: 0, y: size.height), endPoint: .zero))
            }
        }
        .frame(width: 12)
        .accessibilityHidden(true)
    }
}

/// Small latching button (mute, solo, mono, bus assign).
struct LatchButton: View {
    let title: String
    let on: Bool
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 20)
                .foregroundStyle(on ? Color.black : Theme.text)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? tint : Color(white: 0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
