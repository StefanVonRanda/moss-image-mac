// Renders logo.svg onto a rounded light tile at every macOS icon size, then builds AppIcon.icns.
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let logo = NSImage(contentsOf: dir.appendingPathComponent("logo.svg"))!
let set = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(_ px: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // Apple's icon grid: tile is ~80% of the canvas, corner radius ~22.5% of the tile
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1).setFill()
    path.fill()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01); shadow.shadowBlurRadius = s * 0.02
    let inset = tile.insetBy(dx: tile.width * 0.12, dy: tile.height * 0.12)
    logo.draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
}
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales { render(pt * sc, "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png") }
}
print(set.path)
