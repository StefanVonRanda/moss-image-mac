import SwiftUI
import AppKit

@main
struct MossImageApp: App {
    var body: some Scene {
        WindowGroup("MOSS Image") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        Settings { SettingsView() }
    }
}

// MARK: - Model

struct Job: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let prompt: String
    let seed: Int
    let seconds: Double
}

@MainActor
final class Generator: ObservableObject {
    @AppStorage("prompt") var prompt = ""
    @AppStorage("negative") var negative = ""
    @AppStorage("width") var width = 1024
    @AppStorage("height") var height = 1024
    @AppStorage("aspect") var aspect = "1:1"        // "custom" keeps width/height as typed
    @AppStorage("megapixels") var megapixels = 1.0  // 0.25 … 2
    @AppStorage("seed") var seed = 1
    @AppStorage("randomSeed") var randomSeed = true
    @AppStorage("steps") var steps = 8
    @AppStorage("guidance") var guidance = 1.0
    @AppStorage("loraTriggers") private var loraTriggersJSON = #"{"Moss-image-gouache-lora.safetensors":"moss_vgouache_style"}"#  // file -> trigger word
    @AppStorage("loraState") private var loraStateJSON = #"{"MOSS-Image-SFT-8-steps-dmd.safetensors":1.0}"#  // enabled file -> scale
    @AppStorage("loraDir") var loraDir = NSHomeDirectory() + "/moss-mlx/loras"
    @AppStorage("tier") var tier = "compact"
    @AppStorage("cli") var cli = NSHomeDirectory() + "/moss-mlx/bin/moss-mlx"
    @AppStorage("outputDir") var outputDir = NSHomeDirectory() + "/Pictures/MOSS Image"

    @Published var running = false
    @Published var step = 0
    @Published var totalSteps = 0
    @Published var status = ""
    @Published var log = ""
    @Published var jobs: [Job] = []
    @Published var selected: Job?
    @Published var loras: [String] = []
    @Published var downloading = false

    private var process: Process?

    init() { refreshLoras(); if aspect != "custom" { applyPreset() } }

