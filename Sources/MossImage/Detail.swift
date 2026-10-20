import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right-hand side: a mode bar per tab, then the view for that mode.
struct DetailView: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if gen.tab == "i2i" {
                    Picker("", selection: $gen.i2iMode) {
                        Text("Source").tag("source"); Text("Mask").tag("mask"); Text("Result").tag("result")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    if !gen.initImage.isEmpty {
                        Text(gen.maskPath.isEmpty ? "Strength" : "Strength in mask").foregroundStyle(.secondary).padding(.leading, 8)
                        Slider(value: $gen.strength, in: 0.1...1, step: 0.05).frame(width: 140)
                        Text(String(format: "%.2f", gen.strength)).monospacedDigit().frame(width: 36)
                            .help(gen.maskPath.isEmpty ? "0.3 keeps the picture, 0.8 keeps only the composition"
                                                       : "Applies inside the mask only. 1.0 replaces the content, lower values retouch it.")
                    }
                }
                Spacer()
                Toggle(isOn: $gen.layoutOverlay) {
                    Label(gen.layout.items.isEmpty ? "Layout" : "Layout · \(gen.layout.items.count)", systemImage: "rectangle.3.group")
                }
                .toggleStyle(.button)
                .help("Draw text and object boxes over the current image. Boxes are sent with the prompt while Layout is ticked in the sidebar.")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            Group {
                if gen.layoutOverlay {
                    LayoutCanvas(gen: gen, background: overlayBackground)
                } else {
                    switch (gen.tab, gen.i2iMode) {
                    case ("i2i", "source"): SourceView(gen: gen)
                    case ("i2i", "mask"): MaskCanvas(gen: gen)
                    default: ResultView(gen: gen)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(gen: gen)
        }
    }

    /// What the layout boxes are drawn over: the source in the Source and Mask views, else the current result.
    private var overlayBackground: NSImage? {
        if gen.tab == "i2i", gen.i2iMode != "result" { return sourceImage }
        return gen.selected.flatMap { NSImage(contentsOf: $0.url) }
    }

    private var sourceImage: NSImage? { gen.initImage.isEmpty ? nil : NSImage(contentsOf: URL(fileURLWithPath: gen.initImage)) }
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
        VStack(spacing: 12) {
            if gen.initImage.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Drop an image here, or").foregroundStyle(.secondary)
                    Button("Choose…", action: pick)
                    if gen.selected != nil { Button("Use the last result") { if let j = gen.selected { gen.setSource(j.url.path) } } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let img = NSImage(contentsOf: URL(fileURLWithPath: gen.initImage)) {
                GeometryReader { geo in
                    let W = CGFloat(gen.width), H = CGFloat(gen.height)
                    let scale = min((geo.size.width - 32) / W, (geo.size.height - 32) / H)
                    CroppedImage(image: img).frame(width: W * scale, height: H * scale)
                        .border(Color(nsColor: .separatorColor))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                HStack {
                    Text(URL(fileURLWithPath: gen.initImage).lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Text("· shown cropped to " + String(gen.width) + " × " + String(gen.height)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: pick)
                    Button("Clear") { gen.setSource("") }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
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

/// Paint the area to regenerate. Strokes live in output-pixel coordinates over the cropped source;
/// each finished stroke rewrites the mask PNG at output size, white = change, black = keep.
struct MaskCanvas: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Paint what should change").foregroundStyle(.secondary)
                Spacer()
                Text("Brush").foregroundStyle(.secondary)
                Slider(value: $gen.maskBrush, in: 10...300).frame(width: 160)
                Button("Clear") { gen.maskStrokes = []; gen.maskPath = "" }.disabled(gen.maskStrokes.isEmpty)
                Button("Mask from boxes") { maskFromBoxes() }.disabled(gen.layout.items.isEmpty)
                    .help("Fill every layout box: the quickest way to replace text or an object in place")
            }
            .controlSize(.small)
            if gen.initImage.isEmpty {
                Text("Choose a source image first.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let img = NSImage(contentsOf: URL(fileURLWithPath: gen.initImage)) {
                GeometryReader { geo in
                    let W = CGFloat(gen.width), H = CGFloat(gen.height)
                    let scale = min(geo.size.width / W, geo.size.height / H)
                    ZStack {
                        CroppedImage(image: img).frame(width: W * scale, height: H * scale)
                        strokes(scale: scale, color: .accentColor.opacity(0.55)).frame(width: W * scale, height: H * scale)
                    }
                    .frame(width: W * scale, height: H * scale)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { g in
                            let p = CGPoint(x: g.location.x / scale, y: g.location.y / scale)
                            if g.translation == .zero || gen.maskStrokes.isEmpty { gen.maskStrokes.append([p]) } else { gen.maskStrokes[gen.maskStrokes.count - 1].append(p) }
                        }
                        .onEnded { _ in save() })
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            Text(gen.maskPath.isEmpty ? "No mask: the whole image is regenerated at the chosen strength."
                                      : "Mask set. Pixels outside it stay identical; strength now applies inside the mask (1.0 = replace).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func strokes(scale: CGFloat, color: Color) -> some View {
        let brush = gen.maskBrush
        return Canvas { ctx, _ in
            for s in gen.maskStrokes {
                var path = Path()
                if s.count == 1 {
                    path.addEllipse(in: CGRect(x: s[0].x * scale - brush * scale / 2, y: s[0].y * scale - brush * scale / 2, width: brush * scale, height: brush * scale))
                    ctx.fill(path, with: .color(color)); continue
                }
                path.move(to: CGPoint(x: s[0].x * scale, y: s[0].y * scale))
                for p in s.dropFirst() { path.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale)) }
                if s.count == 5, s.first == s.last { path.closeSubpath(); ctx.fill(path, with: .color(color)); continue }  // box rectangle
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: brush * scale, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// One rectangular stroke per layout box, padded a little so glyph edges are covered.
    func maskFromBoxes() {
        gen.maskStrokes = gen.layout.items.map { it in
            let r = it.rect.insetBy(dx: -8, dy: -8)
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        }
        save()
    }

    @MainActor func save() {
        guard !gen.maskStrokes.isEmpty else { return }
        if gen.maskPath.isEmpty, gen.strength < 1 { gen.strength = 1 }  // first mask: replacing is the common intent
        let W = CGFloat(gen.width), H = CGFloat(gen.height)
        let renderer = ImageRenderer(content: ZStack { Color.black; strokes(scale: 1, color: .white) }.frame(width: W, height: H))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        let dir = URL(fileURLWithPath: gen.outputDir).appendingPathComponent("masks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mask-\(Int(Date().timeIntervalSince1970)).png")
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
        gen.maskPath = url.path
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
            if gen.running, gen.tab == "i2i", gen.i2iMode != "result" {
                Button("Show result") { gen.i2iMode = "result"; gen.layoutOverlay = false }.controlSize(.small)
            }
            if let job = gen.selected {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
