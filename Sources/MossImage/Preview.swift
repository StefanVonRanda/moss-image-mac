import SwiftUI
import AppKit

struct PreviewView: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let job = gen.selected, let img = NSImage(contentsOf: job.url) {
                    ZoomableImage(image: img)
                        .contextMenu {
                            Button("4 more seeds") { gen.variations(of: job, count: 4) }
                            Button("Same seed at 2 MP") { gen.rerender(job, megapixels: 2) }
                            Button("Use as source image") { gen.initImage = job.url.path; gen.maskPath = "" }
                            Divider()
                            Button("Reuse prompt and seed") { gen.prompt = job.prompt; gen.seed = job.seed; gen.randomSeed = false }
                            Button("Copy image") { copy(img) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                        }
                } else {
                    Text(gen.jobs.isEmpty ? "No image yet. Write a prompt and press ⌘↩." : "")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !gen.jobs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(gen.jobs) { job in
                            if let img = NSImage(contentsOf: job.url) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(gen.selected == job ? Color.accentColor : .clear, lineWidth: 2))
                                    .onTapGesture { gen.selected = job }
                                    .help(job.seconds > 0 ? "seed \(job.seed) · \(Int(job.seconds)) s" : "seed \(job.seed)")
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Divider()
            }

            HStack {
                if gen.downloading || gen.enhancing { ProgressView().controlSize(.small) }
                if gen.running {
                    if gen.totalSteps > 0 {
                        ProgressView(value: Double(gen.step), total: Double(gen.totalSteps)).frame(width: 160)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(gen.status).foregroundStyle(.secondary).lineLimit(1)
                if !gen.pending.isEmpty { Text("· \(gen.pending.count) queued").foregroundStyle(.secondary) }
                Spacer()
                if let job = gen.selected {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func copy(_ img: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}

/// Scroll wheel zooms at the cursor, click-drag pans, pinch zooms, double-click toggles fit / 2x.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> ImageScrollView {
        let v = ImageScrollView()
        v.setImage(image)
        return v
    }

    func updateNSView(_ v: ImageScrollView, context: Context) { if v.imageView.image !== image { v.setImage(image) } }
}

final class ImageScrollView: NSScrollView {
    let imageView = NSImageView()
    private var fitScale: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        documentView = imageView
        imageView.imageScaling = .scaleNone
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 16
        hasHorizontalScroller = false
        hasVerticalScroller = false
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        needsLayout = true
        fitToWindow()
    }

    override func layout() {
        super.layout()
        if magnification == fitScale { fitToWindow() }
    }

    private func fitToWindow() {
        guard let size = imageView.image?.size, size.width > 0, bounds.width > 0 else { return }
        let inset: CGFloat = 32
        fitScale = min((bounds.width - inset) / size.width, (bounds.height - inset) / size.height)
        magnification = fitScale
        centerImage()
    }

    private func centerImage() {
        let doc = imageView.frame.size, vis = contentView.bounds.size
        contentView.scroll(to: NSPoint(x: (doc.width - vis.width) / 2, y: (doc.height - vis.height) / 2))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == [] && event.momentumPhase == [] || event.modifierFlags.contains(.command) {
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            let target = min(max(magnification * factor, fitScale * 0.5), maxMagnification)
            setMagnification(target, centeredAt: contentView.convert(event.locationInWindow, from: nil))
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var origin = contentView.bounds.origin
        origin.x -= event.deltaX / magnification
        origin.y += event.deltaY / magnification
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        let fit = abs(magnification - fitScale) < 0.001
        let point = contentView.convert(event.locationInWindow, from: nil)
        if fit { setMagnification(max(fitScale * 2, 1), centeredAt: point) } else { fitToWindow() }
    }

    override var acceptsFirstResponder: Bool { true }
}

/// Paint the area to regenerate over the source image. Saves a white-on-black PNG at the source's pixel size.
struct MaskEditor: View {
    @ObservedObject var gen: Generator
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []   // in image pixel coordinates
    @State private var brush: Double = 60
    private let image: NSImage?

    init(gen: Generator) { self.gen = gen; image = NSImage(contentsOf: URL(fileURLWithPath: gen.initImage)) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Mask · paint what should change").font(.headline)
                Spacer()
                Text("Brush").foregroundStyle(.secondary)
                Slider(value: $brush, in: 10...300).frame(width: 160)
                Button("Clear") { strokes = [] }
            }
            if let image, let rep = pixelSize(image) {
                GeometryReader { geo in
                    let scale = min(geo.size.width / rep.width, geo.size.height / rep.height)
                    ZStack {
                        Image(nsImage: image).resizable().frame(width: rep.width * scale, height: rep.height * scale)
                        maskCanvas(scale: scale, size: CGSize(width: rep.width * scale, height: rep.height * scale), color: .accentColor.opacity(0.55))
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    let p = CGPoint(x: g.location.x / scale, y: g.location.y / scale)
                                    if g.translation == .zero { strokes.append([p]) } else { strokes[strokes.count - 1].append(p) }
                                })
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                Text("Could not load the source image.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Remove mask", role: .destructive) { gen.maskPath = ""; dismiss() }.disabled(gen.maskPath.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use mask") { save(); dismiss() }.keyboardShortcut(.defaultAction).disabled(strokes.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
    }

    private func pixelSize(_ img: NSImage) -> CGSize? {
        guard let rep = img.representations.first else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private func maskCanvas(scale: CGFloat, size: CGSize, color: Color) -> some View {
        Canvas { ctx, _ in
            for s in strokes {
                var path = Path()
                if s.count == 1 { path.addEllipse(in: CGRect(x: s[0].x * scale - brush * scale / 2, y: s[0].y * scale - brush * scale / 2, width: brush * scale, height: brush * scale)); ctx.fill(path, with: .color(color)); continue }
                path.move(to: CGPoint(x: s[0].x * scale, y: s[0].y * scale))
                for p in s.dropFirst() { path.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale)) }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: brush * scale, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @MainActor private func save() {
        guard let image, let px = pixelSize(image) else { return }
        let renderer = ImageRenderer(content: ZStack { Color.black; maskCanvas(scale: 1, size: px, color: .white) }.frame(width: px.width, height: px.height))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        let dir = URL(fileURLWithPath: gen.outputDir).appendingPathComponent("masks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mask-\(Int(Date().timeIntervalSince1970)).png")
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        gen.maskPath = url.path
    }
}
