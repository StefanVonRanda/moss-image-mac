import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right-hand side: a mode bar per tab, then the view for that mode.
struct DetailView: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(spacing: 0) {
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

    private var sourceImage: NSImage? { gen.canvasSource.isEmpty ? nil : ImageCache.image(gen.canvasSource) }
    private var resultImage: NSImage? { gen.selected.flatMap { ImageCache.image($0.url.path) } }
}

/// Thumbnails: the pinned original first, then every render, newest first. Click one to work on it.
struct HistoryStrip: View {
    @ObservedObject var gen: Generator
    let pinned: String
    let current: String
    let pick: (String) -> Void

    var body: some View {
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
                        if !pinned.isEmpty { thumb(pinned, label: "Original") }
                        ForEach(gen.jobs) { job in thumb(job.url.path, label: nil) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                }
            }
        }
        .frame(height: gen.historyHidden ? 28 : 92)
    }

    private func thumb(_ path: String, label: String?) -> some View {
        Group {
            if let img = ImageCache.thumbnail(path) {
                Button { pick(path) } label: {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(current == path ? Color.accentColor : .clear, lineWidth: 2))
                        .overlay(alignment: .bottomLeading) {
                            if let label { Text(label).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 3)).padding(3) }
                        }
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label ?? gen.jobs.first { $0.url.path == path }.map { "Image, seed \($0.seed)" } ?? "Image")
                    .accessibilityAddTraits(current == path ? .isSelected : [])
                    .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
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
    @State private var showLog = false
    @State private var showInfo = false
    @State private var showQueue = false

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
            if !gen.pending.isEmpty {
                Text("·").foregroundStyle(.secondary)
                Button("\(gen.pending.count) queued") { showQueue.toggle() }.buttonStyle(.link).help("Renders waiting for the next batch")
                    .popover(isPresented: $showQueue, arrowEdge: .top) { QueueView(gen: gen) }
            }
            Spacer()
            if !gen.log.isEmpty {
                let failed = !gen.running && gen.status.hasPrefix("Failed")
                Button { showLog.toggle() } label: {
                    Label("Log", systemImage: failed ? "exclamationmark.triangle.fill" : "text.alignleft")
                        .symbolRenderingMode(failed ? .multicolor : .monochrome)
                }
                .controlSize(.small).help("The moss-mlx output of the last batch")
                .popover(isPresented: $showLog, arrowEdge: .top) { LogView(text: LogView.readable(gen.log)) }
            }
            if let job = gen.selected {
                Button { showInfo.toggle() } label: { Label("Info", systemImage: "info.circle") }
                    .controlSize(.small).keyboardShortcut("i").help("Settings of the selected image (⌘I)")
                    .popover(isPresented: $showInfo, arrowEdge: .top) { InfoView(url: job.url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .onChange(of: gen.remaining) { _, n in NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil }
        .onChange(of: gen.running) { _, on in if !on, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) } }
    }
}

/// Renders waiting for the next batch, each removable. The running batch is with moss-mlx already, so not listed.
struct QueueView: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(gen.pending, id: \.output) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(gen.queuedTitle(r)).lineLimit(1).truncationMode(.tail)
                                Text(verbatim: "\(r.width) × \(r.height) · seed \(r.seed)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { gen.removeQueued(r.output) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from the queue")
                                .accessibilityLabel("Remove \(gen.queuedTitle(r)), seed \(r.seed)")
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 320).fixedSize(horizontal: false, vertical: true)
            if gen.running, gen.remaining > gen.pending.count {
                let n = gen.remaining - gen.pending.count
                Text("Not listed: \(n == 1 ? "the image" : "\(n) images") moss-mlx is rendering now. Cancel stops \(n == 1 ? "it" : "them") too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack { Spacer(); Button("Remove All Queued") { gen.removeQueued() } }
        }
        .padding(12).frame(width: 360)
    }
}

/// The CLI's stderr, monospaced and selectable, kept scrolled to the end.
struct LogView: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        }
        .padding(12).frame(width: 620, height: 380)
    }

    /// What a terminal would show: each line keeps only what follows its last \r, so `\rstep 1/8 … \rstep 8/8`
    /// collapses to its final state instead of burying the useful lines.
    static func readable(_ log: String) -> String {
        // "\r\n" is one Character in Swift, so it would split on neither
        log.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r").last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }
}

/// Settings of a finished render, read from the full sidecar next to it.
struct InfoView: View {
    let url: URL

    var body: some View {
        let side = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))) as? [String: Any]
        let (prompt, rows) = Self.summary(side ?? [:])
        VStack(alignment: .leading, spacing: 10) {
            if side == nil { Text("No settings were saved next to this image.").foregroundStyle(.secondary) }
            ScrollView {
                Text(prompt).font(prompt.hasPrefix("{") ? .system(.caption, design: .monospaced) : .body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow { Text(rows[i].0).foregroundStyle(.secondary).gridColumnAlignment(.trailing); Text(rows[i].1).textSelection(.enabled) }
                }
            }
            HStack {
                Spacer()
                Button("Copy Prompt") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt, forType: .string) }
                    .disabled(prompt.isEmpty)
            }
        }
        .padding(14).frame(width: 460)
    }

    /// The prompt (the app's raw prompt if saved, else the one sent; layout JSON pretty-printed) and label/value rows.
    static func summary(_ side: [String: Any]) -> (prompt: String, rows: [(String, String)]) {
        let p = side["parameters"] as? [String: Any] ?? [:], t = side["timings"] as? [String: Any] ?? [:]
        var prompt = (side["app"] as? [String: Any])?["prompt"] as? String ?? p["prompt"] as? String ?? ""
        if prompt.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(prompt.utf8)),
           let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            prompt = String(decoding: data, as: UTF8.self)
        }
        var rows: [(String, String)] = []
        func add(_ label: String, _ value: Any?, _ unit: String = "") {
            if let v = (value as? NSNumber)?.stringValue ?? value as? String { rows.append((label, v + unit)) }
        }
        add("Seed", p["seed"])
        if let w = p["width"] as? Int, let h = p["height"] as? Int { add("Size", "\(w) × \(h)") }
        add("Steps", p["steps"])
        add("CFG", p["cfg"] ?? p["guidance"])
        if let src = p["init_image"] as? String {
            add("Source", URL(fileURLWithPath: src).lastPathComponent)
            add("Strength", p["strength"])
        }
        let tier = (side["app"] as? [String: Any])?["tier"] as? String
        add("Model", tier.map { ["compact": "Compact", "8bit": "8-bit"][$0] ?? $0 })
        // "path/x.safetensors:1.00" → "x.safetensors 1.00"
        let loras = (side["loras"] as? [String] ?? []).map { spec -> String in
            guard let i = spec.lastIndex(of: ":"), Double(spec[spec.index(after: i)...]) != nil else { return URL(fileURLWithPath: spec).lastPathComponent }
            return URL(fileURLWithPath: String(spec[..<i])).lastPathComponent + " " + spec[spec.index(after: i)...]
        }
        if !loras.isEmpty { add("LoRAs", loras.joined(separator: "\n")) }
        add("Render time", t["total_s"], " s")
        add("Peak memory", t["mlx_peak_memory_gb"], " GB")
        return (prompt, rows)
    }
}
