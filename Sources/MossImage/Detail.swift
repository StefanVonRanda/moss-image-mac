import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right-hand side: a mode bar per tab, then the view for that mode.
struct DetailView: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(spacing: 0) {
            if gen.tab == "t2i" { t2iBar } else { i2iBar }
            Divider()
            Group {
                if gen.tab == "t2i" {
                    if gen.layoutOverlay { LayoutCanvas(gen: gen, background: resultImage) } else { ResultView(gen: gen) }
                } else if gen.initImage.isEmpty {
                    SourceView(gen: gen)
                } else {
                    VStack(spacing: 0) {
                        LayoutCanvas(gen: gen, background: sourceImage, showMask: true)
                            .id(gen.initImage)
                        Divider()
                        HistoryStrip(gen: gen, pinned: gen.originalSource, current: gen.initImage) { path in gen.initImage = path }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(gen: gen)
        }
    }

    private var t2iBar: some View {
        HStack {
            Spacer()
            Toggle(isOn: $gen.layoutOverlay) {
                Label(gen.layout.items.isEmpty ? "Layout" : "Layout · \(gen.layout.items.count)", systemImage: "rectangle.3.group")
            }
            .toggleStyle(.button)
            .help("Draw text and object boxes over the current image. Boxes are sent with the prompt while Layout is ticked in the sidebar.")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var i2iBar: some View {
        HStack(spacing: 12) {
            if !gen.initImage.isEmpty {
                Text(gen.layout.items.isEmpty ? "No boxes: the whole image is re-rendered at this strength."
                                              : "\(gen.layout.items.count) boxes: only their areas are regenerated, the rest stays identical.")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer()
                strength
                changeSource
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var strength: some View {
        HStack(spacing: 6) {
            Text(gen.effectiveMaskExists ? "Strength in mask" : "Strength").foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Slider(value: $gen.strength, in: 0.1...1, step: 0.05).frame(width: 110)
            Text(String(format: "%.2f", gen.strength)).monospacedDigit().frame(width: 36)
        }
        .help(!gen.effectiveMaskExists ? "0.3 keeps the picture, 0.8 keeps only the composition"
                                       : "Applies inside the mask only. 1.0 replaces the content, lower values retouch it.")
    }

    private var changeSource: some View {
        Button("Change source…") { pickSource() }.controlSize(.small).fixedSize()
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.message = "Choose a source image"
        if panel.runModal() == .OK, let url = panel.url { gen.setSource(url.path) }
    }

    private var sourceImage: NSImage? { gen.initImage.isEmpty ? nil : NSImage(contentsOf: URL(fileURLWithPath: gen.initImage)) }
    private var resultImage: NSImage? { gen.selected.flatMap { NSImage(contentsOf: $0.url) } }
}

/// Thumbnails: the pinned original first, then every render, newest first. Click one to work on it.
struct HistoryStrip: View {
    @ObservedObject var gen: Generator
    let pinned: String
    let current: String
    let pick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if !pinned.isEmpty { thumb(pinned, label: "Original") }
                ForEach(gen.jobs) { job in thumb(job.url.path, label: nil) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(height: 92)
    }

    private func thumb(_ path: String, label: String?) -> some View {
        Group {
            if let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(current == path ? Color.accentColor : .clear, lineWidth: 2))
                    .overlay(alignment: .bottomLeading) {
                        if let label { Text(label).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 3)).padding(3) }
                    }
                    .onTapGesture { pick(path) }
                    .help(path == pinned ? "The original source" : URL(fileURLWithPath: path).lastPathComponent)
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        if let job = gen.jobs.first(where: { $0.url.path == path }) {
                            Button("Move to Trash", role: .destructive) { gen.trash(job) }
                        }
                    }
            }
        }
    }
}

/// The source image as the CLI will see it: resized and centre-cropped to the output aspect.
struct CroppedImage: View {
    let image: NSImage
    var body: some View {
        Color.clear.overlay(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)).clipped()
    }
}

struct SourceView: View {
    @ObservedObject var gen: Generator
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Drop an image here, or").foregroundStyle(.secondary)
            Button("Choose…", action: pick)
            if gen.selected != nil { Button("Use the last result") { if let j = gen.selected { gen.setSource(j.url.path) } } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            providers.first?.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in gen.setSource(url.path) }
            }
            return true
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.message = "Choose a source image"
        if panel.runModal() == .OK, let url = panel.url { gen.setSource(url.path) }
    }
}

/// Closed rectangles (5 points, first == last) filled on a Canvas: the box mask preview and the mask PNG.
struct MaskStrokes: View {
    let strokes: [[CGPoint]]
    let scale: CGFloat
    let color: Color

    var body: some View {
        Canvas { ctx, _ in
            for s in strokes where s.count >= 3 {
                var path = Path()
                path.move(to: CGPoint(x: s[0].x * scale, y: s[0].y * scale))
                for p in s.dropFirst() { path.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale)) }
                path.closeSubpath()
                ctx.fill(path, with: .color(color))
            }
        }
    }
}

/// Always visible under the detail area, whatever view or tab is showing.
struct StatusBar: View {
    @ObservedObject var gen: Generator

    var body: some View {
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
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