    /// Enabled adapters and their strengths, persisted as JSON. Disabled adapters are simply absent.
    var loraState: [String: Double] {
        get { (try? JSONDecoder().decode([String: Double].self, from: Data(loraStateJSON.utf8))) ?? [:] }
        set { loraStateJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8), as: UTF8.self); objectWillChange.send() }
    }

    func isEnabled(_ file: String) -> Binding<Bool> {
        Binding(get: { self.loraState[file] != nil },
                set: { on in var st = self.loraState; st[file] = on ? (st[file] ?? 1) : nil; self.loraState = st })
    }

    func scale(_ file: String) -> Binding<Double> {
        Binding(get: { self.loraState[file] ?? 1 }, set: { v in var st = self.loraState; st[file] = v; self.loraState = st })
    }

    var loraTriggers: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(loraTriggersJSON.utf8))) ?? [:] }
        set { loraTriggersJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8), as: UTF8.self); objectWillChange.send() }
    }

    func trigger(_ file: String) -> Binding<String> {
        Binding(get: { self.loraTriggers[file] ?? "" }, set: { v in var t = self.loraTriggers; t[file] = v.isEmpty ? nil : v; self.loraTriggers = t })
    }

    /// Prompt as sent: trigger words of enabled adapters prepended (unless already present), trigger words of
    /// disabled adapters removed even if typed by hand.
    var effectivePrompt: String {
        var text = prompt
        for file in loras where loraState[file] == nil {
            guard let word = loraTriggers[file] else { continue }
            let pattern = "(?i)\\s*,?\\s*" + NSRegularExpression.escapedPattern(for: word) + "\\s*,?\\s*"
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = loras.filter { loraState[$0] != nil }.compactMap { loraTriggers[$0] }
            .filter { !text.localizedCaseInsensitiveContains($0) }
        return (words + [text]).joined(separator: ", ")
    }

    static let aspects: [(String, Double)] = [("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4), ("3:2", 1.5), ("2:3", 2.0 / 3),
                                             ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("21:9", 21.0 / 9)]

    /// Width x height for the chosen aspect and pixel budget, each a multiple of 16 (the VAE patch size).
    func applyPreset() {
        guard let ratio = Self.aspects.first(where: { $0.0 == aspect })?.1 else { return }
        let pixels = megapixels * 1024 * 1024  // so 1 MP at 1:1 is exactly 1024²
        let h = (pixels / ratio).squareRoot()
        width = Int((h * ratio / 16).rounded()) * 16
        height = Int((h / 16).rounded()) * 16
    }

    func enable(_ file: String, scale: Double) { var st = loraState; st[file] = scale; loraState = st }

    func refreshLoras() {
        try? FileManager.default.createDirectory(atPath: loraDir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: loraDir)) ?? []
        loras = files.filter { $0.hasSuffix(".safetensors") }.sorted()
        loraState = loraState.filter { loras.contains($0.key) }
    }

    /// Copy a local .safetensors into the library and select it.
    func importLora(_ url: URL) {
        let dest = URL(fileURLWithPath: loraDir).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest); refreshLoras(); enable(dest.lastPathComponent, scale: 1) }
        catch { status = "Import failed: \(error.localizedDescription)" }
    }

    /// Download `file` from a Hugging Face repo with the venv's huggingface_hub, into the library.
    func downloadLora(repo: String, file: String, then: (() -> Void)? = nil) {
        guard !downloading else { return }
        let name = repo.replacingOccurrences(of: "/", with: "__") + (file == "lora.safetensors" ? "" : "__" + file.replacingOccurrences(of: ".safetensors", with: "")) + ".safetensors"
        let dest = URL(fileURLWithPath: loraDir).appendingPathComponent(name)
        let python = URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("python").path
        let code = "import sys, shutil; from huggingface_hub import hf_hub_download; shutil.copyfile(hf_hub_download(sys.argv[1], sys.argv[2]), sys.argv[3])"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", code, repo, file, dest.path]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        downloading = true; status = "Downloading \(repo)/\(file)…"
        p.terminationHandler = { [weak self] proc in
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.downloading = false
                if proc.terminationStatus == 0 {
                    self.refreshLoras(); self.enable(name, scale: 1); self.status = "Downloaded \(name)"; then?()
                } else {
                    self.status = "Download failed: " + (msg.split(separator: "\n").last.map(String.init) ?? "exit \(proc.terminationStatus)")
                }
            }
        }
        do { try p.run() } catch { downloading = false; status = "Could not start python: \(error.localizedDescription)" }
    }

    func generate() {
        guard !running, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        width = max(256, (width / 16) * 16); height = max(256, (height / 16) * 16)  // the CLI requires multiples of 16
        if randomSeed { seed = Int.random(in: 1...999_999) }
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = dir.appendingPathComponent("moss-\(stamp)-\(seed).png")

        var args = [effectivePrompt, "--model", tier, "--width", "\(width)", "--height", "\(height)",
                    "--seed", "\(seed)", "-o", out.path]
        args += ["--steps", "\(steps)", "--guidance", "\(guidance)"]
        if !negative.isEmpty { args += ["--negative-prompt", negative] }
        for file in loras where loraState[file] != nil {  // library order; several adapters stack
            args += ["--lora", loraDir + "/" + file + String(format: ":%.2f", loraState[file]!)]
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        running = true; step = 0; totalSteps = 0; log = ""; status = "Encoding prompt…"
        let started = Date()
        let promptCopy = prompt, seedCopy = seed

        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.running = false
                self.process = nil
                let secs = Date().timeIntervalSince(started)
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) {
                    let job = Job(url: out, prompt: promptCopy, seed: seedCopy, seconds: secs)
                    self.jobs.insert(job, at: 0)
                    self.selected = job
                    self.status = String(format: "Done in %.0f s", secs)
                } else if proc.terminationReason == .uncaughtSignal {
                    self.status = "Cancelled"
                } else {
                    self.status = "Failed (exit \(proc.terminationStatus)). See log."
                }
            }
        }
        do { try p.run(); process = p } catch { running = false; status = "Could not start \(cli): \(error.localizedDescription)" }
    }

    func cancel() { process?.terminate() }

    private func consume(_ text: String) {
        log += text
        // the CLI writes "\rstep i/n  12.3 s" progress lines to stderr
        for chunk in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            if let m = chunk.firstMatch(of: #/step (\d+)\/(\d+)/#) {
                step = Int(m.1) ?? 0; totalSteps = Int(m.2) ?? 0
                status = "Denoising step \(step) of \(totalSteps)"
            } else if chunk.contains("fetching") {
                status = "Downloading model (first run only)…"
            }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var gen = Generator()

    var body: some View {
        NavigationSplitView {
            ControlsView(gen: gen)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            PreviewView(gen: gen)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if gen.running {
                    Button("Cancel", action: gen.cancel)
                } else {
                    Button("Generate", action: gen.generate).keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }
}

struct ControlsView: View {
    @ObservedObject var gen: Generator
    @State private var showDownload = false
    @AppStorage("showAdvanced") private var showAdvanced = false

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "safetensors")!]
        panel.message = "Choose a LoRA .safetensors file to copy into the library"
        if panel.runModal() == .OK, let url = panel.url { gen.importLora(url) }
    }

    var body: some View {
        Form {
            Section("Prompt") {
                TextEditor(text: $gen.prompt)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
            }
            Section("Size") {
                Picker("Aspect", selection: $gen.aspect) {
                    ForEach(Generator.aspects, id: \.0) { Text($0.0).tag($0.0) }
                    Divider()
                    Text("Custom").tag("custom")
                }
                .onChange(of: gen.aspect) { gen.applyPreset() }
                if gen.aspect == "custom" {
                    TextField("Width", value: $gen.width, format: .number)
                    TextField("Height", value: $gen.height, format: .number)
                } else {
                    Picker("Pixels", selection: $gen.megapixels) {
                        Text("0.25 MP · fast draft").tag(0.25)
                        Text("0.5 MP").tag(0.5)
                        Text("1 MP · recommended").tag(1.0)
                        Text("1.5 MP").tag(1.5)
                        Text("2 MP").tag(2.0)
                    }
                    .onChange(of: gen.megapixels) { gen.applyPreset() }
                    LabeledContent("Output", value: "\(gen.width) × \(gen.height)")
                }
            }
            Section("LoRA") {
                if gen.loras.isEmpty {
                    Text("No adapters in the library.").foregroundStyle(.secondary)
                }
                ForEach(gen.loras, id: \.self) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(file.replacingOccurrences(of: ".safetensors", with: ""), isOn: gen.isEnabled(file))
                            .lineLimit(1).truncationMode(.middle)
                        if gen.loraState[file] != nil {
                            HStack {
                                Slider(value: gen.scale(file), in: 0...1.5, step: 0.05)
                                Text(String(format: "%.2f", gen.loraState[file] ?? 1)).monospacedDigit().frame(width: 36)
                            }
                            .controlSize(.small)
                            TextField("Trigger word", text: gen.trigger(file), prompt: Text("optional"))
                                .controlSize(.small)
                        }
                    }
                    .contextMenu {
                        Button("Delete from library") {
                            try? FileManager.default.removeItem(atPath: gen.loraDir + "/" + file); gen.refreshLoras()
                        }
                    }
                }
                HStack {
                    Button("Add file…", action: pickFile)
                    Button("Download…") { showDownload = true }.disabled(gen.downloading)
                    Spacer()
                    Button("Show folder") { NSWorkspace.shared.open(URL(fileURLWithPath: gen.loraDir)) }
                }
                .controlSize(.small)
            }
            Section {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showAdvanced.toggle() }
                } label: {
                    HStack {
                        Text("Advanced")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())  // whole row is the hit area
                }
                .buttonStyle(.plain)
                if showAdvanced {
                Stepper("Steps: \(gen.steps)", value: $gen.steps, in: 1...100)
                HStack {
                    Text("CFG")
                    Slider(value: $gen.guidance, in: 1...8, step: 0.5)
                    Text(String(format: "%.1f", gen.guidance)).monospacedDigit().frame(width: 30)
                }
                TextField("Negative prompt", text: $gen.negative)
                Toggle("Random seed", isOn: $gen.randomSeed)
                TextField("Seed", value: $gen.seed, format: .number).disabled(gen.randomSeed)
                Picker("Model", selection: $gen.tier) {
                    Text("Compact · 7 GB").tag("compact")
                    Text("8-bit · 9 GB").tag("8bit")
                }
                }
            }
        }
        .sheet(isPresented: $showDownload) { DownloadSheet(gen: gen) }
        .formStyle(.grouped)
        .background(OverlayScrollers())
        .disabled(gen.running)
    }
}

