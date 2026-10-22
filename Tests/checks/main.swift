// Headless checks against the app's own sources. Run: ./tests.sh
import AppKit
import SwiftUI

var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }

@MainActor func run() async {
    let gen = Generator()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moss-checks-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    gen.outputDir = tmp.path

    // 1. layout compile: documented example from the MOSS-Image prompt-enhancer skill
    var l = MossLayout(meta: ["product campaign"], canvas: "single", items: [
        LayoutItem(label: "object", caption: "cup", x0: 176, y0: 224, x1: 800, y1: 864)])
    var out = l.compiled(caption: "c", width: 1536, height: 1024)
    check(out.contains(#""bbox":[-288,-592,352,32]"#), "compiled bbox matches the documented cup example: \(out)")
    check(out.contains(#""bbox_coord_space":"abs_centralized""#) && out.contains(#""bbox_format":"yxyx""#), "compiled coordinate flags")
    l.items = [LayoutItem(label: "text", caption: "t", text: "HI\nTHERE", x0: 10.4, y0: 10.6, x1: 99.2, y1: 50.5)]
    out = l.compiled(caption: "c", width: 200, height: 100)
    check(out.contains(#""bbox":[-40,-90,1,0]"#), "fractional edges floor/ceil before centring: \(out)")
    check(out.contains(#""text":"HI\nTHERE""#), "newline in visible text escaped, not lost")
    check(!out.contains("\n"), "compiled layout is one physical line")

    // 2. enhancer draft parsing (output of the local model, saved by the CLI test)
    if let draft = try? String(contentsOfFile: "/tmp/layout_out.txt", encoding: .utf8) {
        let parsed = MossLayout.fromDraft(draft)
        check(parsed?.layout.items.count == 2, "local model layout draft parses to 2 items")
        check(parsed?.layout.items.first?.text == "LISBON", "draft text item keeps its text")
    } else { print("skip  no /tmp/layout_out.txt") }
    check(MossLayout.fromDraft("no json here") == nil, "garbage draft rejected")
    check(Enhancer.caption(from: "```json\n{\"caption\": \"a cat\"}\n```") == "a cat", "caption extracted from fenced JSON")
    check(Enhancer.caption(from: "plain words") == "plain words", "bare caption passes through")

    // 3. Render encodes only fields the CLI's Request accepts
    let requestFields = Set("prompt negative_prompt width height steps guidance shift seed uncond_skip_layers slg_layers slg_scale slg_start slg_stop max_sequence_length init_image strength mask mask_feather".split(separator: " ").map(String.init)) .union(["output"])
    gen.prompt = "a sign"; gen.tab = "t2i"; gen.layout = MossLayout()
    let r = gen.currentRender(seed: 7)
    let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
    check(Set(json.keys).isSubset(of: requestFields), "render JSON keys ⊆ Request fields: \(json.keys.sorted())")
    check(json["init_image"] == nil && json["mask"] == nil, "nil optionals are omitted (not null) in text-to-image")
    check((json["strength"] as? Double) == 1, "strength 1 without a source")

    // 4. trigger words
    gen.loras = ["style.safetensors", "dmd.safetensors"]
    gen.loraTriggers = ["style.safetensors": "moss_vgouache_style"]
    gen.loraState = ["style.safetensors": 1]
    gen.prompt = "a cottage"
    check(gen.effectivePrompt == "moss_vgouache_style, a cottage", "enabled adapter prepends its trigger: \(gen.effectivePrompt)")
    gen.prompt = "moss_vgouache_style, a cottage"
    check(gen.effectivePrompt == "moss_vgouache_style, a cottage", "no duplicate trigger")
    gen.loraState = [:]
    check(gen.effectivePrompt == "a cottage", "disabled adapter's trigger removed from a hand-typed prompt: \(gen.effectivePrompt)")

    // 5. size presets
    gen.aspect = "1:1"; gen.megapixels = 1; gen.applyPreset()
    check(gen.width == 1024 && gen.height == 1024, "1:1 at 1 MP is 1024²")
    gen.aspect = "16:9"; gen.megapixels = 2; gen.applyPreset()
    check(gen.width % 16 == 0 && gen.height % 16 == 0 && abs(Double(gen.width) / Double(gen.height) - 16.0 / 9) < 0.03, "16:9 at 2 MP is multiples of 16: \(gen.width)x\(gen.height)")

    // 6. source image sets the aspect
    let src = tmp.appendingPathComponent("src.png")
    let img = NSImage(size: NSSize(width: 1500, height: 1000)); img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 1500, height: 1000).fill(); img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: src)
    gen.megapixels = 1; gen.setSource(src.path)
    check(gen.aspect == "source" && abs(Double(gen.width) / Double(gen.height) - 1.5) < 0.03 && gen.width % 16 == 0, "source 3:2 → aspect 'source', \(gen.width)x\(gen.height)")

    // 7. image-to-image render carries init/strength/mask only on the I2I tab
    gen.tab = "i2i"; gen.strength = 0.55; gen.prompt = "x"
    var r2 = gen.currentRender(seed: 1)
    check(r2.init_image == src.path && r2.strength == 0.55 && r2.mask == nil, "I2I render has init and strength, no boxes so no mask")
    gen.tab = "t2i"; r2 = gen.currentRender(seed: 1)
    check(r2.init_image == nil && r2.strength == 1, "T2I tab ignores the source image")

    // 8. boxes are the mask: white rectangle at the box (+8 px), black elsewhere, output size
    gen.tab = "i2i"; gen.width = 1024; gen.height = 1024; gen.aspect = "custom"
    gen.layout = MossLayout(items: [LayoutItem(label: "text", caption: "c", text: "49 kr.", x0: 300, y0: 200, x1: 720, y1: 320)])
    let r3 = gen.currentRender(seed: 1)
    check(r3.mask != nil && r3.init_image == src.path, "I2I render derives its mask from the boxes")
    if let mp = r3.mask, let m = NSImage(contentsOfFile: mp), let bmp = m.representations.first as? NSBitmapImageRep {
        check(bmp.pixelsWide == 1024 && bmp.pixelsHigh == 1024, "mask is output-sized: \(bmp.pixelsWide)x\(bmp.pixelsHigh)")
        func white(_ x: Int, _ y: Int) -> Bool { (bmp.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.5 }
        check(white(500, 260) && white(295, 195) && white(725, 325), "inside the padded box is white")
        check(!white(280, 260) && !white(500, 180) && !white(100, 900) && !white(740, 260), "outside the box is black")
    } else { check(false, "mask PNG readable") }
    gen.layout = MossLayout()
    check(gen.currentRender(seed: 1).mask == nil, "no boxes: no mask, whole-image strength")

    // 8b. edits: empty captions get a style default, empty prompt allowed, feather travels
    gen.prompt = ""
    gen.layout = MossLayout(items: [LayoutItem(label: "text", caption: "", text: "49 kr.", x0: 300, y0: 200, x1: 720, y1: 320)])
    check(gen.layoutMode, "layout mode follows the boxes")
    check(gen.sentPrompt.contains("same font, size, weight and colour") && gen.sentPrompt.contains("The same picture."), "edit: default caption and summary: \(gen.sentPrompt.prefix(120))")
    gen.prompt = "Change 149 kr. to 55 kr."
    check(!gen.sentPrompt.contains("Change 149"), "edit: the prompt field is ignored, instructions never reach the model")
    check(LayoutItem(x0: 0, y0: 0, x1: 1, y1: 1).label == "text", "new boxes default to text")
    // fill boxes: in the mask, not in the layout; plain caption when nothing is placed
    gen.layout = MossLayout(items: [LayoutItem(label: "fill", caption: "", x0: 100, y0: 100, x1: 300, y1: 200)])
    check(!gen.sentPrompt.hasPrefix("{") && gen.sentPrompt.contains("plain background"), "fill-only edit sends a plain caption: \(gen.sentPrompt)")
    check(gen.currentRender(seed: 1).mask != nil, "fill box still makes a mask")
    gen.layout = MossLayout(items: [LayoutItem(label: "fill", caption: "a red apple", x0: 100, y0: 100, x1: 300, y1: 200),
                                    LayoutItem(label: "text", caption: "", text: "HI", x0: 400, y0: 400, x1: 600, y1: 500)])
    check(gen.sentPrompt.hasPrefix("{") && gen.sentPrompt.contains("a red apple") && !gen.sentPrompt.contains(#""label":"fill""#), "fill with text box: JSON without a fill item, apple in the summary")
    check(gen.tinyBoxes.isEmpty, "fill boxes are exempt from the size guard")
    gen.prompt = ""
    check(gen.currentRender(seed: 1).mask_feather == 12, "feather default 12 in the render")
    gen.pending = []; gen.status = ""
    let cliMissing = !FileManager.default.isExecutableFile(atPath: gen.cli)
    if cliMissing { gen.generate(); check(gen.status.contains("Could not start") || !gen.pending.isEmpty, "edit with boxes passes the empty-prompt guard") }
    gen.tab = "t2i"; gen.generate(); check(gen.status == "Write a prompt first." && gen.pending.isEmpty, "text-to-image still needs a prompt")
    gen.tab = "i2i"

    // 9. layout prompt goes out compiled when layoutMode is on, text box without text is caught
    gen.prompt = "shelf label"
    gen.layout = MossLayout(items: [LayoutItem(label: "text", caption: "", text: "49 kr.", x0: 300, y0: 200, x1: 720, y1: 320)])
    check(gen.sentPrompt.hasPrefix("{") && gen.sentPrompt.contains(#""text":"49 kr.""#) && gen.sentPrompt.contains("The same picture."), "edit: sentPrompt is the compiled layout with the fixed summary")
    gen.tab = "t2i"
    check(gen.sentPrompt.contains("shelf label"), "text to image: sentPrompt carries the prompt as summary caption")
    gen.tab = "i2i"
    gen.layout = MossLayout(items: [LayoutItem(label: "text", caption: "c", text: "", x0: 0, y0: 0, x1: 50, y1: 50)])
    gen.pending = []; gen.generate()
    check(gen.pending.isEmpty && gen.status.contains("no visible text"), "generate refuses an empty text box: \(gen.status)")
    gen.layout = MossLayout(items: [LayoutItem(label: "text", caption: "c", text: "hi", x0: 0, y0: 0, x1: 50, y1: 20)])
    gen.pending = []; gen.generate()
    check(gen.pending.isEmpty && gen.status.contains("under 40 px"), "generate refuses a box too small to render: \(gen.status)")
    gen.layout = MossLayout(); check(!gen.layoutMode, "clearing boxes turns layout mode off")

    // 10. helpers
    check(Generator.layers("22") == [22] && Generator.layers("8, 9 10") == [8, 9, 10] && Generator.layers("") == [], "layer list parsing")
    Keychain.write("moss-checks", "secret"); check(Keychain.read("moss-checks") == "secret", "keychain round trip"); Keychain.write("moss-checks", "")
    check(Keychain.read("moss-checks") == nil, "keychain delete")

    // 11. variations rebuild a render from a sidecar
    let side = tmp.appendingPathComponent("old.json"), png = tmp.appendingPathComponent("old.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: png)
    try! #"{"parameters":{"prompt":"from sidecar","seed":99,"width":512,"height":512,"steps":8,"cfg":1.0,"strength":1.0}}"#.write(to: side, atomically: true, encoding: .utf8)
    let old = Job(url: png, prompt: "", seed: 0, seconds: 0)
    if let v = gen.render(from: old) {
        check(v.prompt == "from sidecar" && v.seed == 99 && v.width == 512 && v.init_image == nil, "render(from:) reads the sidecar")
    } else { check(false, "render(from:) returned nil") }

    // 11b. trash removes the file, its sidecar and the history entry
    let tpng = tmp.appendingPathComponent("t.png"), tside = tmp.appendingPathComponent("t.json")
    try! rep.representation(using: .png, properties: [:])!.write(to: tpng); try! "{}".write(to: tside, atomically: true, encoding: .utf8)
    let tjob = Job(url: tpng, prompt: "", seed: 1, seconds: 0); gen.jobs.insert(tjob, at: 0); gen.selected = tjob
    gen.trash(tjob)
    check(!FileManager.default.fileExists(atPath: tpng.path) && !FileManager.default.fileExists(atPath: tside.path), "trash moves PNG and sidecar away")
    check(!gen.jobs.contains(tjob) && gen.selected != tjob, "trash drops the history entry and selection")

    // 11c. ←/→ step through the history, newest first, and stop at the ends
    let ja = Job(url: tpng, prompt: "", seed: 1, seconds: 0), jb = Job(url: tpng, prompt: "", seed: 2, seconds: 0)
    let savedJobs = gen.jobs
    gen.jobs = [ja, jb]; gen.selected = ja
    gen.selectAdjacent(1); check(gen.selected == jb, "→ selects the older render")
    gen.selectAdjacent(1); check(gen.selected == jb, "→ stops at the oldest")
    gen.selectAdjacent(-1); gen.selectAdjacent(-1); check(gen.selected == ja, "← back to the newest and stops")
    gen.tab = "t2i"; gen.layoutOverlay = true; check(!gen.showsResult, "no stepping while the layout editor is open")
    gen.layoutOverlay = false; check(gen.showsResult, "result view showing on the Text tab")
    gen.jobs = savedJobs; gen.selected = savedJobs.first

    // 12. live paths, only when the venv is present (MOSS_CHECKS_OFFLINE=1 skips them)
    let cli = gen.cli
    if FileManager.default.isExecutableFile(atPath: cli), ProcessInfo.processInfo.environment["MOSS_CHECKS_OFFLINE"] == nil {
        // a real batch through the Generator: two 512² renders, one process, both files reported on stdout
        gen.tab = "t2i"; gen.layout = MossLayout(); gen.loras = []; gen.loraState = [:]
        gen.prompt = "A simple street sign that reads \"HELLO MLX\" on a blue sky"; gen.width = 512; gen.height = 512; gen.aspect = "custom"
        gen.steps = 8; gen.guidance = 1; gen.tier = "compact"
        gen.refreshLoras(); if gen.loras.contains("MOSS-Image-SFT-8-steps-dmd.safetensors") { gen.enable("MOSS-Image-SFT-8-steps-dmd.safetensors", scale: 1) }
        let before = gen.jobs.count
        gen.enqueue([gen.currentRender(seed: 1), gen.currentRender(seed: 2)])
        check(gen.running, "batch started")
        let deadline = Date().addingTimeInterval(240)
        while gen.running, Date() < deadline { await Task.sleep(seconds: 0.2) }
        check(!gen.running, "batch finished within 4 min: \(gen.status)")
        check(gen.jobs.count == before + 2, "two jobs added from stdout paths: \(gen.jobs.count - before)")
        check(gen.jobs.prefix(2).allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, "both PNGs exist")
        check(gen.status.contains("Done"), "status reports done: \(gen.status)")
        // sidecar from the CLI has what variations need
        if let j = gen.jobs.first, let v = gen.render(from: j) { check(v.seed == 2 && v.width == 512, "CLI sidecar round-trips through render(from:)") }

        // local enhancer from Swift (model is cached by the CLI test; otherwise this downloads 2.5 GB)
        do {
            let text = try await Enhancer.local(python: gen.python, model: gen.localModel, idea: "a lighthouse at dawn", want: "caption", width: 1024, height: 1024)
            let cap = Enhancer.caption(from: text)
            check(cap.count > 40 && !cap.hasPrefix("{"), "local enhancer returns a caption: \(cap.prefix(60))…")
        } catch { check(false, "local enhancer: \(error.localizedDescription)") }
    } else { print("skip  no moss-mlx at \(cli)") }

    // 13. Hub search (network)
    do {
        let models = try await HubSearch.models("moss-image")
        check(models.contains { $0.id == "lodestones/MOSS-Image-SFT-8-steps-dmd" }, "Hub search finds the DMD repo among \(models.count) results")
        let files = try await HubSearch.files("lodestones/MOSS-Image-SFT-8-steps-dmd")
        check(files.contains("lora.safetensors"), "Hub file list has lora.safetensors: \(files)")
    } catch { print("skip  network: \(error.localizedDescription)") }

    try? FileManager.default.removeItem(at: tmp)
}

extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
}

let sem = DispatchSemaphore(value: 0)
Task { @MainActor in await run(); sem.signal() }
while sem.wait(timeout: .now()) != .success { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
