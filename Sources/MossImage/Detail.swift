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
                } else if gen.showResult, let r = resultImage {
                    ResultView(gen: gen)
                        .overlay(alignment: .topTrailing) {
                            Button("Use as new source") { if let j = gen.selected { gen.setSource(j.url.path); gen.showResult = false } }
                                .controlSize(.small).padding(12)
                        }
                        .id(r.hash)
                } else {
                    LayoutCanvas(gen: gen, background: sourceImage, tool: gen.editTool, showMask: true, showInspector: gen.editTool == "box" || !gen.layout.items.isEmpty)
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
                Picker("", selection: Binding(get: { gen.showResult ? "result" : "source" }, set: { gen.showResult = $0 == "result" })) {
                    Text("Source").tag("source"); Text("Result").tag("result").disabled(gen.selected == nil)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if !gen.showResult {
                    Picker("", selection: $gen.editTool) {
                        Label("Box", systemImage: "rectangle.dashed").tag("box")
                        Label("Mask rectangle", systemImage: "rectangle.fill").tag("rect")
                        Label("Mask brush", systemImage: "paintbrush.pointed").tag("brush")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Box: a layout box (text to render or an object to place). Mask tools: paint what should change.")
                    if gen.editTool == "brush" { Slider(value: $gen.maskBrush, in: 10...300).frame(width: 100).help("Brush size") }
                    Toggle("Mask from boxes", isOn: $gen.maskFromBoxes).toggleStyle(.checkbox)
                        .help("Regenerate only inside the layout boxes. Off: use the painted mask, or the whole image if none.")
                    Button("Clear mask") { gen.maskStrokes = []; gen.maskPath = "" }.disabled(gen.maskStrokes.isEmpty).controlSize(.small)
                }
                Spacer()
                Text(gen.effectiveMaskExists ? "Strength in mask" : "Strength").foregroundStyle(.secondary)
                Slider(value: $gen.strength, in: 0.1...1, step: 0.05).frame(width: 120)
                Text(String(format: "%.2f", gen.strength)).monospacedDigit().frame(width: 36)
                    .help(!gen.effectiveMaskExists ? "0.3 keeps the picture, 0.8 keeps only the composition"
                                                   : "Applies inside the mask only. 1.0 replaces the content, lower values retouch it.")
                Button("Change source…") { pickSource() }.controlSize(.small)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.message = "Choose a source image"
        if panel.runModal() == .OK, let url = panel.url { gen.setSource(url.path); gen.showResult = false }
    }

    private var sourceImage: NSImage? { gen.initImage.isEmpty ? nil : NSImage(contentsOf: URL(fileURLWithPath: gen.initImage)) }
    private var resultImage: NSImage? { gen.selected.flatMap { NSImage(contentsOf: $0.url) } }
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