struct PreviewView: View {
    @ObservedObject var gen: Generator

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let job = gen.selected, let img = NSImage(contentsOf: job.url) {
                    ZoomableImage(image: img)
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                            Button("Copy image") { copy(img) }
                            Button("Reuse prompt and seed") { gen.prompt = job.prompt; gen.seed = job.seed; gen.randomSeed = false }
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
                                    .help("seed \(job.seed) · \(Int(job.seconds)) s")
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Divider()
            }

            HStack {
                if gen.downloading { ProgressView().controlSize(.small) }
                if gen.running {
                    if gen.totalSteps > 0 {
                        ProgressView(value: Double(gen.step), total: Double(gen.totalSteps)).frame(width: 160)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(gen.status).foregroundStyle(.secondary).lineLimit(1)
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
        if magnification == fitScale { fitToWindow() }  // keep "fit" while the window resizes
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
            // mouse wheel (or ⌘ + trackpad): zoom at the cursor
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            let target = min(max(magnification * factor, fitScale * 0.5), maxMagnification)
            setMagnification(target, centeredAt: contentView.convert(event.locationInWindow, from: nil))
        } else {
            super.scrollWheel(with: event)  // trackpad two-finger pan
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

/// Finds the enclosing NSScrollView and switches it to thin, auto-hiding overlay scrollers,
/// regardless of the system "Show scroll bars" setting.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                var v = self?.superview
                while let view = v, !(view is NSScrollView) { v = view.superview }
                guard let sv = v as? NSScrollView else { return }
                sv.scrollerStyle = .overlay
                sv.autohidesScrollers = true
                sv.verticalScroller?.controlSize = .small
            }
        }
    }
}

