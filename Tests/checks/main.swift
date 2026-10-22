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
    // 2b. stored layout JSON (layoutJSON, sidecar "app", undo): one odd box must not drop every box
    func dec(_ s: String) -> MossLayout? { try? JSONDecoder().decode(MossLayout.self, from: Data(s.utf8)) }
    let shape = #"{"canvas":"single","items":[{"caption":"a cup","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"object","text":"","x0":10,"x1":200.5,"y0":20,"y1":80}],"meta":["product campaign"]}"#
    let sorted = JSONEncoder(); sorted.outputFormatting = .sortedKeys
    let sl = dec(shape)
    check(sl?.items.first?.caption == "a cup" && sl?.items.first?.x1 == 200.5 && sl?.meta == ["product campaign"], "the layout JSON shape written today decodes")
    check(sl.flatMap { try? sorted.encode($0) }.map { String(decoding: $0, as: UTF8.self) } == shape, "decode then encode reproduces the stored JSON byte for byte")
    let rt = MossLayout(meta: ["m"], canvas: "grid", items: [LayoutItem(label: "text", caption: "c", text: "HI", x0: 1.5, y0: 2, x1: 30, y1: 40),
                                                             LayoutItem(label: "fill", caption: "", x0: 5, y0: 6, x1: 7, y1: 8)])
    check((try? JSONDecoder().decode(MossLayout.self, from: JSONEncoder().encode(rt))) == rt, "encode→decode round-trip unchanged")
    let loose = dec(#"{"items":[{"label":"object","caption":"cup","x0":1,"y0":2,"x1":3,"y1":4,"extra":true}],"future":1}"#)
    check(loose?.items.count == 1 && loose?.items.first?.text == "" && loose?.canvas == "single" && loose?.meta == [], "item missing text/id decodes with defaults, unknown keys ignored")
    let bare = dec(#"{"items":[{"x0":1,"y0":2,"x1":3,"y1":4},{"x0":1,"y0":2,"x1":3,"y1":4}]}"#)
    check(bare?.items.first?.label == "text" && bare?.items.first?.caption == "" && bare.map { $0.items[0].id != $0.items[1].id } == true, "bare boxes get label/caption defaults and distinct new ids")
    let mixed = dec(#"{"items":[{"label":"object","caption":"a","x0":1,"y0":2,"x1":3,"y1":4},{"caption":"bad","x0":"left","y0":2,"x1":3,"y1":4},{"caption":"nox","y0":2,"x1":3,"y1":4},{"label":"text","text":"HI","x0":5,"y0":6,"x1":7,"y1":8}]}"#)
    check(mixed?.items.map(\.caption) == ["a", ""] && mixed?.items.last?.text == "HI", "a malformed box among good ones drops only itself")
    check(dec("{}") == MossLayout(), "the empty default layoutJSON decodes to no boxes")
    check(Enhancer.caption(from: "```json\n{\"caption\": \"a cat\"}\n```") == "a cat", "caption extracted from fenced JSON")
    check(Enhancer.caption(from: "plain words") == "plain words", "bare caption passes through")

    // 3. Render encodes only fields the CLI's Request accepts
    let requestFields = Set("prompt negative_prompt width height steps guidance shift seed uncond_skip_layers slg_layers slg_scale slg_start slg_stop max_sequence_length init_image strength mask mask_feather preview".split(separator: " ").map(String.init)) .union(["output"])
    gen.prompt = "a sign"; gen.tab = "t2i"; gen.layout = MossLayout()
    let r = gen.currentRender(seed: 7)
    let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
    check(Set(json.keys).isSubset(of: requestFields), "render JSON keys ⊆ Request fields: \(json.keys.sorted())")
    check(json["preview"] == nil, "no preview in the job JSON: it goes as --preview, only to a CLI that lists it (11g)")
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

    // 6b. "source" is Image-only: the Text tab gets back the last preset picked, sized for it
    gen.tab = "t2i"; gen.aspect = "4:3"; gen.megapixels = 1; gen.applyPreset()
    let (w43, h43) = (gen.width, gen.height)
    gen.tab = "i2i"; gen.setSource(src.path)
    check(gen.aspect == "source", "Image tab source sets aspect 'source'")
    gen.tab = "t2i"
    check(gen.aspect == "4:3" && gen.width == w43 && gen.height == h43, "back on Text: previous preset 4:3 and its size: \(gen.aspect) \(gen.width)x\(gen.height)")
    UserDefaults.standard.set("source", forKey: "aspect"); UserDefaults.standard.removeObject(forKey: "textAspect")
    let stale = Generator()
    check(stale.aspect == "1:1" && stale.width == 1024 && stale.height == 1024, "stale 'source' on Text at launch comes up 1:1, not Custom: \(stale.aspect) \(stale.width)x\(stale.height)")
    gen.tab = "i2i"; gen.setSource(src.path)   // the rest expects the source state

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

    // 11c. local Enhance survives > 64 KB of stderr (download progress bars) without deadlocking
    final class Outcome: @unchecked Sendable { var text: String?; var error: String?; var done = false }
    func fakePython(_ name: String, _ body: String) -> String {
        let f = tmp.appendingPathComponent(name)
        try! "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return f.path
    }
    func enhanceLocal(_ py: String) async -> Outcome {
        let o = Outcome()
        Task.detached {
            do { o.text = try await Enhancer.local(python: py, model: "m", idea: "i", want: "caption", width: 512, height: 512) }
            catch { o.error = error.localizedDescription }
            o.done = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !o.done, Date() < deadline { await Task.sleep(seconds: 0.05) }
        return o
    }
    let noisy = await enhanceLocal(fakePython("noisy-python", "yes progress | head -c 300000 >&2\necho '{\"caption\": \"a test caption\"}'"))
    check(noisy.text.map(Enhancer.caption) == "a test caption", "local enhance with 300 KB of stderr returns within 10 s: \(noisy.text ?? noisy.error ?? "timed out")")
    let broken = await enhanceLocal(fakePython("broken-python", "echo \"ModuleNotFoundError: No module named 'mlx_lm'\" >&2\nexit 1"))
    check(broken.error?.contains("mlx-lm is not installed") == true, "local enhance failure keeps the mlx-lm hint: \(broken.error ?? "no error")")
    // 11c. trashLora moves the adapter away and forgets its scale and trigger
    let keepLoraDir = gen.loraDir, ldir = tmp.appendingPathComponent("loras")
    gen.loraDir = ldir.path; try! FileManager.default.createDirectory(at: ldir, withIntermediateDirectories: true)
    try! "x".write(to: ldir.appendingPathComponent("gone.safetensors"), atomically: true, encoding: .utf8)
    gen.refreshLoras(); gen.enable("gone.safetensors", scale: 0.7); gen.loraTriggers["gone.safetensors"] = "gone_style"
    gen.trashLora("gone.safetensors")
    check(!FileManager.default.fileExists(atPath: ldir.appendingPathComponent("gone.safetensors").path) && !gen.loras.contains("gone.safetensors"), "trashLora moves the file out of the library")
    check(gen.loraState["gone.safetensors"] == nil && gen.loraTriggers["gone.safetensors"] == nil, "trashLora drops scale and trigger")
    gen.trashLora("missing.safetensors"); check(gen.status.contains("Could not move"), "trashLora reports a failure: \(gen.status)")
    gen.loraDir = keepLoraDir

    // 11d. trashing a render trashes its mask only once no other sidecar references it
    let mdir = tmp.appendingPathComponent("masks"); try! FileManager.default.createDirectory(at: mdir, withIntermediateDirectories: true)
    let maskA = mdir.appendingPathComponent("mask-a.png").path, orphan = mdir.appendingPathComponent("mask-orphan.png").path
    for m in [maskA, orphan] { try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: m)) }
    func edit(_ name: String, mask: String) -> Job {
        let u = tmp.appendingPathComponent(name + ".png")
        try! rep.representation(using: .png, properties: [:])!.write(to: u)
        try! #"{"parameters":{"mask":"\#(mask)"}}"#.write(to: tmp.appendingPathComponent(name + ".json"), atomically: true, encoding: .utf8)
        return Job(url: u, prompt: "", seed: 1, seconds: 0)
    }
    let e1 = edit("e1", mask: maskA), e2 = edit("e2", mask: maskA), e3 = edit("e3", mask: src.path)
    gen.trash(e1); check(FileManager.default.fileExists(atPath: maskA), "mask kept while a variation still references it")
    gen.trash(e2); check(!FileManager.default.fileExists(atPath: maskA), "mask trashed with the last render that used it")
    gen.trash(e3); check(FileManager.default.fileExists(atPath: src.path), "a mask path outside outputDir/masks is never trashed")
    gen.pruneMasks(olderThan: 86_400); check(FileManager.default.fileExists(atPath: orphan), "launch prune keeps unreferenced masks under a day old")
    gen.pruneMasks(); check(!FileManager.default.fileExists(atPath: orphan), "prune trashes unreferenced masks")

    // 11e. Settings writes the defaults directly: a Generator that never set the key itself sees the new value and
    // notifies (ContentView reloads on that). One that did set it keeps its own copy, hence the fresh instance.
    let app = Generator()
    var notified = false
    let sub = app.objectWillChange.sink { notified = true }
    let newOut = tmp.appendingPathComponent("elsewhere").path
    UserDefaults.standard.set(newOut, forKey: "outputDir"); await Task.sleep(seconds: 0.1)
    check(notified && app.outputDir == newOut, "external outputDir change reaches the Generator: \(app.outputDir)")
    sub.cancel()
    app.loadHistory(); check(app.jobs.isEmpty && app.selected == nil, "history of a new, missing output folder is empty")
    UserDefaults.standard.set(tmp.path, forKey: "outputDir")
    // 11c. re-deriving the size from the source keeps the Original pin (initImage is a later result)
    gen.tab = "i2i"; gen.setSource(src.path); gen.initImage = png.path; gen.megapixels = 0.5; gen.applyPreset()
    check(gen.originalSource == src.path && gen.initImage == png.path && gen.width * gen.height < 600_000, "Pixels change keeps originalSource and initImage: \(gen.width)x\(gen.height)")

    // 11d. boxes follow the output size; compiled bboxes stay on the canvas
    gen.tab = "t2i"; gen.aspect = "1:1"; gen.megapixels = 1; gen.applyPreset()
    gen.layout = MossLayout(items: [LayoutItem(label: "object", caption: "c", x0: 600, y0: 600, x1: 1000, y1: 1000)])
    gen.megapixels = 0.5; gen.applyPreset()
    let b = gen.layout.items[0], s = Double(gen.width) / 1024
    check(abs(b.x0 - 600 * s) < 0.01 && abs(b.y1 - 1000 * s) < 0.01 && b.x1 <= Double(gen.width), "1 → 0.5 MP scales the box with the canvas: \(b.rect) at \(gen.width)")
    let half = gen.width / 2
    let bbox = (try? JSONSerialization.jsonObject(with: Data(gen.sentPrompt.utf8)) as? [String: Any])
        .flatMap { ($0["items"] as? [[String: Any]])?.first?["bbox"] as? [Int] } ?? []
    check(bbox.count == 4 && bbox.allSatisfy { abs($0) <= half }, "compiled bbox inside ±\(half): \(bbox)")
    gen.resize(5, gen.height); gen.resize(1024, gen.height)
    check(abs(gen.layout.items[0].x0 - 600 * s) < 0.01, "a half-typed width under 16 px leaves the boxes alone")
    out = MossLayout(items: [LayoutItem(label: "object", caption: "c", x0: -50, y0: 10, x1: 300, y1: 90)]).compiled(caption: "c", width: 200, height: 100)
    check(out.contains(#""bbox":[-40,-100,40,100]"#), "compiled() clamps a box that overhangs the canvas: \(out)")
    gen.layout = MossLayout()

    // 11c. reuse restores what the user typed: "app" in the sidecar, or legacy layout JSON taken apart
    let poster = MossLayout(items: [LayoutItem(label: "text", caption: "bold", text: "SALE", x0: 100, y0: 50, x1: 400, y1: 150),
                                    LayoutItem(label: "object", caption: "a cup", x0: 500, y0: 300, x1: 700, y1: 600)])
    let lpng = tmp.appendingPathComponent("legacy.png"), lside = tmp.appendingPathComponent("legacy.json")
    try! rep.representation(using: .png, properties: [:])!.write(to: lpng)
    func writeSidecar(_ params: [String: Any]) {
        let obj: [String: Any] = ["schema_version": 2, "parameters": params, "timings": ["total_s": 41.18], "loras": ["/x/style.safetensors:1.00"]]
        try! JSONSerialization.data(withJSONObject: obj).write(to: lside)
    }
    gen.loraTriggers["Moss-image-gouache-lora.safetensors"] = "moss_vgouache_style"   // defaults persist between runs
    writeSidecar(["prompt": poster.compiled(caption: "moss_vgouache_style, a poster", width: 1024, height: 768), "width": 1024, "height": 768, "seed": 42])
    let legacy = gen.restore(lpng)
    check(legacy?.prompt == "a poster", "legacy: summary caption without trigger word: \(legacy?.prompt ?? "nil")")
    check(legacy?.layout?.items.map(\.rect) == poster.items.map(\.rect) && legacy?.layout?.items.map(\.text) == ["SALE", ""]
          && legacy?.layout?.items.map(\.label) == ["text", "object"], "legacy: layout JSON back to the same boxes")
    // the real edit sidecar from the CLI: boxes back, generated summary not put in the prompt box
    let real = #"{"bbox_coord_space":"abs_centralized","bbox_format":"yxyx","items":[{"bbox":[11,-221,376,228],"caption":"...","label":"text","text":"Hello World"}],"summary":{"canvas":"single","caption":"The same picture."}}"#
    writeSidecar(["prompt": real, "width": 1024, "height": 1024, "seed": 914110, "init_image": "/x/src.png"])
    let edit = gen.restore(lpng)
    check(edit?.prompt == "" && edit?.layout?.items.first?.rect == CGRect(x: 291, y: 523, width: 449, height: 365)
          && edit?.layout.map { $0.compiled(caption: "The same picture.", width: 1024, height: 1024) } == real,
          "legacy edit: boxes recompile to the same JSON, prompt empty: \(String(describing: edit?.layout?.items.first?.rect))")
    let plain = gen.restore(tmp.appendingPathComponent("old.png"))
    check(plain?.prompt == "from sidecar" && plain?.layout == nil, "legacy plain prompt passes through")
    // new sidecars: "app" merged in, CLI fields kept, reuse restores prompt, boxes and seed
    writeSidecar(["prompt": poster.compiled(caption: "moss_vgouache_style, a poster", width: 1024, height: 768), "width": 1024, "height": 768, "seed": 42])
    Generator.merge(AppInfo(prompt: "a poster, moss_vgouache_style kept as typed", layout: poster), intoSidecarOf: lpng.path)
    let merged = gen.sidecarRoot(lpng)
    check(merged?["app"] != nil && merged?["loras"] as? [String] == ["/x/style.safetensors:1.00"] && gen.sidecar(lpng)?["seed"] as? Int == 42, "merge adds app, keeps the CLI's fields")
    gen.prompt = "something else"; gen.layout = MossLayout(); gen.seed = 1; gen.randomSeed = true
    gen.aspect = "custom"; gen.resize(1024, 768)   // the image's size, so Reuse has no boxes to rescale
    gen.reuse(Job(url: lpng, prompt: "", seed: 42, seconds: 0))
    check(gen.prompt == "a poster, moss_vgouache_style kept as typed" && gen.layout == poster && gen.seed == 42 && !gen.randomSeed, "reuse restores raw prompt, boxes and seed")
    gen.layout = MossLayout()

    // 11d. re-renders carry the image's LoRAs; a batch is the leading run sharing one LoRA set; no stray mask
    let keepDir = gen.loraDir; gen.tier = "compact"; gen.loraDir = "/l"; gen.loras = ["a.safetensors", "b.safetensors"]; gen.loraState = ["a.safetensors": 0.5]
    check(gen.modelArgs() == ["--model", "compact", "--lora", "/l/a.safetensors:0.50"], "sidebar LoRA args: \(gen.modelArgs())")
    check(gen.modelArgs(Job(url: lpng, prompt: "", seed: 42, seconds: 0)) == ["--model", "compact", "--lora", "/x/style.safetensors:1.00"], "re-render takes the sidecar's LoRAs")
    check(gen.modelArgs(Job(url: tmp.appendingPathComponent("old.png"), prompt: "", seed: 0, seconds: 0)) == gen.modelArgs(), "sidecar without loras: sidebar's")
    let rs = (1...4).map { gen.currentRender(seed: $0) }, x = ["--model", "compact"], y = x + ["--lora", "/x/style.safetensors:1.00"]
    gen.pending = rs; gen.runArgs = [rs[0].output: x, rs[1].output: x, rs[2].output: y]
    let b1 = gen.takeBatch(), b2 = gen.takeBatch(), b3 = gen.takeBatch()
    check(b1.renders.map(\.seed) == [1, 2] && b1.args == x && b2.renders.map(\.seed) == [3] && b2.args == y, "leading run per LoRA set, rest waits")
    check(b3.renders.map(\.seed) == [4] && b3.args == gen.modelArgs() && gen.pending.isEmpty && gen.runArgs.isEmpty, "unregistered render runs with the sidebar's set")
    gen.tab = "i2i"; gen.layout = poster
    let masks = { (try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("masks").path).count) ?? 0 }
    let before = masks(); _ = gen.render(from: Job(url: lpng, prompt: "", seed: 42, seconds: 0))
    check(masks() == before, "render(from:) writes no mask PNG")
    gen.layout = MossLayout(); gen.loras = []; gen.loraState = [:]; gen.loraDir = keepDir
    // 11c. the layout is held in memory and persisted: a new Generator sees the saved boxes
    gen.layout = MossLayout(items: [LayoutItem(label: "text", caption: "c", text: "saved", x0: 10, y0: 10, x1: 200, y1: 80)])
    gen.layout.items[0].text = "edited in place"
    let reloaded = Generator()
    check(reloaded.layout == gen.layout && reloaded.layout.items.first?.text == "edited in place", "layout round-trips through layoutJSON")
    check(reloaded.layoutMode, "a reloaded layout with boxes turns layout mode on")
    gen.layout = MossLayout(); check(Generator().layout.items.isEmpty && !gen.layoutMode, "cleared layout persists as empty")

    // 11d. image cache: same object on repeat, reloaded when the file is rewritten
    func writePNG(_ w: Int, _ h: Int, _ url: URL) {
        let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try! r.representation(using: .png, properties: [:])!.write(to: url)
    }
    let cpng = tmp.appendingPathComponent("cache.png"); writePNG(600, 300, cpng)
    let t1 = ImageCache.thumbnail(cpng.path), f1 = ImageCache.image(cpng.path)
    check(t1 != nil && t1 === ImageCache.thumbnail(cpng.path) && f1 != nil && f1 === ImageCache.image(cpng.path), "image cache returns the same object on repeat")
    check(t1?.size == NSSize(width: 288, height: 144), "thumbnail short side is 144 px: \(t1?.size ?? .zero)")
    writePNG(300, 600, cpng)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: cpng.path)
    let t2 = ImageCache.thumbnail(cpng.path), f2 = ImageCache.image(cpng.path)
    check(t2 !== t1 && t2?.size == NSSize(width: 144, height: 288) && f2 !== f1, "image cache reloads after the file changes")
    try! FileManager.default.removeItem(at: cpng); check(ImageCache.thumbnail(cpng.path) == nil, "image cache drops a deleted file")
    // 11c. log: carriage-return progress collapses to its last state per line
    let raw = "loading\nfetching 3 files\n\rstep 1/8     2.1 s\rstep 2/8     4.0 s\rstep 8/8    15.2 s\n/out/a.png saved\r\nstep 1/8 0.5 s\rboom"
    check(LogView.readable(raw) == "loading\nfetching 3 files\nstep 8/8    15.2 s\n/out/a.png saved\nboom", "log keeps the last \\r state of each line: \(LogView.readable(raw).debugDescription)")
    check(LogView.readable("") == "" && LogView.readable("a\n\nb") == "a\n\nb", "log without \\r passes through")

    // 11d. info: full sidecar → prompt and rows
    let sideJSON = #"{"parameters":{"prompt":"{\"items\":[]}","seed":3,"width":912,"height":1152,"steps":8,"guidance":1.0,"cfg":1.5,"init_image":"/a/src.png","strength":0.6},"timings":{"total_s":35.7,"mlx_peak_memory_gb":8.02},"loras":["/l/dmd.safetensors:1.00","/l/x:y.safetensors"]}"#
    let info = InfoView.summary(try! JSONSerialization.jsonObject(with: Data(sideJSON.utf8)) as! [String: Any])
    let rowsInfo = Dictionary(uniqueKeysWithValues: info.rows)
    check(info.prompt.contains("\n") && info.prompt.contains(#""items""#), "info pretty-prints a layout prompt: \(info.prompt.debugDescription)")
    check(rowsInfo["Seed"] == "3" && rowsInfo["Size"] == "912 × 1152" && rowsInfo["CFG"] == "1.5" && rowsInfo["Strength"] == "0.6" && rowsInfo["Source"] == "src.png", "info rows: \(info.rows)")
    check(rowsInfo["LoRAs"] == "dmd.safetensors 1.00\nx:y.safetensors" && rowsInfo["Render time"] == "35.7 s" && rowsInfo["Peak memory"] == "8.02 GB", "info LoRAs and timings: \(info.rows)")
    let appSide: [String: Any] = ["app": ["prompt": "raw idea"], "parameters": ["prompt": "sent"]]
    check(InfoView.summary(appSide).prompt == "raw idea" && InfoView.summary(appSide).rows.isEmpty, "info prefers the app's raw prompt")

    // 11e. time remaining: rate from step 1 on, rest of this image plus the images after it
    check(Generator.eta(elapsed: 0, step: 1, steps: 8, after: 0) == nil, "no estimate at step 1")
    check(Generator.eta(elapsed: 12, step: 4, steps: 8, after: 0) == "~16 s left", "4 s/step, 4 steps left: \(Generator.eta(elapsed: 12, step: 4, steps: 8, after: 0) ?? "nil")")
    check(Generator.eta(elapsed: 12, step: 4, steps: 8, after: 2) == "~16 s left · ~1 min for all", "plus two 32 s images: \(Generator.eta(elapsed: 12, step: 4, steps: 8, after: 2) ?? "nil")")
    check(Generator.eta(elapsed: 5, step: 8, steps: 8, after: -1) == "~0 s left", "last step, no negative image count")
    gen.pending = []; check(gen.remaining == 0, "nothing running or queued: no badge")
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

    // 11d. a pasted image becomes a source path: bitmap data saved as PNG, image files as is, anything else nil
    let pb = NSPasteboard(name: .init("moss-checks-\(UUID().uuidString)"))
    pb.clearContents(); pb.writeObjects([img])
    if let p = gen.pastedImagePath(from: pb), let back = NSImageRep(contentsOfFile: p) {
        check(p.hasPrefix(tmp.appendingPathComponent("sources").path) && p.hasSuffix(".png"), "pasted bitmap saved under <outputDir>/sources: \(p)")
        check(back.pixelsWide == rep.pixelsWide && back.pixelsHigh == rep.pixelsHigh, "pasted PNG keeps the pixel size")
    } else { check(false, "pasted bitmap gives a readable PNG path") }
    pb.clearContents(); pb.writeObjects([png as NSURL])
    check(gen.pastedImagePath(from: pb) == png.path, "pasted image file is used in place")
    pb.clearContents(); pb.writeObjects([side as NSURL, img])
    check(gen.pastedImagePath(from: pb) == nil, "pasted non-image file is refused, not its icon")
    pb.clearContents(); pb.setString("just text", forType: .string)
    check(gen.pastedImagePath(from: pb) == nil, "pasted text is not an image")
    pb.releaseGlobally()

    // 11c. layout undo: one step per edit, a drag is one step, redo, coalesced typing
    gen.layout = MossLayout()
    for _ in 0..<60 { gen.undoLayout() }   // earlier sections (Reuse) leave steps; the stack keeps 50
    gen.layout = MossLayout()
    var e0 = gen.layout; var lu = e0; let ubox = LayoutItem(x0: 10, y0: 10, x1: 60, y1: 60); lu.items = [ubox]
    gen.layout = lu; gen.recordUndo(e0)                                                       // draw
    let drawn = gen.layout; e0 = drawn
    for dx in 1...20 { gen.item(ubox.id).wrappedValue.set(ubox.rect.offsetBy(dx: Double(dx), dy: 0)) }
    gen.recordUndo(e0)                                                                        // drag: many sets, one step
    let moved = gen.layout; e0 = moved
    gen.layout = MossLayout(); gen.recordUndo(e0)                                             // delete
    gen.recordUndo(gen.layout)                                                                // no change: no step
    gen.undoLayout(); check(gen.layout == moved, "undo restores the deleted box")
    gen.undoLayout(); check(gen.layout == drawn, "one undo reverts a whole drag")
    gen.undoLayout(); check(gen.layout.items.isEmpty, "third undo removes the drawn box")
    gen.undoLayout(); check(gen.layout.items.isEmpty, "undo past the start is a no-op")
    gen.redoLayout(); gen.redoLayout(); check(gen.layout == moved, "redo replays draw and move")
    for ch in ["a", "ab", "abc"] { e0 = gen.layout; gen.item(ubox.id).wrappedValue.caption = ch; gen.recordUndo(e0, coalesce: "caption") }
    gen.redoLayout(); check(gen.layout.items.first?.caption == "abc", "a new edit drops the redo stack")
    gen.undoLayout(); check(gen.layout == moved, "typing in one field is one undo step")
    gen.layout = MossLayout()

    // 11f. across branches: undo steps follow a size change; Reuse brings boxes onto the current canvas, as one undo step
    gen.tab = "t2i"; gen.aspect = "1:1"; gen.megapixels = 1; gen.applyPreset(); gen.layout = MossLayout()
    let blank = gen.layout
    gen.layout = MossLayout(items: [LayoutItem(label: "object", caption: "u", x0: 100, y0: 100, x1: 500, y1: 500)]); gen.recordUndo(blank)
    let sized = gen.layout; var nudged = sized; nudged.items[0].x0 = 200; gen.layout = nudged; gen.recordUndo(sized)
    gen.megapixels = 0.25; gen.applyPreset(); gen.undoLayout()
    check(gen.width == 512 && abs((gen.layout.items.first?.x0 ?? 0) - 50) < 0.01, "undo after 1 → 0.25 MP gives the box at the new scale: \(gen.layout.items.first?.rect ?? .zero)")
    let rpng = tmp.appendingPathComponent("reuse.png"), rside = tmp.appendingPathComponent("reuse.json")
    try! rep.representation(using: .png, properties: [:])!.write(to: rpng)
    let boxed = MossLayout(items: [LayoutItem(label: "object", caption: "r", x0: 100, y0: 100, x1: 300, y1: 300)])
    try! JSONSerialization.data(withJSONObject: ["parameters": ["prompt": boxed.compiled(caption: "scene", width: 1024, height: 1024),
                                                                "width": 1024, "height": 1024, "seed": 7]]).write(to: rside)
    gen.layout = MossLayout()
    gen.reuse(Job(url: rpng, prompt: "", seed: 7, seconds: 0))
    check(gen.prompt == "scene" && abs((gen.layout.items.first?.x0 ?? 0) - 50) < 1, "Reuse of a 1024² image on a 512² canvas halves its boxes: \(gen.layout.items.first?.rect ?? .zero)")
    gen.undoLayout(); check(gen.layout.items.isEmpty, "Reuse is one undo step")
    gen.layout = MossLayout()

    // 11g. live preview: --preview goes only to a CLI whose --help lists it; each step line publishes the file's
    // image, the finished image clears it, the file is deleted. Fake CLIs: one step, then the output.
    let dot = tmp.appendingPathComponent("dot.png"); writePNG(6, 4, dot)
    let savedCLI = gen.cli
    gen.tab = "t2i"; gen.prompt = "p"; gen.loras = []; gen.loraState = [:]
    for (name, help, isNew) in [("old-cli", "  --mask MASK", false), ("new-cli", "  --preview PREVIEW  live", true)] {
        let fake = tmp.appendingPathComponent(name)
        try! """
        #!/bin/zsh
        [[ $1 == --help ]] && { print -- '\(help)'; exit 0 }
        print -r -- "$*" > $0.args
        out=$(sed -E 's/.*"output":"([^"]*)".*/\\1/; s#\\\\/#/#g' $2)
        [[ $* == *--preview* ]] && cp \(dot.path) ${@[-1]}
        print -u2 'step 1/2'; sleep 1; cp \(dot.path) $out; print $out
        """.write(to: fake, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        check(Generator.supportsPreview(fake.path) == isNew, "\(name): --help \(isNew ? "lists" : "lacks") --preview")
        gen.cli = fake.path; Generator.previewSupport[fake.path] = isNew
        gen.enqueue([gen.currentRender(seed: 1)])
        var shown: NSImage?
        let until = Date().addingTimeInterval(10)
        while gen.running, Date() < until { shown = shown ?? gen.preview; await Task.sleep(seconds: 0.05) }
        let args = (try? String(contentsOfFile: fake.path + ".args", encoding: .utf8)) ?? ""
        let sent = args.split(separator: " ").last.map(String.init) ?? ""
        check(args.contains("--preview") == isNew && gen.status == "Done", "\(name): --preview \(isNew ? "sent" : "not sent"), batch done: \(args) \(gen.status)")
        check((shown?.size == NSSize(width: 6, height: 4)) == isNew, "\(name): preview \(isNew ? "published during the step" : "never shown"): \(shown?.size ?? .zero)")
        check(gen.preview == nil && (!isNew || !FileManager.default.fileExists(atPath: sent)), "\(name): preview cleared and its file deleted after the batch")
    }
    gen.cli = savedCLI

    // 12. live paths, only when the venv is present (MOSS_CHECKS_OFFLINE=1 skips them). MOSS_CLI=path picks another moss-mlx.
    let cli = ProcessInfo.processInfo.environment["MOSS_CLI"] ?? gen.cli
    if FileManager.default.isExecutableFile(atPath: cli), ProcessInfo.processInfo.environment["MOSS_CHECKS_OFFLINE"] == nil {
        gen.cli = cli; let previews = Generator.supportsPreview(cli); Generator.previewSupport[cli] = previews
        // a real batch through the Generator: two 512² renders, one process, both files reported on stdout
        gen.tab = "t2i"; gen.layout = MossLayout(); gen.loras = []; gen.loraState = [:]
        gen.prompt = "A simple street sign that reads \"HELLO MLX\" on a blue sky"; gen.width = 512; gen.height = 512; gen.aspect = "custom"
        gen.steps = 8; gen.guidance = 1; gen.tier = "compact"
        gen.refreshLoras(); if gen.loras.contains("MOSS-Image-SFT-8-steps-dmd.safetensors") { gen.enable("MOSS-Image-SFT-8-steps-dmd.safetensors", scale: 1) }
        let before = gen.jobs.count
        gen.enqueue([gen.currentRender(seed: 1), gen.currentRender(seed: 2)])
        check(gen.running, "batch started")
        let deadline = Date().addingTimeInterval(240)
        var live: NSImage?
        while gen.running, Date() < deadline { live = live ?? gen.preview; await Task.sleep(seconds: 0.2) }
        check(!gen.running, "batch finished within 4 min: \(gen.status)")
        if previews {
            check(live?.size == NSSize(width: 32, height: 32) && gen.preview == nil, "a 32×32 preview was written and shown during the batch, cleared after: \(live?.size ?? .zero)")
        } else { print("skip  \(cli) has no --preview (src without patch 0006)") }
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
        gen.cli = savedCLI
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
