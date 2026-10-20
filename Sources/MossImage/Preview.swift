import SwiftUI
import AppKit

struct ResultView: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let job = gen.selected, let img = NSImage(contentsOf: job.url) {
                    ZoomableImage(url: job.url)
                        .contextMenu {
                            Button("4 more seeds") { gen.variations(of: job, count: 4) }
                            Button("Same seed at 2 MP") { gen.rerender(job, megapixels: 2) }
                            Button("Use as source image") { gen.setSource(job.url.path); gen.tab = "i2i" }
                            Divider()
                            Button("Reuse prompt and seed") { gen.prompt = job.prompt; gen.seed = job.seed; gen.randomSeed = false }
                            Button("Copy image") { copy(img) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { gen.trash(job) }
                        }
                } else {
                    Text(gen.jobs.isEmpty ? "No image yet. Write a prompt and press ⌘↩." : "")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !gen.jobs.isEmpty {
                HStack(spacing: 0) {
                Button { gen.historyHidden.toggle() } label: {
                    Image(systemName: gen.historyHidden ? "chevron.up" : "chevron.down").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 8)
                .help(gen.historyHidden ? "Show history" : "Hide history")
                if gen.historyHidden {
                    Text("\(gen.jobs.count) images").font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                    Spacer()
                } else {
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
                                    .contextMenu {
                                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                                        Button("Move to Trash", role: .destructive) { gen.trash(job) }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                }
                }
                }
                .frame(height: gen.historyHidden ? 28 : 92)
                Divider()
            }

        }
    }

    private func copy(_ img: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}

/// Scroll wheel zooms at the cursor, click-drag pans, pinch zooms, double-click toggles fit / 2x.
struct ZoomableImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> ImageScrollView {
        let v = ImageScrollView()
        v.load(url)
        return v
    }

    /// Only a different file replaces the image; SwiftUI refreshes (status updates, etc.) leave the view alone.
    func updateNSView(_ v: ImageScrollView, context: Context) { if v.url != url { v.load(url) } }
}

final class ImageScrollView: NSScrollView {
    let imageView = NSImageView()
    private(set) var url: URL?
    private var fitScale: CGFloat = 1
    private var userZoomed = false

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

    func load(_ url: URL) {
        self.url = url
        guard let image = NSImage(contentsOf: url) else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        userZoomed = false
        needsLayout = true
        fitToWindow()
    }

    override func layout() {
        super.layout()
        if !userZoomed { fitToWindow() }   // follow the view's size until the user zooms
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }

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
            userZoomed = true
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
        if fit { userZoomed = true; setMagnification(max(fitScale * 2, 1), centeredAt: point) } else { userZoomed = false; fitToWindow() }
    }

    override var acceptsFirstResponder: Bool { true }
}
