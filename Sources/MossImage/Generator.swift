import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct Job: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let prompt: String      // as the user typed it, not as sent (no layout JSON, no trigger words)
    let seed: Int
    let seconds: Double
}

/// One queued render: exactly the fields moss-mlx's `--batch` JSONL accepts (Request fields plus `output`).
struct Render: Codable {
    var prompt: String
    var negative_prompt: String
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Double
    var seed: Int
    var uncond_skip_layers: [Int]
    var slg_layers: [Int]
    var slg_scale: Double
    var slg_start: Double
    var slg_stop: Double
    var init_image: String?
    var strength: Double
    var mask: String?
    var mask_feather: Int
    var output: String
}

/// What the user had for a render, merged into its sidecar as "app": the CLI only sees the prompt as sent.
struct AppInfo: Codable {
    var prompt: String
    var layout: MossLayout?
}

@MainActor
final class Generator: ObservableObject {
    @AppStorage("prompt") var prompt = ""
    @AppStorage("negative") var negative = ""
    @AppStorage("width") var width = 1024
    @AppStorage("height") var height = 1024
    @AppStorage("aspect") var aspect = "1:1"        // "custom" keeps width/height as typed
    @AppStorage("megapixels") var megapixels = 1.0  // in units of 1024², 0.25 … 2
    @AppStorage("seed") var seed = 1
    @AppStorage("randomSeed") var randomSeed = true
    @AppStorage("steps") var steps = 8
    @AppStorage("guidance") var guidance = 1.0
    @AppStorage("uncondSkip") var uncondSkip = "22"      // negative-branch block skipping, official default
    @AppStorage("slgLayers") var slgLayers = ""          // skip-layer guidance, off when empty
    @AppStorage("slgScale") var slgScale = 0.0
    @AppStorage("slgStart") var slgStart = 0.0
    @AppStorage("slgStop") var slgStop = 1.0
    @AppStorage("loraTriggers") private var loraTriggersJSON = #"{"Moss-image-gouache-lora.safetensors":"moss_vgouache_style"}"#
    @AppStorage("loraState") private var loraStateJSON = #"{"MOSS-Image-SFT-8-steps-dmd.safetensors":1.0}"#
    @AppStorage("loraDir") var loraDir = NSHomeDirectory() + "/moss-mlx/loras"
    @AppStorage("tier") var tier = "compact"
    @AppStorage("cli") var cli = NSHomeDirectory() + "/moss-mlx/bin/moss-mlx"
    @AppStorage("outputDir") var outputDir = NSHomeDirectory() + "/Pictures/MOSS Image"
    // remote backend (ComfyUI server hosting MOSS-Image); generation runs remotely, everything else stays local
    @AppStorage("backend") var backend = "local"              // local (moss-mlx) | comfy
    @AppStorage("comfyURL") var comfyURL = "http://127.0.0.1:8188"
    @AppStorage("comfyCheckpoint") var comfyCheckpoint = "moss_image_sft_int8_convrot.safetensors"
    @AppStorage("comfyTextEncoder") var comfyTextEncoder = "qwen3.5_9b_w4a8_gptq.safetensors"   // CLIPLoader type moss_image
    @AppStorage("comfyVAE") var comfyVAE = "flux2-vae_small.safetensors"
    @AppStorage("comfyLoras") var comfyLoras = ""             // "dmd.safetensors:1.0, style:0.8" — files the server already has
    // image-to-image
    @AppStorage("initImage") var initImage = ""
    @AppStorage("strength") var strength = 0.6
    @AppStorage("maskFeather") var maskFeather = 12   // px: how far the regenerated patch blends into its surroundings   // image to image: regenerate only inside the layout boxes
    // layout
    @AppStorage("layoutMode") var layoutMode = false
    @AppStorage("layoutJSON") private var layoutJSON = "{}"
    // enhancer
    @AppStorage("enhancerBackend") var enhancerBackend = "local"   // local (mlx-lm) | claude
    @AppStorage("enhancerModel") var enhancerModel = "claude-opus-5-5"
    @AppStorage("localModel") var localModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    // tabs: t2i | i2i, and the view mode inside each
    @AppStorage("tab") var tab = "t2i"
    @AppStorage("layoutOverlay") var layoutOverlay = false   // text to image: draw boxes over the result
    @AppStorage("originalSource") var originalSource = ""
    @AppStorage("historyHidden") var historyHidden = false    // image to image: the picture you started from (results replace initImage)

    @Published var running = false
    @Published var step = 0
    @Published var totalSteps = 0
    @Published var batchDone = 0
    @Published var batchTotal = 0
    @Published var status = ""
    @Published var log = ""
    @Published var jobs: [Job] = []
    @Published var selected: Job?
    @Published var loras: [String] = []
    @Published var downloading = false
    @Published var enhancing = false
    @Published var promptBeforeEnhance: String?
    @Published var pending: [Render] = []
    @Published var preview: NSImage?               // the running render's low-res estimate, decoded once per step
    private var previewPath: String?               // where this batch's CLI rewrites it; deleted when the batch ends
    private var appInfo: [String: AppInfo] = [:]   // by output path, until the image arrives
    var runArgs: [String: [String]] = [:]          // --model/--lora per queued output path

    private var process: Process?
    private var batchStarted = Date()

    // remote ComfyUI state: one websocket per batch, one prompt id at a time, a launch-stable client id
    private var comfyWS: URLSessionWebSocketTask?
    private var comfySession: URLSession?   // the socket's own session; invalidated with the batch
    private var comfyPromptId = ""       // the submit() result; ws events filter on it
    private var comfyInterrupted = false // set by cancel(); pending.isEmpty can't be the signal: takeBatch() drains the queue by design
    let comfyClientId = UUID().uuidString

    init() {
        refreshLoras(); if aspect != "custom" { applyPreset() }; loadHistory()
        layout = (try? JSONDecoder().decode(MossLayout.self, from: Data(layoutJSON.utf8))) ?? MossLayout()
        layoutMode = !layout.items.isEmpty
        pruneMasks(olderThan: 86_400)
        probePreview()
    }

