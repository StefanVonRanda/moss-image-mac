// Renders the app icon at every macOS size into AppIcon.iconset. Usage: make_icon <icon dir>
// The artwork is <icon dir>/art.png (square, rendered with MOSS-Image itself), masked to Apple's icon grid:
// an 824 px continuous-corner tile on a 1024 canvas with the standard soft drop shadow.
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let set = dir.appendingPathComponent("AppIcon.iconset")
guard let art = NSImage(contentsOf: dir.appendingPathComponent("art.png")) else { fatalError("no art.png in \(dir.path)") }
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

/// Superellipse (n = 5), close to Apple's continuous-corner squircle, filling `r`.
func squircle(_ r: NSRect) -> NSBezierPath {
    let p = NSBezierPath(), n = 5.0, steps = 360
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2 * .pi, c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1), y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let pt = NSPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

func render(_ px: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let s = CGFloat(px) / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = squircle(tile)

    // shadow: Apple's template uses about 28 px blur, 12 px down, 30 % black at 1024
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    art.draw(in: tile, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // a hairline edge so the tile holds its shape on dark and light backgrounds alike
    shape.lineWidth = max(1, 2 * s)
    NSColor.white.withAlphaComponent(0.18).setStroke(); shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
}

for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales { render(pt * sc, "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png") }
}
print(set.path)
