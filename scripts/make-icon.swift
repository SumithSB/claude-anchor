// Draws the app icon (white anchor on a clay squircle, matching the in-app logo) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root; needs iconutil)
import AppKit

let clayTop = NSColor(red: 0xE3 / 255.0, green: 0x8C / 255.0, blue: 0x6D / 255.0, alpha: 1)
let clayBottom = NSColor(red: 0xC8 / 255.0, green: 0x5F / 255.0, blue: 0x40 / 255.0, alpha: 1)

/// Same geometry as `AnchorGlyph` in Sources/Anchor/AnchorApp.swift (y flipped for AppKit).
func anchorPath(in r: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    let w = r.width, h = r.height, x = r.midX
    func pt(_ px: CGFloat, _ fromTop: CGFloat) -> NSPoint { NSPoint(x: px, y: r.maxY - fromTop) }
    p.appendOval(in: NSRect(x: x - w * 0.14, y: r.maxY - w * 0.28, width: w * 0.28, height: w * 0.28))   // eye
    p.move(to: pt(x, w * 0.28)); p.line(to: pt(x, h))                                                     // shank
    p.move(to: pt(x - w * 0.3, h * 0.36)); p.line(to: pt(x + w * 0.3, h * 0.36))                           // stock
    p.move(to: pt(r.minX, h * 0.62))                                                                       // arms
    p.curve(to: pt(r.maxX, h * 0.62), controlPoint1: pt(r.minX + w / 3, h * 1.1533), controlPoint2: pt(r.maxX - w / 3, h * 1.1533))   // the quad curve (control at 1.42h) as a cubic
    for (dx, sgn) in [(r.minX, CGFloat(1)), (r.maxX, CGFloat(-1))] {                                       // flukes
        p.move(to: pt(dx, h * 0.62)); p.line(to: pt(dx + sgn * w * 0.16, h * 0.56))
    }
    return p
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824 pt squircle centred on a 1024 canvas, soft drop shadow.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.28); sh.shadowBlurRadius = 24 * s; sh.shadowOffset = NSSize(width: 0, height: -10 * s)
    sh.set()
    clayBottom.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: clayTop, ending: clayBottom)!.draw(in: shape, angle: -90)
    // Anchor: 22:26 like the in-app glyph, centred slightly high to balance the curved arms.
    let gw: CGFloat = 400 * s, gh: CGFloat = gw * 26 / 22
    let glyph = anchorPath(in: NSRect(x: 512 * s - gw / 2, y: 512 * s - gh / 2 + 18 * s, width: gw, height: gh))
    glyph.lineWidth = 46 * s; glyph.lineCapStyle = .round; glyph.lineJoinStyle = .round
    NSColor.white.setStroke(); glyph.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let out = "Resources/AppIcon.icns"
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set.path, "-o", out]
try! p.run(); p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")
print("wrote \(out)")