    // MARK: history

    func loadHistory(limit: Int = 80) {
        let dir = URL(fileURLWithPath: outputDir)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []   // new empty folder: empty history
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        let pngs = urls.filter { $0.pathExtension == "png" }.sorted { date($0) > date($1) }.prefix(limit)
        jobs = pngs.map { url in
            let params = sidecar(url)
            return Job(url: url, prompt: restore(url)?.prompt ?? "", seed: params?["seed"] as? Int ?? 0, seconds: 0)
        }
        selected = jobs.first
    }

    /// Move a render and its sidecar to the Trash and drop it from the history; its mask too once nothing else uses it.
    func trash(_ job: Job) {
        let side = job.url.deletingPathExtension().appendingPathExtension("json")
        let mask = sidecar(job.url)?["mask"] as? String
        try? FileManager.default.trashItem(at: job.url, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: side, resultingItemURL: nil)
        if let mask { pruneMasks([mask]) }
        jobs.removeAll { $0.id == job.id }
        if selected == job { selected = jobs.first }
        if initImage == job.url.path { initImage = originalSource == job.url.path ? "" : originalSource }
        if originalSource == job.url.path { originalSource = initImage }
    }

    /// Move masks in `outputDir/masks` to the Trash when no sidecar in the output folder and no queued render
    /// references them. `paths` nil = every mask there (launch: also catches masks of cancelled or failed renders).
    // ponytail: skipped while a batch runs (its renders have no sidecars yet); the launch prune catches those
    func pruneMasks(_ paths: [String]? = nil, olderThan age: TimeInterval = 0) {
        let fm = FileManager.default, dir = URL(fileURLWithPath: outputDir).appendingPathComponent("masks").path
        let candidates = (paths ?? ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }).filter { p in
            URL(fileURLWithPath: p).deletingLastPathComponent().path == dir   // only masks this app wrote
                && ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date).map { -$0.timeIntervalSinceNow >= age } == true
        }
        guard !candidates.isEmpty, !running else { return }
        let sides = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: outputDir), includingPropertiesForKeys: nil)) ?? []
        let used = Set(sides.filter { $0.pathExtension == "json" }.compactMap { sidecar($0)?["mask"] as? String } + pending.compactMap(\.mask))
        for p in candidates where !used.contains(p) { try? fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
    }

    var isBoxEdit: Bool { usingSource && !layout.items.isEmpty }

    func sidecar(_ url: URL) -> [String: Any]? { sidecarRoot(url)?["parameters"] as? [String: Any] }

    func sidecarRoot(_ url: URL) -> [String: Any]? {
        let side = url.deletingPathExtension().appendingPathExtension("json")
        return try? JSONSerialization.jsonObject(with: Data(contentsOf: side)) as? [String: Any]
    }

    /// Adds `info` as "app" to the CLI's sidecar next to `png`, keeping everything the CLI wrote.
    static func merge(_ info: AppInfo, intoSidecarOf png: String) {
        let side = URL(fileURLWithPath: png).deletingPathExtension().appendingPathExtension("json")
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: side))) as? [String: Any],
              let app = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) else { return }
        obj["app"] = app
        try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: side)
    }

    /// What the user had for the image at `url`: the sidecar's "app", or for older sidecars the sent prompt
    /// taken apart again (layout JSON back to boxes, trigger words of known adapters dropped).
    func restore(_ url: URL) -> AppInfo? {
        guard let root = sidecarRoot(url), let p = root["parameters"] as? [String: Any] else { return nil }
        if let app = root["app"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: app),
           let info = try? JSONDecoder().decode(AppInfo.self, from: data) { return info }
        var text = p["prompt"] as? String ?? "", layout: MossLayout?
        if let w = p["width"] as? Int, let h = p["height"] as? Int, let l = MossLayout.fromCompiled(text, width: w, height: h) {
            layout = l.layout; text = l.caption
        }
        // ponytail: an edit's summary is generated, not typed, and its fill boxes are not in the layout; both are lost
        if p["init_image"] is String, text.hasPrefix("The same picture.") { text = "" }
        return AppInfo(prompt: Self.strip(Array(loraTriggers.values), from: text), layout: layout)
    }

    /// Prompt, boxes and seed of `job` back in the sidebar, as the user had them.
    func reuse(_ job: Job) {
        let info = restore(job.url) ?? AppInfo(prompt: job.prompt)
        var l = info.layout ?? MossLayout()
        // the boxes are in that image's pixels; bring them onto the current canvas, as a size change would
        if let p = sidecar(job.url), let w = p["width"] as? Int, let h = p["height"] as? Int, w > 0, h > 0 {
            l = Self.scaled(l, Double(width) / Double(w), Double(height) / Double(h))
        }
        let before = layout
        prompt = info.prompt; layout = l; recordUndo(before); seed = job.seed; randomSeed = false
    }

    // MARK: LoRA

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

    func enable(_ file: String, scale: Double) { var st = loraState; st[file] = scale; loraState = st }

    func refreshLoras() {
        try? FileManager.default.createDirectory(atPath: loraDir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: loraDir)) ?? []
        loras = files.filter { $0.hasSuffix(".safetensors") }.sorted()
        loraState = loraState.filter { loras.contains($0.key) }
    }

    /// Move an adapter to the Trash and forget its scale and trigger word.
    func trashLora(_ file: String) {
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: loraDir).appendingPathComponent(file), resultingItemURL: nil) }
        catch { status = "Could not move \(file) to the Trash: \(error.localizedDescription)"; return }
        var t = loraTriggers; t[file] = nil; loraTriggers = t
        var st = loraState; st[file] = nil; loraState = st
        refreshLoras()
        status = "Moved \(file) to the Trash"
    }

    func importLora(_ url: URL) {
        let dest = URL(fileURLWithPath: loraDir).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest); refreshLoras(); enable(dest.lastPathComponent, scale: 1) }
        catch { status = "Import failed: \(error.localizedDescription)" }
    }

    var python: String { URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("python").path }

    /// Download `file` from a Hugging Face repo with the venv's huggingface_hub, into the library.
    func downloadLora(repo: String, file: String, then: (() -> Void)? = nil) {
        guard !downloading else { return }
        let name = repo.replacingOccurrences(of: "/", with: "__") + (file == "lora.safetensors" ? "" : "__" + file.replacingOccurrences(of: ".safetensors", with: "")) + ".safetensors"
        let dest = URL(fileURLWithPath: loraDir).appendingPathComponent(name)
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

    // MARK: prompt

    /// Prompt as sent: trigger words of enabled adapters prepended (unless already present), trigger words of
    /// disabled adapters removed even if typed by hand.
    var effectivePrompt: String {
        let text = Self.strip(loras.filter { loraState[$0] == nil }.compactMap { loraTriggers[$0] }, from: prompt)
        let words = loras.filter { loraState[$0] != nil }.compactMap { loraTriggers[$0] }
            .filter { !text.localizedCaseInsensitiveContains($0) }
        return (words + [text]).joined(separator: ", ")
    }

    /// `text` without `words`, case-insensitive, along with the comma that joined each one.
    static func strip(_ words: [String], from text: String) -> String {
        var text = text
        for word in words {
            let pattern = "(?i)\\s*,?\\s*" + NSRegularExpression.escapedPattern(for: word) + "\\s*,?\\s*"
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decoded once from `layoutJSON` at init; every change is written back.
    // ponytail: encodes + writes UserDefaults on every change (each drag step, a few µs for a handful of boxes); debounce if layouts grow large
    @Published var layout = MossLayout() {
        didSet {
            layoutJSON = String(decoding: (try? JSONEncoder().encode(layout)) ?? Data("{}".utf8), as: UTF8.self)
            layoutMode = !layout.items.isEmpty   // boxes exist = layout is sent; no separate switch
        }
    }

    /// Boxes that are too small to render at the current output size (under 40 px tall, about two latent patches).
    var tinyBoxes: [LayoutItem] { layout.items.filter { !$0.isFill && ($0.rect.height < 40 || $0.rect.width < 40) } }

    func item(_ id: UUID) -> Binding<LayoutItem> {
        Binding(get: { self.layout.items.first { $0.id == id } ?? LayoutItem(x0: 0, y0: 0, x1: 0, y1: 0) },
                set: { v in var l = self.layout; if let i = l.items.firstIndex(where: { $0.id == id }) { l.items[i] = v; self.layout = l } })
    }

    // ponytail: layout undo is a snapshot stack here, not the window's UndoManager: Enhance and the sidebar's Clear boxes
    // edit the layout outside the canvas, and text views keep the window's stack to themselves. Layout only, last 50 steps.
    private var undoStack: [MossLayout] = [], redoStack: [MossLayout] = [], undoKey: String?
    /// Record `before` as one undo step if the layout has changed since. Edits in a row with the same `coalesce` key
    /// (typing in one field, a run of arrow-key nudges) share one step.
    func recordUndo(_ before: MossLayout, coalesce key: String? = nil) {
        guard before != layout else { return }
        if key == nil || key != undoKey { undoStack.append(before); if undoStack.count > 50 { undoStack.removeFirst() } }
        undoKey = key; redoStack = []
    }
    func undoLayout() { guard let l = undoStack.popLast() else { return }; redoStack.append(layout); undoKey = nil; layout = l }
    func redoLayout() { guard let l = redoStack.popLast() else { return }; undoStack.append(layout); undoKey = nil; layout = l }

    func setSource(_ path: String) {
        initImage = path; originalSource = path
        fitSource()
    }

    /// Match the working image's aspect at the current pixel budget, so nothing is cropped. Size only:
    /// initImage and originalSource stay as they are.
    private func fitSource() {
        guard !initImage.isEmpty, let rep = NSImageRep(contentsOfFile: initImage), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return }
        let ratio = Double(rep.pixelsWide) / Double(rep.pixelsHigh)
        let h = (megapixels * 1024 * 1024 / ratio).squareRoot()
        resize(max(256, Int((h * ratio / 16).rounded()) * 16), max(256, Int((h / 16).rounded()) * 16))
        aspect = "source"
    }

    /// Re-derive width/height from the source image when the pixel budget changes.
    func applySourceAspect() {
        guard aspect == "source" else { return }
        fitSource()
    }

    /// The text handed to the model: a caption, or the compiled layout JSON when layout mode is on.
    var sentPrompt: String {
        guard layoutMode, !layout.items.isEmpty else { return effectivePrompt }
        var l = layout
        if usingSource {  // an edit: boxes without a caption inherit the look of what is around them
            for i in l.items.indices where !l.items[i].isFill && l.items[i].caption.trimmingCharacters(in: .whitespaces).isEmpty {
                l.items[i].caption = l.items[i].label == "text"
                    ? "same font, size, weight and colour as the text next to it"
                    : "matching the style, lighting and colours of the surrounding picture"
            }
        }
        // For an edit the prompt is not used: an instruction like "change X to Y" misleads the model, and the
        // masked surroundings already carry the style. The words to render live in the boxes. Fill boxes add
        // what their area should show (empty = plain background) to the summary.
        var caption = effectivePrompt
        if usingSource {
            let fills = l.items.filter(\.isFill).map { $0.caption.trimmingCharacters(in: .whitespaces) }
            let wants = fills.filter { !$0.isEmpty }
            caption = "The same picture." + (fills.count > wants.count ? " The marked area shows only the plain background that surrounds it." : "")
                + wants.map { " The marked area shows \($0)." }.joined()
        }
        return l.compiled(caption: caption, width: width, height: height)
    }

    // MARK: size

    static let aspects: [(String, Double)] = [("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4), ("3:2", 1.5), ("2:3", 2.0 / 3),
                                             ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("21:9", 21.0 / 9)]

    func applyPreset() {
        if aspect == "source" { applySourceAspect(); return }
        guard let ratio = Self.aspects.first(where: { $0.0 == aspect })?.1 else { return }
        let pixels = megapixels * 1024 * 1024  // so 1 MP at 1:1 is exactly 1024²
        let h = (pixels / ratio).squareRoot()
        resize(Int((h * ratio / 16).rounded()) * 16, Int((h / 16).rounded()) * 16)
    }

    /// Set the output size; layout boxes scale with it so they keep covering the same part of the picture.
    func resize(_ w: Int, _ h: Int) {
        // ponytail: a side under 16 px is a half-typed value, not a canvas; boxes keep their pixels instead of collapsing
        if min(width, height, w, h) >= 16, w != width || h != height {
            let sx = Double(w) / Double(width), sy = Double(h) / Double(height)
            if !layout.items.isEmpty { layout = Self.scaled(layout, sx, sy) }
            // undo steps follow too, so ⌘Z after a size change doesn't bring back boxes in the old canvas's pixels
            undoStack = undoStack.map { Self.scaled($0, sx, sy) }; redoStack = redoStack.map { Self.scaled($0, sx, sy) }
        }
        width = w; height = h
    }

    static func scaled(_ layout: MossLayout, _ sx: Double, _ sy: Double) -> MossLayout {
        var l = layout
        for i in l.items.indices { l.items[i].x0 *= sx; l.items[i].x1 *= sx; l.items[i].y0 *= sy; l.items[i].y1 *= sy }
        return l
    }

    // MARK: queue

    static func layers(_ text: String) -> [Int] { text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) } }

    func outputURL(seed: Int) -> URL {
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("moss-\(stamp)-\(seed)-\(Int.random(in: 100...999)).png")
    }

    /// A render from the current sidebar state.
    func currentRender(seed: Int? = nil, width: Int? = nil, height: Int? = nil) -> Render {
        let s = seed ?? (randomSeed ? Int.random(in: 1...999_999) : self.seed)
        let w = width ?? self.width, h = height ?? self.height
        return Render(prompt: sentPrompt, negative_prompt: negative, width: max(256, w / 16 * 16), height: max(256, h / 16 * 16),
                      steps: steps, guidance: guidance, seed: s,
                      uncond_skip_layers: Self.layers(uncondSkip), slg_layers: Self.layers(slgLayers),
                      slg_scale: slgScale, slg_start: slgStart, slg_stop: slgStop,
                      init_image: usingSource ? initImage : nil, strength: usingSource ? strength : 1,
                      mask: usingSource ? effectiveMask : nil, mask_feather: maskFeather,
                      output: outputURL(seed: s).path)
    }

    var usingSource: Bool { tab == "i2i" && !initImage.isEmpty }

    /// The mask sent with an image-to-image render: the layout boxes, if any. No boxes = the whole image.
    var effectiveMask: String? { layout.items.isEmpty ? nil : writeMask(boxStrokes) }

    var effectiveMaskExists: Bool { !layout.items.isEmpty }

    /// One closed rectangle per layout box, padded 8 px so glyph edges are covered.
    var boxStrokes: [[CGPoint]] {
        layout.items.map { it in
            let r = it.rect.insetBy(dx: -8, dy: -8)
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        }
    }

    /// Render closed rectangles (output-pixel coordinates) to a white-on-black PNG at output size. Returns the path.
    func writeMask(_ strokes: [[CGPoint]]) -> String? {
        guard !strokes.isEmpty else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        let renderer = ImageRenderer(content: ZStack { Color.black; MaskStrokes(strokes: strokes, scale: 1, color: .white) }.frame(width: W, height: H))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        let dir = URL(fileURLWithPath: outputDir).appendingPathComponent("masks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mask-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
        return url.path
    }

    func generate() {
        if usingSource, aspect != "source" { aspect = "source"; applyPreset() }   // edits always keep the source's aspect
        layoutMode = !layout.items.isEmpty
        if !tinyBoxes.isEmpty, layoutMode {
            status = "\(tinyBoxes.count) box(es) under 40 px at \(width)×\(height). Raise Pixels in the sidebar or draw bigger boxes; text that small cannot be rendered."
            return
        }
        let editWithBoxes = usingSource && layoutMode && !layout.items.isEmpty
        guard editWithBoxes || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Write a prompt first."; return }
        if tab == "i2i", initImage.isEmpty { status = "Choose a source image first, or switch to Text to image."; return }
        if layoutMode, layout.items.contains(where: { $0.label == "text" && $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            status = "A text box has no visible text. Type the words to render in its Visible text field (Layout toggle, select the box)."; return
        }
        if randomSeed { seed = Int.random(in: 1...999_999) }
        enqueue([currentRender(seed: seed)])
    }

    /// Same settings as `job`, new seeds.
    func variations(of job: Job, count: Int) {
        guard var base = render(from: job) else { return }
        enqueue((0..<count).map { _ in base.seed = Int.random(in: 1...999_999); base.output = outputURL(seed: base.seed).path; return base }, from: job)
    }

    /// Same prompt and seed as `job`, re-rendered at `megapixels`.
    func rerender(_ job: Job, megapixels mp: Double) {
        guard var r = render(from: job) else { return }
        let ratio = Double(r.width) / Double(r.height)
        let h = (mp * 1024 * 1024 / ratio).squareRoot()
        r.width = Int((h * ratio / 16).rounded()) * 16; r.height = Int((h / 16).rounded()) * 16
        r.output = outputURL(seed: r.seed).path
        enqueue([r], from: job)
    }

    /// Rebuild a Render from a finished image's sidecar; falls back to current settings for anything missing.
    func render(from job: Job) -> Render? {
        guard let p = sidecar(job.url) else { return nil }
        let s = p["seed"] as? Int ?? job.seed   // not currentRender(): in an edit it writes a mask PNG nobody uses
        return Render(prompt: p["prompt"] as? String ?? sentPrompt, negative_prompt: p["negative_prompt"] as? String ?? "",
                      width: p["width"] as? Int ?? width, height: p["height"] as? Int ?? height,
                      steps: p["steps"] as? Int ?? steps, guidance: p["cfg"] as? Double ?? guidance, seed: s,
                      uncond_skip_layers: p["uncond_skip_layers"] as? [Int] ?? Self.layers(uncondSkip),
                      slg_layers: p["slg_layers"] as? [Int] ?? Self.layers(slgLayers), slg_scale: p["slg_scale"] as? Double ?? slgScale,
                      slg_start: p["slg_start"] as? Double ?? slgStart, slg_stop: p["slg_stop"] as? Double ?? slgStop,
                      init_image: p["init_image"] as? String, strength: p["strength"] as? Double ?? 1, mask: p["mask"] as? String,
                      mask_feather: p["mask_feather"] as? Int ?? maskFeather, output: outputURL(seed: s).path)
    }

    /// `--model` and `--lora` args: the sidebar's, or for a re-render the adapters recorded in `job`'s sidecar.
    func modelArgs(_ job: Job? = nil) -> [String] {
        // ponytail: the sidecar records no tier, so a re-render uses the current one
        let specs = job.flatMap { sidecarRoot($0.url)?["loras"] as? [String] }
            ?? loras.filter { loraState[$0] != nil }.map { loraDir + "/" + $0 + String(format: ":%.2f", loraState[$0]!) }
        return ["--model", tier] + specs.flatMap { ["--lora", $0] }
    }

    /// Pops the leading run of `pending` that shares one model/LoRA set: one process takes one set; the rest
    /// waits for the next batch.
    func takeBatch() -> (renders: [Render], args: [String]) {
        let now = modelArgs()
        let args = runArgs[pending[0].output] ?? now
        let batch = Array(pending.prefix { (runArgs[$0.output] ?? now) == args })
        pending.removeFirst(batch.count)
        for r in batch { runArgs[r.output] = nil }
        return (batch, args)
    }

    /// Queue `renders`. What the user had (the sidecar's "app") comes from `job` for re-renders, else the sidebar.
    func enqueue(_ renders: [Render], from job: Job? = nil) {
        let info = job.flatMap { restore($0.url) } ?? AppInfo(prompt: prompt, layout: layout.items.isEmpty ? nil : layout)
        let args = modelArgs(job)
        for r in renders { appInfo[r.output] = info; runArgs[r.output] = args }
        pending.append(contentsOf: renders)
        if !running { startBatch() }
    }

    /// Runs the leading renders in `pending` that share a LoRA set as one moss-mlx --batch process, so the
    /// model loads once per batch.
    private func startBatch() {
        guard !pending.isEmpty else { return }
        let (batch, modelArgs) = takeBatch()
        if backend == "comfy" { startComfy(batch: batch, modelArgs: modelArgs); return }
        let jobsFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moss-jobs-\(UUID().uuidString).jsonl")
        let enc = JSONEncoder()
        let lines = batch.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        do { try lines.joined(separator: "\n").write(to: jobsFile, atomically: true, encoding: .utf8) }
        catch { status = "Could not write job file: \(error.localizedDescription)"; return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["--batch", jobsFile.path] + modelArgs
        probePreview()   // a changed CLI path: this batch runs without, the next one knows
        let previewFile = Self.previewSupport[cli] == true ? NSTemporaryDirectory() + "moss-preview-\(UUID().uuidString).png" : nil
        if let previewFile { p.arguments! += ["--preview", previewFile] }
        previewPath = previewFile; preview = nil
        let err = Pipe(), out = Pipe()
        p.standardError = err; p.standardOutput = out
        running = true; step = 0; totalSteps = 0; batchDone = 0; batchTotal = batch.count; log = ""
        status = batch.count > 1 ? "Encoding prompts…" : "Encoding prompt…"
        batchStarted = Date()
        let byOutput = Dictionary(uniqueKeysWithValues: batch.map { ($0.output, $0) })
        let infos = batch.reduce(into: [String: AppInfo]()) { $0[$1.output] = appInfo.removeValue(forKey: $1.output) }

        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.consume(text) }
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                for line in text.split(separator: "\n") {
                    let path = String(line).trimmingCharacters(in: .whitespaces)
                    guard let r = byOutput[path], FileManager.default.fileExists(atPath: path) else { continue }
                    if let info = infos[path] { Self.merge(info, intoSidecarOf: path) }
                    let job = Job(url: URL(fileURLWithPath: path), prompt: infos[path]?.prompt ?? r.prompt, seed: r.seed,
                                  seconds: Date().timeIntervalSince(self.batchStarted))
                    self.jobs.insert(job, at: 0); self.selected = job; self.preview = nil
                    if r.init_image != nil, self.tab == "i2i" { self.initImage = path }  // the result becomes the working image; boxes and mask stay
                    self.batchDone += 1; self.batchStarted = Date()
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: jobsFile)
            if let previewFile { try? FileManager.default.removeItem(atPath: previewFile) }
            Task { @MainActor in
                guard let self else { return }
                self.running = false; self.process = nil; self.preview = nil; self.previewPath = nil
                if proc.terminationReason == .uncaughtSignal {
                    self.status = "Cancelled"; self.pending = []
                } else if proc.terminationStatus != 0 {
                    self.status = "Failed (exit \(proc.terminationStatus)): " + self.lastErrorLine; self.pending = []
                } else {
                    self.status = self.batchTotal > 1 ? "Done, \(self.batchDone) images" : "Done"
                    self.startBatch()  // anything queued while this batch ran
                }
            }
        }
        do { try p.run(); process = p } catch { running = false; status = "Could not start \(cli): \(error.localizedDescription)" }
    }

    // MARK: remote ComfyUI backend

    /// Same set of renders, executed on the ComfyUI server: init/mask PNGs are uploaded, one API-format graph per
    /// render is submitted in order, outputs land at the render's local output path with a CLI-shaped sidecar.
    /// Progress and step counts come from the server's WebSocket; images from /history.
    private func startComfy(batch: [Render], modelArgs _: [String]) {
        let client = ComfyClient(base: comfyBase, token: Keychain.read("comfy-token") ?? "")
        let loras = Self.remoteLoRAList(comfyLoras, loras: loras, loraState: loraState)   // the sidebar's set, translated
        running = true; step = 0; totalSteps = 0; batchDone = 0; batchTotal = batch.count; log = ""
        comfyInterrupted = false
        preview = nil; previewPath = nil
        batchStarted = Date(); stepClock = Date()
        status = "Connecting to ComfyUI…"
        let infos = batch.reduce(into: [String: AppInfo]()) { $0[$1.output] = appInfo.removeValue(forKey: $1.output) }
        let ws = attachComfyWS()
        Task { @MainActor [weak self] in
            defer {
                ws?.cancel(with: .normalClosure, reason: nil)
                Task { @MainActor [weak self] in
                    self?.comfySession?.finishTasksAndInvalidate()   // a batch's session is single-use
                    self?.comfySession = nil
                    self?.running = false; self?.comfyWS = nil
                    self?.startBatch()   // anything queued while this batch ran
                }
            }
            guard let self else { return }
            do {
                _ = try await client.ping()   // fail fast on a wrong address or blocked port
                var uploaded = UploadedTracker(client: client)   // local path → server name, one upload per file per batch
                for r in batch {
                    if self.comfyInterrupted { self.status = "Cancelled"; return }
                    var sent = r
                    sent.init_image = try await uploaded.image(r.init_image, tag: "in-")
                    sent.mask = try await uploaded.mask(r.mask, feather: r.mask_feather)
                    let graph = ComfyGraph.build(sent, loras: loras, checkpoint: self.comfyCheckpoint, textEncoder: self.comfyTextEncoder, vae: self.comfyVAE)
                    if let problem = ComfyGraph.validate(graph).first { self.status = "Not sent: \(problem)"; return }
                    self.step = 0; self.totalSteps = 0
                    self.status = self.batchTotal > 1 ? "Image \(self.batchDone + 1) of \(self.batchTotal) · queued" : "Queued on the server…"
                    let id = try await client.submit(graph, clientId: self.comfyClientId)
                    self.comfyPromptId = id   // the WebSocket progress filter now applies
                    var outputs: [ComfyClient.Output] = []
                    let deadline = Date().addingTimeInterval(Self.remoteDeadline)   // generous: the first render may download 12 GB before anything arrives
                    while outputs.isEmpty, Date() < deadline {
                        try await Task.sleep(nanoseconds: 1_200_000_000)
                        if self.comfyInterrupted { self.status = "Cancelled"; return }
                        do { outputs = try await client.outputs(id) }
                        catch {
                            // an errored prompt fails fast here; polling would otherwise outlive it
                            self.status = "ComfyUI: " + ((error as? ComfyError)?.errorDescription ?? error.localizedDescription)
                            self.pending = []
                            return
                        }
                    }
                    self.comfyPromptId = ""
                    guard let image = outputs.first else { self.status = "ComfyUI did not return an image for seed \(r.seed)."; return }
                    let data = try await client.fetch(image)
                    try data.write(to: URL(fileURLWithPath: r.output))
                    Self.writeSidecar(r, loras: loras)   // `r`: the local init/mask paths stay in the history
                    if let info = infos[r.output] { Self.merge(info, intoSidecarOf: r.output) }
                    let job = Job(url: URL(fileURLWithPath: r.output), prompt: infos[r.output]?.prompt ?? r.prompt, seed: r.seed,
                                  seconds: Date().timeIntervalSince(self.batchStarted))
                    self.jobs.insert(job, at: 0); self.selected = job; self.preview = nil
                    if r.init_image != nil, self.tab == "i2i" { self.initImage = r.output }   // the result becomes the working image
                    self.batchDone += 1; self.batchStarted = Date(); self.stepClock = Date()
                }
                if batchDone == batch.count { status = batchTotal > 1 ? "Done, \(batchDone) images" : "Done" }
            } catch is CancellationError {
            } catch {
                self.status = "ComfyUI: " + ((error as? ComfyError)?.errorDescription ?? error.localizedDescription)
                self.pending = []
            }
        }
    }

    /// "dmd.safetensors:1.0, style:0.8" → ordered specs; missing scale = 1.0
    static func comfyLoRAList(_ text: String) -> [ComfyGraph.LoRA] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" }).compactMap { piece in
            let name = piece.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.contains(".safetensors") else { return nil }
            if let colon = name.firstIndex(of: ":"), let scale = Double(name[name.index(after: colon)...]) {
                return ComfyGraph.LoRA(name: String(name[..<colon]), scale: scale)
            }
            return ComfyGraph.LoRA(name: name, scale: 1)
        }
    }

    /// Remote adapters. The sidebar's active set (same order and scales as the local `modelArgs`) is authoritative;
    /// the settings text is a translation layer:
    ///   "local=server.safetensors:0.8"  send the server's `server.safetensors` while the local one is enabled,
    ///                                    at 0.8 instead of the sidebar's scale
    ///   "server.safetensors:0.9"        an explicit always-on remote adapter (a server-side style, say)
    ///   local names without a mapping   go to the server under the same filename
    static func remoteLoRAList(_ text: String, loras: [String], loraState: [String: Double]) -> [ComfyGraph.LoRA] {
        var mapped: [String: ComfyGraph.LoRA] = [:]   // local file → server adapter
        var extras: [ComfyGraph.LoRA] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let entry = piece.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            var local = "", spec = entry
            if let eq = entry.firstIndex(of: "=") {
                local = String(entry[..<eq]).trimmingCharacters(in: .whitespaces)
                spec = String(entry[entry.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
            guard let lora = Self.comfyLoRAList(spec).first else { continue }
            if local.isEmpty { extras.append(lora) } else if local.hasSuffix(".safetensors") { mapped[local] = lora }
        }
        var out: [ComfyGraph.LoRA] = []
        for file in loras where (loraState[file] ?? 0) > 0 {   // enabled sidebar adapters, library order
            out.append(mapped[file] ?? ComfyGraph.LoRA(name: file, scale: loraState[file] ?? 1))
        }
        return out + extras
    }

    /// Generous: a first remote render may download the 12 GB model before the first image appears.
    static let remoteDeadline: TimeInterval = 1800

    /// A sidecar in the CLI's shape so history, reuse and re-render treat remote images like local ones.
    /// init/mask stay the local paths the render came from; loras lists the *server-side* adapters.
    static func writeSidecar(_ r: Render, loras: [ComfyGraph.LoRA]) {
        var p: [String: Any] = ["prompt": r.prompt, "negative_prompt": r.negative_prompt, "width": r.width, "height": r.height,
                                "steps": r.steps, "cfg": r.guidance, "seed": r.seed,
                                "uncond_skip_layers": r.uncond_skip_layers, "slg_layers": r.slg_layers,
                                "slg_scale": r.slg_scale, "slg_start": r.slg_start, "slg_stop": r.slg_stop,
                                "strength": r.strength, "mask_feather": r.mask_feather]
        if let m = r.mask { p["mask"] = m }
        if let i = r.init_image { p["init_image"] = i }
        let root: [String: Any] = ["parameters": p,
                                   "loras": loras.map { "\($0.name):" + String(format: "%.2f", $0.scale) }]
        let side = URL(fileURLWithPath: r.output).deletingPathExtension().appendingPathExtension("json")
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: side)
        }
    }

    /// WebSocket progress for this app's prompts (clientId routes our events to this socket). The socket lives on
    /// its own URLSession, not the shared one: a 101-upgraded connection and data requests in one pool have been
    /// observed to starve each other ("network connection was lost").
    @discardableResult
    private func attachComfyWS() -> URLSessionWebSocketTask? {
        var c = URLComponents(url: comfyBase.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        c.queryItems = [.init(name: "clientId", value: comfyClientId)]
        guard let url = c.url else { return nil }
        let session = URLSession(configuration: .default)
        comfySession = session
        let ws = session.webSocketTask(with: url)
        ws.resume()
        comfyWS = ws
        receiveComfy(ws)
        return ws
    }

    private func receiveComfy(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.comfyWS === ws, self.running else { return }
                switch result {
                case .success(.string(let text)): self.consumeComfy(Data(text.utf8), ws)   // text frames (the common kind)
                case .success(.data(let data)): self.consumeComfy(data, ws)                // binary frames
                default:
                    return      // cancelled, failed or closed (e.g. no ws on the server): polling still completes the batch
                }
            }
        }
    }

    private func consumeComfy(_ data: Data, _ ws: URLSessionWebSocketTask) {
        if let event = ComfyEvents.parse(data), Self.eventID(event) == comfyPromptId {
            switch event {
            case .executing(_, nil): status = "Saving…"
            case .progress(_, let step, let of):
                self.step = step; totalSteps = of
                status = (batchTotal > 1 ? "Image \(batchDone + 1) of \(batchTotal) · " : "") + "step \(step) of \(of)"
                if let left = Self.eta(elapsed: Date().timeIntervalSince(stepClock), step: step, steps: of,
                                       after: batchTotal - batchDone - 1) { status += " · " + left }
            case .executing: break
            case .error:
                status = "The server reported an error for this render."
                pending = []
            }
        }
        receiveComfy(ws)   // keep reading the stream while the batch runs
    }

    static func eventID(_ e: ComfyEvents.Event) -> String? {
        switch e { case .executing(let id, _), .progress(let id, _, _), .error(let id): return id }
    }

    private var lastErrorLine: String {
        log.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last { !$0.hasPrefix("step ") && !$0.isEmpty }.map(String.init) ?? "see log"
    }

    func cancel() {
        pending = []
        process?.terminate()
        if backend == "comfy" {
            comfyInterrupted = true   // the runner sees this and stops before sending more prompts
            let base = comfyBase, token = Keychain.read("comfy-token") ?? ""
            Task.detached { await ComfyClient(base: base, token: token).interrupt() }   // stops the running prompt remotely
        }
    }

    var comfyBase: URL { URL(string: comfyURL.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://127.0.0.1:8188")! }

    /// local path → server upload name, deduplicated inside one batch; masks always go through featherMask
    /// (binarize + optional feather) so what the server sees matches what the local CLI would feed itself
    struct UploadedTracker {
        let client: ComfyClient
        var names: [String: String] = [:]

        mutating func image(_ key: String?, tag: String) async throws -> String? {
            guard let key else { return nil }
            if let name = names[key] { return name }
            let name = tag + UUID().uuidString + ".png"
            names[key] = try await client.upload(pngAt: key, as: name)
            return names[key]
        }

        mutating func mask(_ key: String?, feather: Int) async throws -> String? {
            guard let key else { return nil }
            if let name = names[key] { return name }
            let name = "ms-" + UUID().uuidString + ".png"
            let local = Generator.featherMask(key, radius: feather)
            defer { if local != key { try? FileManager.default.removeItem(atPath: local) } }
            names[key] = try await client.upload(pngAt: local, as: name)
            return names[key]
        }
    }

    /// Feathering with the local CLI's exact contract (moss_image_mlx/pipeline.py load_mask): binarize at 50 %,
    /// dilate the painted region by `radius` px (PIL MaxFilter 2·radius+1), then blur at half the radius —
    /// painted interiors stay fully regenerated and only the dilated edge ramps to zero. radius 0 still
    /// binarizes (the CLI does), which is what keeps antialiased stroke edges from diluting SetLatentNoiseMask.
    nonisolated static func featherMask(_ path: String, radius: Int) -> String {
        let dst = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moss-feather-\(UUID().uuidString).png")
        guard let src = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return path }
        let clamp: [String: Any] = ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)]   // actual key names (probed, not docs)
        // the 50% binarize must drive every channel from R: the unspecified G/B/A vectors default to
        // identity, which would leak G=B=1 into black pixels and misread the mask on any but the red channel
        var image = src
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1000, y: 0, z: 0, w: 0),
                                                          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                          "inputBiasVector": CIVector(x: -499, y: -499, z: -499, w: 0)])
            .applyingFilter("CIColorClamp", parameters: clamp)   // the ≥ 128 binarize
        if radius > 0 {
            image = image
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: Float(radius)])   // MaxFilter
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Float(radius) / 2])    // CoreImage σ ≈ radius/2 = PIL's blur(feather/2)
                .applyingFilter("CIColorClamp", parameters: clamp)
        }
        guard let cg = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false]).createCGImage(image, from: src.extent),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return path }
        try? data.write(to: dst)
        return dst.path
    }

    /// Per CLI path: does it take `--preview`? An install without patch 0006 rejects the flag, so it is only sent
    /// once `--help` (~0.5 s, off the main thread) has listed it. Unknown counts as no.
    // ponytail: probed once per path and launch; after setup.sh upgrades the CLI, previews start on the next launch
    static var previewSupport: [String: Bool] = [:]

    func probePreview() {
        let cli = cli
        guard Self.previewSupport[cli] == nil else { return }
        Self.previewSupport[cli] = false
        Task.detached {
            let ok = Self.supportsPreview(cli)
            await MainActor.run { Self.previewSupport[cli] = ok }
        }
    }

    nonisolated static func supportsPreview(_ cli: String) -> Bool {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: cli); p.arguments = ["--help"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let help = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 && help.contains("--preview")
    }

    private func consume(_ text: String) {
        log += text
        for chunk in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            if let m = chunk.firstMatch(of: #/step (\d+)\/(\d+)/#) {
                step = Int(m.1) ?? 0; totalSteps = Int(m.2) ?? 0
                if step == 1 { stepClock = Date() }
                let which = batchTotal > 1 ? "Image \(batchDone + 1) of \(batchTotal) · " : ""
                status = which + "step \(step) of \(totalSteps)"
                // the CLI rewrote the file (atomically) just before printing this line
                if let previewPath, let data = try? Data(contentsOf: URL(fileURLWithPath: previewPath)) { preview = NSImage(data: data) }
                if let left = Self.eta(elapsed: Date().timeIntervalSince(stepClock), step: step, steps: totalSteps,
                                       after: batchTotal - batchDone - 1) { status += " · " + left }
            } else if chunk.contains("fetching") {
                status = "Loading model…"   // the CLI prints this every run; the Hub only downloads on the first
            } else if chunk.contains("Fetching"), chunk.contains("s/it") {
                status = "Downloading model, first run only…"   // slow per-file progress means real transfer
            }
        }
    }

    private var stepClock = Date()   // when the current image reported step 1

    /// "~25 s left", plus "~2 min for all" when `after` more images follow. `elapsed` runs from step 1, so prompt
    /// encoding and the slow first step don't skew the rate. nil until step 2.
    // ponytail: later images assumed to have the same step count, VAE decode (~5 %) not counted
    static func eta(elapsed: Double, step: Int, steps: Int, after: Int) -> String? {
        guard step > 1, step <= steps, elapsed > 0 else { return nil }
        let rate = elapsed / Double(step - 1), image = rate * Double(steps - step)
        func text(_ s: Double) -> String { s < 59.5 ? "~\(Int(s.rounded())) s" : "~\(Int((s / 60).rounded())) min" }
        return text(image) + " left" + (after > 0 ? " · " + text(image + rate * Double(steps * after)) + " for all" : "")
    }

    /// Images still to come: the rest of the running batch plus the queue. The Dock badge.
    var remaining: Int { (running ? max(0, batchTotal - batchDone) : 0) + pending.count }

    // MARK: enhancer (local mlx model or Claude API)

    func enhance() {
        guard !enhancing, !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let want = layoutMode ? "layout" : "caption"
        let idea = prompt, w = width, h = height
        let backend = enhancerBackend, model = enhancerModel, local = localModel, py = python
        var key = ""
        if backend == "claude" {
            guard let k = Keychain.read("anthropic-api-key"), !k.isEmpty else { status = "Add an Anthropic API key in Settings (⌘,), or switch Enhance to the local model."; return }
            key = k
        }
        enhancing = true; status = backend == "claude" ? "Enhancing with Claude…" : "Enhancing with \(local.split(separator: "/").last ?? "")… (first run downloads the model)"
        Task {
            do {
                let text = backend == "claude"
                    ? try await Enhancer.claude(apiKey: key, model: model, idea: idea, want: want, width: w, height: h)
                    : try await Enhancer.local(python: py, model: local, idea: idea, want: want, width: w, height: h)
                self.promptBeforeEnhance = idea
                if want == "layout", let draft = MossLayout.fromDraft(text) {
                    let before = self.layout; self.layout = draft.layout; self.recordUndo(before); self.prompt = draft.caption
                    self.status = "Layout with \(draft.layout.items.count) boxes. Switch to the Layout view to adjust."
                } else if want == "layout" {
                    self.status = "The model did not return a usable layout. Try again or draw boxes by hand."
                } else {
                    self.prompt = Enhancer.caption(from: text); self.status = "Prompt enhanced. Revert restores the original."
                }
            } catch {
                self.status = "Enhance failed: \(error.localizedDescription)"
            }
            self.enhancing = false
        }
    }

    func revertEnhance() { if let p = promptBeforeEnhance { prompt = p; promptBeforeEnhance = nil } }
}

enum Keychain {
    static let service = "dk.vonranda.mossimage"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
