// Renders the app icon at every macOS size into AppIcon.iconset. Usage: make_icon <icon dir>
// The mark is generic on purpose (a bold "M" on a flat blue tile) so it does not reuse OpenMOSS's logo.
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
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
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).fill(with: NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.80, alpha: 1))

    // a small picture frame in the top-right corner, with a sun
    let frame = NSRect(x: tile.maxX - tile.width * 0.36, y: tile.maxY - tile.height * 0.34, width: tile.width * 0.24, height: tile.height * 0.19)
    let framePath = NSBezierPath(roundedRect: frame, xRadius: frame.height * 0.15, yRadius: frame.height * 0.15)
    framePath.lineWidth = max(1, s * 0.018)
    NSColor.white.withAlphaComponent(0.9).setStroke(); framePath.stroke()
    NSBezierPath(ovalIn: NSRect(x: frame.maxX - frame.width * 0.38, y: frame.maxY - frame.height * 0.45, width: frame.width * 0.2, height: frame.width * 0.2)).fill(with: NSColor.white.withAlphaComponent(0.9))
    let hill = NSBezierPath()
    hill.move(to: NSPoint(x: frame.minX + frame.width * 0.08, y: frame.minY + frame.height * 0.12))
    hill.line(to: NSPoint(x: frame.minX + frame.width * 0.42, y: frame.maxY - frame.height * 0.25))
    hill.line(to: NSPoint(x: frame.minX + frame.width * 0.62, y: frame.minY + frame.height * 0.5))
    hill.line(to: NSPoint(x: frame.maxX - frame.width * 0.08, y: frame.minY + frame.height * 0.12))
    hill.close(); NSColor.white.withAlphaComponent(0.9).setFill(); hill.fill()

    // the letter
    let font = NSFont.systemFont(ofSize: tile.height * 0.62, weight: .black)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let str = NSAttributedString(string: "M", attributes: attrs)
    let size = str.size()
    str.draw(at: NSPoint(x: tile.minX + tile.width * 0.1, y: tile.midY - size.height / 2 - tile.height * 0.05))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
}

extension NSBezierPath {
    func fill(with color: NSColor) { color.setFill(); fill() }
}

for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales { render(pt * sc, "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png") }
}
print(set.path)
