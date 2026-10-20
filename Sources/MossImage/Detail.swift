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
                        Text(gen.effectiveMaskExists ? "Strength in mask" : "Strength").foregroundStyle(.secondary).padding(.leading, 8)
                        Slider(value: $gen.strength, in: 0.1...1, step: 0.05).frame(width: 140)
                        Text(String(format: "%.2f", gen.strength)).monospacedDigit().frame(width: 36)
                            .help(!gen.effectiveMaskExists ? "0.3 keeps the picture, 0.8 keeps only the composition"
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

/// Strokes as a Canvas: freehand polylines with the brush, or closed 5-point rectangles filled (from boxes / rectangle tool).
struct MaskStrokes: View {
    let strokes: [[CGPoint]]
    let brush: Double
    let scale: CGFloat
    let color: Color

    var body: some View {
        Canvas { ctx, _ in
            for s in strokes {
                var path = Path()
                if s.count == 1 {
                    path.addEllipse(in: CGRect(x: s[0].x * scale - brush * scale / 2, y: s[0].y * scale - brush * scale / 2, width: brush * scale, height: brush * scale))
                    ctx.fill(path, with: .color(color)); continue
                }
                path.move(to: CGPoint(x: s[0].x * scale, y: s[0].y * scale))
                for p in s.dropFirst() { path.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale)) }
                if s.count == 5, s.first == s.last { path.closeSubpath(); ctx.fill(path, with: .color(color)); continue }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: brush * scale, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Paint the area to regenerate. Strokes live in output-pixel coordinates over the cropped source;
/// each finished stroke rewrites the mask PNG at output size, white = change, black = keep.
struct MaskCanvas: View {
    @ObservedObject var gen: Generator
    @State private var tool = "rect"      // rect | brush
    @State private var rectStart: CGPoint?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $tool) { Text("Rectangle").tag("rect"); Text("Brush").tag("brush") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                if tool == "brush" {
                    Text("Brush").foregroundStyle(.secondary)
                    Slider(value: $gen.maskBrush, in: 10...300).frame(width: 140)
                }
                Spacer()
                Toggle("Mask from layout boxes", isOn: $gen.maskFromBoxes).toggleStyle(.checkbox)
                    .help("Regenerate only inside the layout boxes. The quickest way to replace text: draw a text box over the old words, type the new ones, generate.")
                Button("Clear") { gen.maskStrokes = []; gen.maskPath = "" }.disabled(gen.maskStrokes.isEmpty)
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
                        if gen.maskFromBoxes, !gen.layout.items.isEmpty {
                            MaskStrokes(strokes: gen.boxStrokes, brush: 0, scale: scale, color: .orange.opacity(0.45)).frame(width: W * scale, height: H * scale)
                        }
                        MaskStrokes(strokes: gen.maskStrokes, brush: gen.maskBrush, scale: scale, color: .accentColor.opacity(0.55)).frame(width: W * scale, height: H * scale)
                    }
                    .frame(width: W * scale, height: H * scale)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { g in
                            let p = CGPoint(x: g.location.x / scale, y: g.location.y / scale)
                            if tool == "rect" {
                                let a = CGPoint(x: g.startLocation.x / scale, y: g.startLocation.y / scale)
                                let r = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
                                let rect = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
                                if rectStart == nil { rectStart = a; gen.maskStrokes.append(rect) } else { gen.maskStrokes[gen.maskStrokes.count - 1] = rect }
                            } else {
                                if g.translation == .zero || gen.maskStrokes.isEmpty { gen.maskStrokes.append([p]) } else { gen.maskStrokes[gen.maskStrokes.count - 1].append(p) }
                            }
                        }
                        .onEnded { _ in rectStart = nil; save() })
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            Text(statusLine).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var statusLine: String {
        if gen.maskFromBoxes, !gen.layout.items.isEmpty { return "Mask follows the \(gen.layout.items.count) layout boxes (orange). Painted areas are ignored while this is on." }
        if gen.maskPath.isEmpty { return "No mask: the whole image is regenerated at the chosen strength, text included. Draw a rectangle over what should change." }
        return "Mask set. Pixels outside it stay identical; strength now applies inside the mask (1.0 = replace)."
    }

    /// Fill every layout box as a painted mask (for when the automatic option is off).
    func maskFromBoxes() { gen.maskStrokes = gen.boxStrokes; save() }

    @MainActor func save() {
        guard !gen.maskStrokes.isEmpty else { return }
        if gen.maskPath.isEmpty, gen.strength < 1 { gen.strength = 1 }  // first mask: replacing is the common intent
        if let path = gen.writeMask(gen.maskStrokes) { gen.maskPath = path }
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
