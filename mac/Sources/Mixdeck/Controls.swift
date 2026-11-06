import AppKit
import SwiftUI

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

/// Vertical fader with a brushed-metal cap. Drag to move, double-click to reset to 0 dB.
struct Fader: View {
    @Binding var dB: Float
    var tint: Color = Theme.accent
    @State private var dragStart: Double?
    @State private var clicks = DoubleClick()

    private static let capH: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, thumbH = Self.capH
            let travel = h - thumbH
            let p = FaderLaw.position(dB)
            ZStack(alignment: .top) {
                Canvas { ctx, size in
                    let x = size.width / 2
                    // Scale ticks on both sides; 0 dB in gold.
                    for mark: Float in [12, 6, 0, -6, -12, -20, -40, -60] {
                        let y = thumbH / 2 + travel * (1 - FaderLaw.position(mark))
                        let zero = mark == 0
                        let len: CGFloat = zero ? 8 : 5
                        let c = zero ? Theme.gold : Theme.dim.opacity(0.55)
                        ctx.fill(Path(CGRect(x: x - 6 - len, y: y - 0.5, width: len, height: 1)), with: .color(c))
                        ctx.fill(Path(CGRect(x: x + 6, y: y - 0.5, width: len, height: 1)), with: .color(c))
                    }
                    // Recessed slot
                    let slot = CGRect(x: x - 2.5, y: thumbH / 2 - 4, width: 5, height: travel + 8)
                    ctx.fill(Path(roundedRect: slot, cornerRadius: 2.5), with: .color(Theme.track))
                    ctx.stroke(Path(roundedRect: slot, cornerRadius: 2.5), with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                }
                FaderCap(tint: tint)
                    .frame(width: 28, height: thumbH)
                    .offset(y: travel * (1 - p))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = p }
                    guard g.translation.height != 0 else { return }   // a click alone doesn't move it
                    let np = (dragStart ?? p) - Double(g.translation.height / max(travel, 1))
                    dB = (FaderLaw.dB(np) * 10).rounded() / 10
                }
                .onEnded { g in
                    dragStart = nil
                    if clicks.isDoubleClick(g) { dB = 0 }
                })
        }
        .frame(width: 36)
        .help("Gain (double-click for 0 dB)")
        .accessibilityElement()
        .accessibilityLabel("Gain")
        .accessibilityValue(FaderLaw.label(dB) + " dB")
        .accessibilityAdjustableAction { dir in dB = min(12, max(-60, dB + (dir == .increment ? 1 : -1))) }
    }
}

/// Recognises a double-click from the ends of a zero-distance drag gesture, which would
/// otherwise swallow the clicks before a tap gesture sees them.
struct DoubleClick {
    private var lastClick: Date?

    /// Call from the drag's `onEnded`. True on the second click of a double-click.
    mutating func isDoubleClick(_ g: DragGesture.Value) -> Bool {
        let moved = abs(g.translation.width) > 3 || abs(g.translation.height) > 3
        guard !moved else { lastClick = nil; return false }
        let now = Date()
        if let last = lastClick, now.timeIntervalSince(last) <= NSEvent.doubleClickInterval {
            lastClick = nil
            return true
        }
        lastClick = now
        return false
    }
}

