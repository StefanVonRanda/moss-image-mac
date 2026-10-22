import SwiftUI
import AppKit

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
    var tier: String? = nil   // --model; nil in sidecars from before it was recorded
}

/// Outpainting: how far to extend each side, as a fraction of the image's width (left, right) or height (top, bottom).
struct Pad: Equatable { var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0 }

@MainActor
final class Generator: ObservableObject {
    @AppStorage("prompt") var prompt = ""
    @AppStorage("recentPrompts") private var recentPromptsJSON = "[]"   // as typed, newest first
    @AppStorage("negative") var negative = ""
    @AppStorage("width") var width = 1024
    @AppStorage("height") var height = 1024
    @AppStorage("aspect") var aspect = "1:1" {      // "custom" keeps width/height as typed; "source" is Image-only
        didSet { if aspect != "source" { textAspect = aspect } }
    }
    @AppStorage("textAspect") var textAspect = "1:1"   // the last aspect picked by hand, restored on the Text tab
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
    @AppStorage("tab") var tab = "t2i" {
        didSet { if tab == "t2i" { pad = Pad() }; if tab == "t2i", aspect == "source" { aspect = textAspect; applyPreset() } }
    }
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
    @Published var comparing = false               // Space held: see canvasSource
    /// Outpainting: how far to extend the working image on each side. Changing it re-derives the output size.
    // ponytail: not persisted; a relaunch starts unextended
    @Published var pad = Pad() { didSet { if pad != oldValue, usingSource { fitSource() } } }
    /// Where the working image sits on the canvas while it is extended (output pixels); nil = it fills the canvas.
    @Published private(set) var imageRect: CGRect?
    private var outpaints: Set<String> = []        // output paths of queued extensions: their result resets `pad`
    private var previewPath: String?               // where this batch's CLI rewrites it; deleted when the batch ends
    var appInfo: [String: AppInfo] = [:]           // by output path, until the image arrives
    var runArgs: [String: [String]] = [:]          // --model/--lora per queued output path

    private var process: Process?
    private var batchStarted = Date()

