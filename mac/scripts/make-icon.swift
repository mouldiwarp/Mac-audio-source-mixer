// Draws the Mixdeck app icon (no third-party artwork) and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))!.draw(in: path, angle: -90)
    NSColor(white: 1, alpha: 0.10).setStroke()
    path.lineWidth = max(1, s * 0.006); path.stroke()

    // Three channel strips: level meter (green > amber > red) beside a fader slot with a gold cap.
    let levels: [CGFloat] = [0.70, 0.48, 0.60]
    let faders: [CGFloat] = [0.62, 0.40, 0.52]
    let gold = NSColor(srgbRed: 0.773, green: 0.627, blue: 0.349, alpha: 1)
    let segs = 9
    for i in 0..<3 {
        let cx = s * (0.28 + 0.22 * CGFloat(i))
        // meter
        let mw = s * 0.035, segH = s * 0.048, gap = s * 0.012
        let mx = cx - s * 0.075
        for k in 0..<segs {
            let y = s * 0.22 + CGFloat(k) * (segH + gap)
            let lit = CGFloat(k) / CGFloat(segs) < levels[i]
            let f = CGFloat(k) / CGFloat(segs - 1)
            let col = f > 0.8 ? NSColor(srgbRed: 0.90, green: 0.33, blue: 0.24, alpha: 1)
                    : f > 0.6 ? NSColor(srgbRed: 1.0, green: 0.71, blue: 0.29, alpha: 1)
                    : NSColor(srgbRed: 0.61, green: 0.85, blue: 0.42, alpha: 1)
            (lit ? col : NSColor(white: 1, alpha: 0.07)).setFill()
            NSBezierPath(roundedRect: NSRect(x: mx, y: y, width: mw, height: segH), xRadius: mw * 0.25, yRadius: mw * 0.25).fill()
        }
        // fader slot + cap
        let fx = cx + s * 0.035
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: fx - s * 0.013, y: s * 0.22, width: s * 0.026, height: s * 0.56),
                     xRadius: s * 0.013, yRadius: s * 0.013).fill()
        let cap = NSRect(x: fx - s * 0.05, y: s * faders[i] - s * 0.04, width: s * 0.10, height: s * 0.08)
        gold.setFill()
        NSBezierPath(roundedRect: cap, xRadius: s * 0.015, yRadius: s * 0.015).fill()
        NSColor(white: 0, alpha: 0.45).setFill()
        NSRect(x: cap.minX + s * 0.008, y: cap.midY - s * 0.004, width: cap.width - s * 0.016, height: s * 0.008).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