struct KnownLora: Identifiable {
    let id: String
    let repo: String
    let file: String
    let steps: Int
    let guidance: Double
    let note: String
}

// ponytail: hardcoded list; move to a JSON file when it grows past a handful
let knownLoras = [
    KnownLora(id: "dmd8", repo: "lodestones/MOSS-Image-SFT-8-steps-dmd", file: "lora.safetensors",
              steps: 8, guidance: 1, note: "8 steps, no CFG, strength 1.0"),
    KnownLora(id: "dmd8-latest", repo: "lodestones/MOSS-Image-SFT-8-steps-dmd", file: "lora_latest.safetensors",
              steps: 8, guidance: 1, note: "newer checkpoint, author suggests strength 0.7"),
]

struct DownloadSheet: View {
    @ObservedObject var gen: Generator
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var file = "lora.safetensors"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download a LoRA from Hugging Face").font(.headline)
            Form {
                TextField("Repository", text: $repo, prompt: Text("user/repo"))
                TextField("File", text: $file)
            }
            .formStyle(.columns)
            Text("Known adapters").font(.subheadline).foregroundStyle(.secondary)
            ForEach(knownLoras) { k in
                HStack {
                    VStack(alignment: .leading) {
                        Text(k.repo + " · " + k.file).font(.body)
                        Text(k.note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Get") {
                        gen.downloadLora(repo: k.repo, file: k.file) {
                            gen.steps = k.steps; gen.guidance = k.guidance
                            if k.file == "lora_latest.safetensors" { gen.enable(gen.loras.first { $0.hasSuffix("__lora_latest.safetensors") } ?? "", scale: 0.7) }
                        }
                        dismiss()
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download") { gen.downloadLora(repo: repo, file: file); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(repo.split(separator: "/").count != 2 || file.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct SettingsView: View {
    @AppStorage("cli") var cli = NSHomeDirectory() + "/moss-mlx/bin/moss-mlx"
    @AppStorage("loraDir") var loraDir = NSHomeDirectory() + "/moss-mlx/loras"
    @AppStorage("outputDir") var outputDir = NSHomeDirectory() + "/Pictures/MOSS Image"

    var body: some View {
        Form {
            TextField("moss-mlx executable", text: $cli)
            TextField("LoRA folder", text: $loraDir)
            TextField("Output folder", text: $outputDir)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