    init() {
        refreshLoras(); if aspect != "custom" { applyPreset() }; loadHistory()
        layout = (try? JSONDecoder().decode(MossLayout.self, from: Data(layoutJSON.utf8))) ?? MossLayout()
        layoutMode = !layout.items.isEmpty
        // a stale "source" on the Text tab: back to the last preset, after the boxes load so they scale with it.
        // ponytail: installs from before textAspect come up 1:1
        if tab == "t2i", aspect == "source" { aspect = textAspect; applyPreset() }
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
        let p = sidecar(job.url), refs = [p?["mask"], p?["init_image"]].compactMap { $0 as? String }   // an extension's padded init lives with the masks
        try? FileManager.default.trashItem(at: job.url, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: side, resultingItemURL: nil)
        if !refs.isEmpty { pruneMasks(refs) }
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
        let used = Set(sides.filter { $0.pathExtension == "json" }.flatMap { u in [sidecar(u)?["mask"], sidecar(u)?["init_image"]].compactMap { $0 as? String } }
                       + pending.flatMap { [$0.mask, $0.init_image].compactMap { $0 } })
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
    var effectivePrompt: String { withTriggers(prompt) }

    func withTriggers(_ prompt: String) -> String {
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
        imageRect = nil; pad = Pad()   // a new picture starts unextended; boxes scale with the canvas
        fitSource()
    }

    /// Match the working image's aspect at the current pixel budget, so nothing is cropped, extended by `pad`.
    /// Size only: initImage and originalSource stay as they are.
    private func fitSource() {
        guard !initImage.isEmpty, let rep = NSImageRep(contentsOfFile: initImage), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return }
        let g = Self.outpaint(source: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh), pad: pad, pixels: megapixels * 1024 * 1024)
        place(g.width, g.height, image: pad == Pad() ? nil : g.image)
        aspect = "source"
    }

    /// Re-derive width/height from the source image when the pixel budget changes.
    func applySourceAspect() {
        guard aspect == "source" else { return }
        fitSource()
    }

    /// The text handed to the model: a caption, or the compiled layout JSON when layout mode is on.
    var sentPrompt: String {
        // An extension sends the prompt as typed: it describes the whole, larger picture. Empty, the model is
        // only told to continue the scene (as a box edit's summary does).
        guard layoutMode, !layout.items.isEmpty else {
            return outpainting && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? withTriggers("The same picture." + Self.extended) : effectivePrompt
        }
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
            caption = "The same picture." + (outpainting ? Self.extended : "") + (fills.count > wants.count ? " The marked area shows only the plain background that surrounds it." : "")
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
    func resize(_ w: Int, _ h: Int) { place(w, h, image: nil) }

    /// Set the output size with the working image at `image` (nil: filling the canvas); boxes move with the picture.
    private func place(_ w: Int, _ h: Int, image: CGRect?) {
        let a = imageRect ?? CGRect(x: 0, y: 0, width: width, height: height), b = image ?? CGRect(x: 0, y: 0, width: w, height: h)
        // ponytail: a side under 16 px is a half-typed value, not a canvas; boxes keep their pixels instead of collapsing
        if min(a.width, a.height, b.width, b.height) >= 16, a != b {
            if !layout.items.isEmpty { layout = Self.mapped(layout, from: a, to: b) }
            // undo steps follow too, so ⌘Z after a size change doesn't bring back boxes in the old canvas's pixels
            undoStack = undoStack.map { Self.mapped($0, from: a, to: b) }; redoStack = redoStack.map { Self.mapped($0, from: a, to: b) }
        }
        width = w; height = h; imageRect = image
    }

    /// `layout` carried along when the picture moves from `a` to `b` (output-pixel rects).
    static func mapped(_ layout: MossLayout, from a: CGRect, to b: CGRect) -> MossLayout {
        let sx = b.width / a.width, sy = b.height / a.height
        var l = layout
        for i in l.items.indices {
            l.items[i].x0 = (l.items[i].x0 - a.minX) * sx + b.minX; l.items[i].x1 = (l.items[i].x1 - a.minX) * sx + b.minX
            l.items[i].y0 = (l.items[i].y0 - a.minY) * sy + b.minY; l.items[i].y1 = (l.items[i].y1 - a.minY) * sy + b.minY
        }
        return l
    }

    static func scaled(_ layout: MossLayout, _ sx: Double, _ sy: Double) -> MossLayout {
        var l = layout
        for i in l.items.indices { l.items[i].x0 *= sx; l.items[i].x1 *= sx; l.items[i].y0 *= sy; l.items[i].y1 *= sy }
        return l
    }

    // MARK: outpaint

    /// The Image tab extends the working image: the render fills the new area and keeps the picture.
    var outpainting: Bool { usingSource && imageRect != nil }

    static let extended = " It is extended beyond its original edges: the new area continues the scene seamlessly, in the same style, lighting and colours."

    /// Output size, and where the source sits in it, for `source` (pixels) extended by `pad` within `pixels`: the
    /// whole canvas fits the budget, and every edge lies on the 16 px latent grid so the join falls between patches.
    /// A zero pad gives the plain fitted size.
    static func outpaint(source: CGSize, pad: Pad, pixels: Double) -> (width: Int, height: Int, image: CGRect) {
        let s = (pixels / (source.width * (1 + pad.left + pad.right) * source.height * (1 + pad.top + pad.bottom))).squareRoot()
        func grid(_ v: Double) -> Int { Int((v / 16).rounded()) * 16 }
        let w = max(256, grid(source.width * s)), h = max(256, grid(source.height * s))
        let l = grid(source.width * pad.left * s), r = grid(source.width * pad.right * s)
        let t = grid(source.height * pad.top * s), b = grid(source.height * pad.bottom * s)
        return (l + w + r, t + h + b, CGRect(x: l, y: t, width: w, height: h))
    }

    /// What an extension regenerates: the canvas outside `image`, reaching `overlap` px into the picture on the
    /// extended sides so the join is redrawn too (the CLI's mask feather then softens it). Up to four strips.
    static func outpaintMask(canvas: CGSize, image: CGRect, overlap: CGFloat = 8) -> [CGRect] {
        let x0 = image.minX > 0 ? image.minX + overlap : 0, x1 = image.maxX < canvas.width ? image.maxX - overlap : canvas.width
        let y0 = image.minY > 0 ? image.minY + overlap : 0, y1 = image.maxY < canvas.height ? image.maxY - overlap : canvas.height
        return [CGRect(x: 0, y: 0, width: x0, height: canvas.height), CGRect(x: x1, y: 0, width: canvas.width - x1, height: canvas.height),
                CGRect(x: 0, y: 0, width: canvas.width, height: y0), CGRect(x: 0, y: y1, width: canvas.width, height: canvas.height - y1)]
            .filter { $0.width > 0 && $0.height > 0 }
    }

    /// The pad that grows a picture of aspect `source` (w/h) to `ratio`, half on each side.
    static func pad(to ratio: Double, from source: Double) -> Pad {
        let grow = (max(ratio, source) / min(ratio, source) - 1) / 2
        return ratio >= source ? Pad(left: grow, right: grow) : Pad(top: grow, bottom: grow)
    }

    /// Extend the working image to `ratio`, evenly on both sides.
    func extend(to ratio: Double) {
        guard let rep = NSImageRep(contentsOfFile: initImage), rep.pixelsHigh > 0 else { return }
        pad = Self.pad(to: ratio, from: Double(rep.pixelsWide) / Double(rep.pixelsHigh))
    }

    /// The working image at `imageRect` on the output canvas, the new area filled with its edge pixels stretched
    /// outwards and blurred: regenerated at strength 1 anyway, but the VAE sees a plausible join, not a hard border.
    /// Written with the masks and pruned like them. Returns the path.
    func writePaddedInit() -> String? {
        guard let rect = imageRect, let file = CGImageSourceCreateWithURL(URL(fileURLWithPath: initImage) as CFURL, nil),
              let src = CGImageSourceCreateImageAtIndex(file, 0, nil) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let r = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)   // Core Image is bottom-up
        let s = max(r.width / CGFloat(src.width), r.height / CGFloat(src.height))   // cover and centre-crop, as the CLI does
        let scaled = CIImage(cgImage: src).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        let picture = scaled.transformed(by: CGAffineTransform(translationX: r.midX - scaled.extent.midX, y: r.midY - scaled.extent.midY)).cropped(to: r)
        let filled = picture.composited(over: picture.clampedToExtent().applyingGaussianBlur(sigma: 24)).cropped(to: canvas)
        guard let cg = CIContext().createCGImage(filled, from: canvas) else { return nil }
        let dir = URL(fileURLWithPath: outputDir).appendingPathComponent("masks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("outpaint-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        guard (try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)) != nil else { return nil }
        return url.path
    }

    /// An extension's result is the working image now: it fills the canvas, unextended.
    private func extensionDone() { imageRect = nil; pad = Pad(); fitSource() }

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
                      init_image: usingSource ? (outpainting ? writePaddedInit() : initImage) : nil,
                      strength: usingSource && !outpainting ? strength : 1,   // the new area starts from noise
                      mask: usingSource ? effectiveMask : nil, mask_feather: maskFeather,
                      output: outputURL(seed: s).path)
    }

    var usingSource: Bool { tab == "i2i" && !initImage.isEmpty }

    /// The mask sent with an image-to-image render: the layout boxes and the extension, if any. Neither = the whole image.
    var effectiveMask: String? { writeMask(boxStrokes + (imageRect.map { Self.outpaintMask(canvas: CGSize(width: width, height: height), image: $0) } ?? []).map(Self.outline)) }

    var effectiveMaskExists: Bool { !layout.items.isEmpty || outpainting }

    /// One closed rectangle per layout box, padded 8 px so glyph edges are covered.
    var boxStrokes: [[CGPoint]] { layout.items.map { Self.outline($0.rect.insetBy(dx: -8, dy: -8)) } }

    static func outline(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
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
        guard editWithBoxes || outpainting || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Write a prompt first."; return }
        if tab == "i2i", initImage.isEmpty { status = "Choose a source image first, or switch to Text to image."; return }
        if layoutMode, layout.items.contains(where: { $0.label == "text" && $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            status = "A text box has no visible text. Type the words to render in its Visible text field (Layout toggle, select the box)."; return
        }
        if randomSeed { seed = Int.random(in: 1...999_999) }
        if !editWithBoxes { recentPrompts = Self.remembering(prompt, in: recentPrompts) }   // a box edit ignores the prompt
        let r = currentRender(seed: seed)
        if outpainting { outpaints.insert(r.output) }
        enqueue([r])
    }

    var recentPrompts: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(recentPromptsJSON.utf8))) ?? [] }
        set { recentPromptsJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self); objectWillChange.send() }
    }

    /// `list` with `prompt` moved to the front: newest first, no duplicates, at most 20; blank prompts change nothing.
    static func remembering(_ prompt: String, in list: [String]) -> [String] {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? list : Array(([p] + list.filter { $0 != p }).prefix(20))
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

    /// `--model` and `--lora` args: the sidebar's, or for a re-render the tier and adapters recorded in `job`'s sidecar.
    func modelArgs(_ job: Job? = nil) -> [String] {
        // ponytail: sidecars from before the tier was recorded re-render with the current one
        let t = job.flatMap { restore($0.url)?.tier } ?? tier
        let specs = job.flatMap { sidecarRoot($0.url)?["loras"] as? [String] }
            ?? loras.filter { loraState[$0] != nil }.map { loraDir + "/" + $0 + String(format: ":%.2f", loraState[$0]!) }
        return ["--model", t] + specs.flatMap { ["--lora", $0] }
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
        var info = job.flatMap { restore($0.url) } ?? AppInfo(prompt: prompt, layout: layout.items.isEmpty ? nil : layout)
        info.tier = info.tier ?? tier   // what modelArgs(job) picks too
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
                    if self.outpaints.remove(path) != nil, self.initImage == path { self.extensionDone() }
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

    private var lastErrorLine: String {
        log.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last { !$0.hasPrefix("step ") && !$0.isEmpty }.map(String.init) ?? "see log"
    }

    func cancel() { pending = []; process?.terminate() }

    /// Drop queued renders by output path, nil = all of them. The running batch is the CLI's already and stays.
    func removeQueued(_ output: String? = nil) {
        let gone = pending.filter { output == nil || $0.output == output }
        pending.removeAll { output == nil || $0.output == output }
        for r in gone { appInfo[r.output] = nil; runArgs[r.output] = nil }
        pruneMasks(gone.compactMap(\.mask))   // ponytail: no-op while a batch runs; the launch prune catches those
    }

    /// A queued render's line in the queue list: first line of the prompt the user typed, else of the one sent.
    func queuedTitle(_ r: Render) -> String {
        let line = (appInfo[r.output]?.prompt ?? r.prompt).split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return !line.isEmpty ? line : r.init_image.map { "Edit of " + URL(fileURLWithPath: $0).lastPathComponent } ?? "No prompt"
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