/// Brushed-metal fader cap with grip ridges and a glowing index line.
private struct FaderCap: View {
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5)
            .fill(LinearGradient(stops: [
                .init(color: Color(white: 0.64), location: 0), .init(color: Color(white: 0.32), location: 0.2),
                .init(color: Color(white: 0.19), location: 0.5), .init(color: Color(white: 0.29), location: 0.8),
                .init(color: Color(white: 0.13), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .overlay(
                Canvas { ctx, size in
                    for k: CGFloat in [-10, -6, 6, 10] {
                        ctx.fill(Path(CGRect(x: 4, y: size.height / 2 + k - 0.5, width: size.width - 8, height: 1)),
                                 with: .color(.black.opacity(0.35)))
                    }
                }
            )
            .overlay(Rectangle().fill(tint).frame(height: 2).padding(.horizontal, 2).shadow(color: tint.opacity(0.9), radius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.85), radius: 5, y: 4)
    }
}

/// Stereo peak meter, -60...0 dBFS, drawn as glowing LED segments.
struct MeterView: View {
    var l: Float
    var r: Float

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 1.2, segH: CGFloat = 2.8
            let n = max(1, Int((size.height + gap) / (segH + gap)))
            let w = (size.width - 2) / 2
            var lit: [(CGRect, Color)] = []
            for (i, v) in [l, r].enumerated() {
                let x = CGFloat(i) * (w + 2)
                let db = v > 0 ? 20 * log10(Double(v)) : -100
                let frac = max(0, min(1, (db + 60) / 60))
                for k in 0..<n {
                    let pos = (Double(k) + 0.5) / Double(n)
                    let color = pos < 0.7 ? Theme.ok : pos < 0.88 ? Theme.warn : Theme.danger
                    let rect = CGRect(x: x, y: size.height - CGFloat(k + 1) * (segH + gap) + gap, width: w, height: segH)
                    ctx.fill(Path(rect), with: .color(Theme.track))
                    if pos <= frac {
                        lit.append((rect, color))
                    } else {
                        ctx.fill(Path(rect), with: .color(color.opacity(0.10)))
                    }
                }
            }
            guard !lit.isEmpty else { return }
            // Soft glow under the lit segments, then the segments themselves.
            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: 2.5))
                for (r, c) in lit { glow.fill(Path(r.insetBy(dx: -0.5, dy: -0.5)), with: .color(c.opacity(0.8))) }
            }
            for (r, c) in lit { ctx.fill(Path(r), with: .color(c)) }
        }
        .frame(width: 12)
        .accessibilityHidden(true)
    }
}

/// Small latching button (mute, solo, mono, bus assign). Lights up like a lamp when on.
struct LatchButton: View {
    let title: String
    let on: Bool
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption(10.5))
                .tracking(0.8)
                .frame(maxWidth: .infinity, minHeight: 20)
                .foregroundStyle(on ? Theme.obsidian : Theme.text.opacity(0.8))
                .background(LampFace(on: on, tint: tint))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Button face shared by latch and icon buttons: a dark recessed face with a tinted rim,
/// or a lit, glowing face when on.
struct LampFace: View {
    let on: Bool
    var tint: Color = Theme.accent
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(on ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [.white.opacity(on ? 0.35 : 0.04), .clear], startPoint: .top, endPoint: .center)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(on ? 0.9 : 0.28), lineWidth: 0.75))
            .shadow(color: on ? tint.opacity(0.6) : .clear, radius: 5)
    }
}

/// Horizontal pan control: recessed track, gold arc from centre, metal knob.
/// Drag to move, double-click to centre.
struct PanControl: View {
    @Binding var pan: Float
    @State private var dragStart: Float?
    @State private var clicks = DoubleClick()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, knob: CGFloat = 12
            let usable = w - knob
            let x = knob / 2 + usable * CGFloat((pan + 1) / 2)
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let mid = size.height / 2
                    let track = CGRect(x: knob / 2, y: mid - 2, width: usable, height: 4)
                    ctx.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(Theme.track))
                    let cx = size.width / 2
                    ctx.fill(Path(CGRect(x: cx - 0.5, y: mid - 5, width: 1, height: 10)), with: .color(Theme.dim.opacity(0.6)))
                    let a = min(cx, x), b = max(cx, x)
                    ctx.fill(Path(roundedRect: CGRect(x: a, y: mid - 1.5, width: b - a, height: 3), cornerRadius: 1.5),
                             with: .color(Theme.gold))
                }
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.45), Color(white: 0.2)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: knob * 0.75))
                    .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: x - knob / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = pan }
                    guard g.translation.width != 0 else { return }
                    let v = (dragStart ?? pan) + Float(g.translation.width / max(usable, 1)) * 2
                    pan = (min(1, max(-1, v)) * 100).rounded() / 100
                }
                .onEnded { g in
                    dragStart = nil
                    if clicks.isDoubleClick(g) { pan = 0 }
                })
        }
        .frame(height: 16)
        .help("Pan (double-click to centre)")
        .accessibilityElement()
        .accessibilityLabel("Pan")
        .accessibilityValue(pan == 0 ? "centre" : String(format: "%@ %.0f%%", pan < 0 ? "left" : "right", abs(pan) * 100))
        .accessibilityAdjustableAction { dir in pan = min(1, max(-1, pan + (dir == .increment ? 0.1 : -0.1))) }
    }
}
