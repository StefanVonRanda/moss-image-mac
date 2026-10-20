import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right-hand side: a mode bar per tab, then the view for that mode.
struct DetailView: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if gen.tab == "t2i" {
                    Picker("", selection: $gen.t2iMode) {
                        Text("Result").tag("result"); Text("Layout").tag("layout")
                    }
                } else {
                    Picker("", selection: $gen.i2iMode) {
                        Text("Source").tag("source"); Text("Mask").tag("mask"); Text("Layout").tag("layout"); Text("Result").tag("result")
                    }
                }
                Spacer()
                if gen.tab == "i2i", !gen.initImage.isEmpty {
                    Text("Strength").foregroundStyle(.secondary)
                    Slider(value: $gen.strength, in: 0.1...1, step: 0.05).frame(width: 140)
                    Text(String(format: "%.2f", gen.strength)).monospacedDigit().frame(width: 36)
                        .help("0.3 keeps the picture, 0.8 keeps only the composition")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            Group {
                switch (gen.tab, gen.tab == "t2i" ? gen.t2iMode : gen.i2iMode) {
                case ("t2i", "layout"): LayoutCanvas(gen: gen, background: nil)
                case ("i2i", "source"): SourceView(gen: gen)
                case ("i2i", "mask"): MaskCanvas(gen: gen)
                case ("i2i", "layout"): LayoutCanvas(gen: gen, background: sourceImage)
                default: ResultView(gen: gen)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            Text(gen.maskPath.isEmpty ? "No mask: the whole image is regenerated at the chosen strength." : "Mask set. Pixels outside it stay identical.")
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
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: brush * scale, lineCap: .round, lineJoin: .round))
            }
        }
    }

    @MainActor private func save() {
        guard !gen.maskStrokes.isEmpty else { return }
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
