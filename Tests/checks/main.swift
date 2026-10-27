// Headless checks against the app's own sources. Run: ./tests.sh
import AppKit
import SwiftUI

var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }

@MainActor func run() async {
    UserDefaults.standard.removeObject(forKey: "cli")   // the default engine home, not a fake CLI an aborted run left behind
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
    let requestFields = Set("prompt negative_prompt width height steps guidance shift seed uncond_skip_layers slg_layers slg_scale slg_start slg_stop max_sequence_length init_image strength mask mask_feather preview references reference_size rgba keep_alpha edit_format vision_pixels control_color control_depth control_end".split(separator: " ").map(String.init)) .union(["output"])
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
    // hold Space: the original replaces the working image on the canvas, only once an edit has replaced it
    gen.tab = "i2i"; gen.comparing = true
    check(!gen.canCompare && !gen.showsOriginal && gen.canvasSource == src.path, "Space before any edit: nothing to compare, working image stays")
    gen.initImage = "/tmp/edit.png"
    check(gen.showsOriginal && gen.canvasSource == src.path, "Space held after an edit: canvas shows the original")
    gen.comparing = false
    check(!gen.showsOriginal && gen.canvasSource == "/tmp/edit.png", "Space let go: canvas shows the working image again")
    gen.comparing = true; gen.tab = "t2i"
    check(!gen.showsOriginal, "no comparing outside the Image tab")
    gen.comparing = false; gen.initImage = src.path

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

    // 8c. Edit tab: the picture goes as a reference, the prompt as typed, boxes ignored, the edit adapter rides along
    gen.layout = MossLayout(items: [LayoutItem(label: "text", caption: "", text: "HI", x0: 400, y0: 400, x1: 600, y1: 500)])
    gen.tab = "edit"; gen.setSource(src.path); gen.editModel = "chinoll"; gen.prompt = "Make the wall blue"
    let r4 = gen.currentRender(seed: 1)
    check(r4.references == [gen.initImage] && r4.init_image == nil && r4.mask == nil && r4.strength == 1, "instruction: a reference, no init or mask")
    check(r4.prompt == "Make the wall blue" && !gen.isBoxEdit && !gen.outpainting, "instruction: prompt as typed, boxes not used: \(r4.prompt)")
    check(gen.modelArgs().contains(Generator.editAdapter.path), "instruction: the edit adapter goes as --lora")
    let j4 = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(r4)) as! [String: Any]
    check(Set(j4.keys).isSubset(of: requestFields) && j4["rgba"] == nil, "instruction JSON keys ⊆ Request fields: \(j4.keys.sorted())")
    // edit model: chinoll sends nothing new (older engines keep working); Edit-HQ its adapter, ai-toolkit and 512² vision
    check(gen.editModel == "chinoll" && j4["edit_format"] == nil && j4["vision_pixels"] == nil, "MOSS Image Edit: no edit_format, no vision_pixels")
    gen.editModel = "hq"
    let hq = gen.currentRender(seed: 1), jhq = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(hq)) as! [String: Any]
    check(jhq["edit_format"] as? String == "ai-toolkit" && jhq["vision_pixels"] as? Int == 262144 && Set(jhq.keys).isSubset(of: requestFields),
          "Edit-HQ: edit_format ai-toolkit, vision_pixels 512²: \(jhq.keys.sorted())")
    check(gen.modelArgs().contains(Generator.editHQAdapter.path) && !gen.modelArgs().contains(Generator.editAdapter.path)
          && gen.neededAdapters.contains(Generator.editHQAdapter), "Edit-HQ: its adapter goes as --lora instead of chinoll's, fetched on first use")
    let hqPng = tmp.appendingPathComponent("hq-out.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: hqPng)
    for (fmt, px) in [("ai-toolkit", 262144), ("chinoll", 147456)] {   // the CLI writes both fields into every sidecar
        try! JSONSerialization.data(withJSONObject: ["parameters": ["prompt": "p", "seed": 3, "width": 512, "height": 512, "references": [gen.initImage],
                                                                    "edit_format": fmt, "vision_pixels": px]])
            .write(to: hqPng.deletingPathExtension().appendingPathExtension("json"))
        let back = gen.render(from: Job(url: hqPng, prompt: "", seed: 3, seconds: 0))
        check(fmt == "chinoll" ? back?.edit_format == nil && back?.vision_pixels == nil : back?.edit_format == fmt && back?.vision_pixels == px,
              "render(from:) of a \(fmt) edit: \(String(describing: back?.edit_format)) \(String(describing: back?.vision_pixels))")
    }
    gen.tab = "i2i"
    check(gen.currentRender(seed: 1).edit_format == nil && !gen.modelArgs().contains(Generator.editHQAdapter.path), "Edit-HQ chosen, strength edit: no edit format, no HQ adapter")
    gen.tab = "edit"; gen.editModel = "chinoll"
    // more pictures: the source stays picture 1, added ones follow in order, at most 4, removable, no duplicates
    let refPaths = (2...5).map { tmp.appendingPathComponent("ref\($0).png").path }
    for p in refPaths { try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: p)) }
    gen.extraReferences = []; gen.status = ""
    gen.addReference(refPaths[0]); gen.addReference(refPaths[1]); gen.addReference(refPaths[0]); gen.addReference(gen.initImage)
    check(gen.currentRender(seed: 1).references == [gen.initImage, refPaths[0], refPaths[1]], "references: source first, then in the order added, duplicates ignored")
    gen.addReference(refPaths[2]); gen.addReference(refPaths[3])
    check(gen.references.count == Generator.maxReferences && !gen.references.contains(refPaths[3]) && gen.status.contains("Up to 4"), "references: the 5th is refused with a message: \(gen.status)")
    gen.removeReference(refPaths[1])
    check(gen.references == [gen.initImage, refPaths[0], refPaths[2]], "references: removing one keeps the others in order")
    gen.removeReference(gen.initImage); check(gen.references.first == gen.initImage, "references: the source cannot be removed as a reference")
    gen.tab = "i2i"; gen.addReference(refPaths[3])
    check(gen.tab == "edit" && gen.instructing && gen.references.last == refPaths[3], "adding a reference switches to the Edit tab")
    let r6 = gen.currentRender(seed: 1)
    let j6 = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(r6)) as! [String: Any]
    check(j6["references"] as? [String] == [gen.initImage, refPaths[0], refPaths[2], refPaths[3]], "references go out as one ordered JSON list")
    // a re-render from the sidecar keeps every reference; trashing it keeps the reference files
    let refsPng = tmp.appendingPathComponent("refs-out.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: refsPng)
    try! JSONSerialization.data(withJSONObject: ["parameters": ["prompt": "p", "seed": 3, "width": 512, "height": 512, "references": r6.references!]])
        .write(to: refsPng.deletingPathExtension().appendingPathExtension("json"))
    let rjob = Job(url: refsPng, prompt: "", seed: 3, seconds: 0)
    check(gen.render(from: rjob)?.references == r6.references, "render(from:) keeps all references in order")
    gen.trash(rjob)
    check(r6.references!.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "trashing an edit leaves its reference files alone")
    gen.setSource(refPaths[0]); check(gen.references.first == refPaths[0] && gen.references.filter { $0 == refPaths[0] }.count == 1, "a reference made the source is not also picture 2")
    gen.setSource(src.path); gen.extraReferences = [refPaths[0]]; gen.status = ""
    gen.tab = "i2i"
    check(gen.currentRender(seed: 1).references == nil && gen.currentRender(seed: 1).edit_format == nil && !gen.modelArgs().contains(Generator.editAdapter.path),
          "Image tab with pictures added on Edit: no reference, no edit format, no edit adapter (references live on the Edit tab)")
    gen.extraReferences = []
    // 8d. transparent source: "Keep transparency" sends keep_alpha for edits of a source with transparent pixels only
    check(!gen.sourceHasAlpha && gen.currentRender(seed: 1).keep_alpha == nil, "opaque source: no keep_alpha")
    let cut = tmp.appendingPathComponent("cutout.png"), opaqueAlpha = tmp.appendingPathComponent("opaque-alpha.png")
    func rgbaPNG(opaqueWidth: Int, _ url: URL) {   // 64×32, opaque red up to opaqueWidth, transparent after; alpha channel either way
        let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<32 { for x in 0..<opaqueWidth { r.bitmapData![y * r.bytesPerRow + x * 4] = 255; r.bitmapData![y * r.bytesPerRow + x * 4 + 3] = 255 } }
        try! r.representation(using: .png, properties: [:])!.write(to: url)
    }
    rgbaPNG(opaqueWidth: 32, cut); rgbaPNG(opaqueWidth: 64, opaqueAlpha)
    check(Generator.hasAlpha(cut.path) && !Generator.hasAlpha(opaqueAlpha.path), "hasAlpha: transparent pixels count, an all-opaque alpha channel does not")
    gen.setSource(cut.path); gen.keepAlpha = true; gen.tab = "edit"; gen.setSource(cut.path)
    let ka = gen.currentRender(seed: 1), jka = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(ka)) as! [String: Any]
    check(ka.keep_alpha == true && ka.references?.first == cut.path && Set(jka.keys).isSubset(of: requestFields), "instruction edit of a cutout: keep_alpha with picture 1 = the cutout: \(jka.keys.sorted())")
    gen.tab = "i2i"
    check(gen.currentRender(seed: 1).keep_alpha == true && gen.currentRender(seed: 1).init_image == cut.path, "strength edit of a cutout: keep_alpha too (kept pixels keep their alpha)")
    gen.pad = Pad(left: 0.25); check(gen.outpainting && gen.currentRender(seed: 1).keep_alpha == nil, "extending: no keep_alpha"); gen.pad = Pad()
    gen.keepAlpha = false; check(gen.currentRender(seed: 1).keep_alpha == nil, "Keep transparency off: no keep_alpha")
    gen.keepAlpha = true; gen.tab = "t2i"; check(gen.currentRender(seed: 1).keep_alpha == nil, "Text tab: no keep_alpha"); gen.tab = "i2i"
    let kaPng = tmp.appendingPathComponent("ka-out.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: kaPng)
    try! JSONSerialization.data(withJSONObject: ["parameters": ["prompt": "p", "seed": 3, "width": 512, "height": 256, "references": [cut.path], "keep_alpha": true]])
        .write(to: kaPng.deletingPathExtension().appendingPathExtension("json"))
    check(gen.render(from: Job(url: kaPng, prompt: "", seed: 3, seconds: 0))?.keep_alpha == true, "render(from:) keeps keep_alpha")
    gen.setSource(src.path)

    // 8e. the Edit tab keeps its own picture, original and prompt; Text and Image share theirs
    gen.layout = MossLayout(); gen.megapixels = 1; gen.prompt = "a quiet street"
    gen.tab = "edit"; gen.setSource(cut.path); gen.prompt = "Make it blue"
    check(gen.aspect == "source" && abs(Double(gen.width) / Double(gen.height) - 2) < 0.03, "Edit tab: the output follows its picture's aspect (2:1): \(gen.width)x\(gen.height)")
    gen.tab = "t2i"; check(gen.prompt == "a quiet street" && !gen.usingSource, "Text tab: its own prompt back, no picture used")
    gen.tab = "i2i"
    check(gen.initImage == src.path && gen.originalSource == src.path && gen.prompt == "a quiet street" && abs(Double(gen.width) / Double(gen.height) - 1.5) < 0.03,
          "Image tab: its source, original, prompt and 3:2 size are as left: \(gen.initImage) \(gen.width)x\(gen.height)")
    gen.tab = "edit"
    check(gen.initImage == cut.path && gen.originalSource == cut.path && gen.prompt == "Make it blue" && abs(Double(gen.width) / Double(gen.height) - 2) < 0.03,
          "Edit tab: its picture, original, prompt and size are as left")
    // "Edit this picture" on a result: the Edit tab with it as picture 1; the Image tab's source stays
    gen.tab = "t2i"; gen.editPicture(opaqueAlpha.path)
    check(gen.tab == "edit" && gen.initImage == opaqueAlpha.path && gen.originalSource == opaqueAlpha.path && gen.instructing
          && gen.currentRender(seed: 1).references?.first == opaqueAlpha.path, "Edit this picture: Edit tab, picture 1, an instruction edit")
    gen.tab = "i2i"; check(gen.initImage == src.path, "Edit this picture leaves the Image tab's source alone")
    gen.tab = "t2i"; gen.startEdit(src.path); check(gen.tab == "i2i", "a drop or paste on the Text tab still starts on the Image tab")
    gen.tab = "edit"; gen.startEdit(cut.path); check(gen.tab == "edit" && gen.initImage == cut.path, "a drop or paste on the Edit tab replaces its picture")
    // guards: no picture, then no instruction
    gen.pending = []; gen.status = ""; gen.initImage = ""; gen.prompt = "Make it red"; gen.generate()
    check(gen.status == "Choose a picture to edit first." && gen.pending.isEmpty && !gen.instructing, "Edit tab without a picture: says so, nothing queued")
    gen.setSource(src.path); gen.prompt = "  \n"; gen.generate()
    check(gen.status == "Say what to change first." && gen.pending.isEmpty, "Edit tab without an instruction: says so, nothing queued")
    gen.quality = "turbo"
    check(gen.effectiveQuality == "draft" && gen.currentRender(seed: 1).references == [src.path], "Edit tab: Turbo renders as Draft"); gen.quality = "draft"
    // the result becomes picture 1 and the next edit starts from it; the original stays for Space (fake CLI: hands back picture 1)
    if FileManager.default.fileExists(atPath: Generator.editHQAdapter.path) {   // else generate() would download 500 MB
        let fakeEdit = tmp.appendingPathComponent("edit-cli"), savedEditCLI = gen.cli, (savedLoras, savedState) = (gen.loras, gen.loraState)
        try! """
        #!/bin/zsh
        [[ $1 == --help ]] && exit 0
        line=$(cat $2); out=$(sed -E 's/.*"output":"([^"]*)".*/\\1/; s#\\\\/#/#g' <<< $line)
        cp $(sed -E 's/.*"references":\\["([^"]*)".*/\\1/; s#\\\\/#/#g' <<< $line) $out
        print -r -- "{\\"parameters\\":$line}" > ${out%.png}.json; print $out
        """.write(to: fakeEdit, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeEdit.path)
        gen.cli = fakeEdit.path; Generator.previewSupport[fakeEdit.path] = false; gen.loras = []; gen.loraState = [:]
        gen.editModel = "hq"; gen.prompt = "Make the wall blue"
        func waitForBatch() async { let until = Date().addingTimeInterval(10); while gen.running || !gen.pending.isEmpty, Date() < until { await Task.sleep(seconds: 0.05) } }
        gen.generate(); await waitForBatch()
        let first = gen.jobs.first?.url.path ?? ""
        check(gen.initImage == first && first != src.path && gen.originalSource == src.path && gen.canCompare, "an edit's result becomes picture 1, the original stays: \(gen.status)")
        gen.comparing = true; check(gen.showsOriginal && gen.canvasSource == src.path, "Space held on the Edit tab shows the original"); gen.comparing = false
        gen.generate(); await waitForBatch()
        check(gen.sidecar(gen.jobs[0].url)?["references"] as? [String] == [first] && gen.initImage == gen.jobs[0].url.path, "the next edit starts from the previous result")
        gen.tab = "i2i"; check(gen.initImage == src.path, "edit results do not replace the Image tab's source")
        gen.cli = savedEditCLI; gen.loras = savedLoras; gen.loraState = savedState
    } else { print("skip  no Edit-HQ adapter at \(Generator.editHQAdapter.path)") }
    // a new install edits with Edit-HQ; an install from before the Edit tab that was on "Edit by: Instruction" lands on
    // the Edit tab with its source, prompt and edit model; any other stored edit mode is just dropped
    let defs = UserDefaults.standard
    defs.removeObject(forKey: "editModel"); defs.removeObject(forKey: "editMode")
    check(Generator().editModel == "hq" && Generator().chosenEdit == Generator.editModels["hq"], "a new install edits with Edit-HQ v5")
    gen.tab = "i2i"; gen.setSource(src.path); gen.prompt = "Make the wall blue"
    defs.set("retouch", forKey: "editMode"); let dropped = Generator()
    check(dropped.tab == "i2i" && defs.object(forKey: "editMode") == nil, "a stored Strength edit mode is dropped, the tab stays")
    defs.set("instruct", forKey: "editMode"); let migrated = Generator()
    check(migrated.tab == "edit" && migrated.initImage == src.path && migrated.originalSource == src.path && migrated.prompt == "Make the wall blue"
          && migrated.instructing && migrated.editModel == "chinoll" && defs.object(forKey: "editMode") == nil,
          "a stored Instruction edit mode lands on the Edit tab with its source, prompt and chinoll's model: \(migrated.tab) \(migrated.initImage)")
    migrated.tab = "i2i"; check(migrated.initImage == src.path && migrated.prompt == "Make the wall blue", "after the move the Image tab keeps the source too")
    defs.set("hq", forKey: "editModel"); defs.set("instruct", forKey: "editMode"); defs.set("i2i", forKey: "tab")
    check(Generator().editModel == "hq", "a migrated install keeps an edit model it had chosen")
    defs.set("i2i", forKey: "tab")
    gen.tab = "i2i"; gen.setSource(src.path)
    // transparent output: Text tab only, the trigger added once, rgba, the alpha adapter
    gen.layout = MossLayout(); gen.transparent = true; gen.tab = "t2i"; gen.prompt = "a brass key"
    let r5 = gen.currentRender(seed: 1)
    check(r5.rgba == true && r5.prompt == "a brass key, isolated on a transparent background", "transparent: rgba and trigger: \(r5.prompt)")
    check(gen.modelArgs().contains(Generator.alphaAdapter.path), "transparent: the alpha adapter goes as --lora")
    gen.prompt = "a key on a transparent background"
    check(gen.effectivePrompt == gen.prompt, "transparent: trigger not added when the prompt already asks for it")
    // with boxes the trigger ends the summary caption (where a plain caption would have it), once, not in the item captions
    gen.prompt = "a sticker logo"
    gen.layout = MossLayout(items: [LayoutItem(label: "object", caption: "a fox head", x0: 0, y0: 0, x1: 100, y1: 100),
                                    LayoutItem(label: "text", caption: "bold letters", text: "MOSS", x0: 0, y0: 120, x1: 200, y1: 200)])
    let r7 = gen.currentRender(seed: 1)
    let summary = (try? JSONSerialization.jsonObject(with: Data(r7.prompt.utf8)) as? [String: Any])?["summary"] as? [String: Any]
    check(r7.rgba == true && summary?["caption"] as? String == "a sticker logo" + Generator.alphaTrigger, "transparent layout: trigger ends summary.caption: \(r7.prompt)")
    check(r7.prompt.components(separatedBy: "transparent background").count == 2, "transparent layout: trigger sent once, not in the boxes")
    gen.layout = MossLayout()
    gen.tab = "i2i"
    check(gen.currentRender(seed: 1).rgba == nil && !gen.modelArgs().contains(Generator.alphaAdapter.path), "transparent is Text-tab only")
    gen.transparent = false; gen.prompt = ""

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
    // the tier: recorded in "app" when queued, re-renders take it, older sidecars fall back to the current one
    gen.running = true   // queue only, no process
    gen.enqueue([gen.currentRender(seed: 7)])
    check(gen.pending.last.flatMap { gen.appInfo[$0.output]?.tier } == "compact", "new render records the current tier")
    Generator.merge(AppInfo(prompt: "a poster, moss_vgouache_style kept as typed", layout: poster, tier: "8bit"), intoSidecarOf: lpng.path)
    check((gen.sidecarRoot(lpng)?["app"] as? [String: Any])?["tier"] as? String == "8bit", "merge writes the tier")
    gen.variations(of: Job(url: lpng, prompt: "", seed: 42, seconds: 0), count: 1)
    check(gen.pending.last.map { gen.runArgs[$0.output] == ["--model", "8bit", "--lora", "/x/style.safetensors:1.00"] && gen.appInfo[$0.output]?.tier == "8bit" } == true,
          "re-render takes the sidecar's tier, not the current one")
    gen.rerender(Job(url: tmp.appendingPathComponent("old.png"), prompt: "", seed: 0, seconds: 0), megapixels: 1)
    check(gen.pending.last.map { gen.runArgs[$0.output]?.prefix(2) == ["--model", "compact"] && gen.appInfo[$0.output]?.tier == "compact" } == true,
          "sidecar without a tier: the current one")
    gen.running = false; gen.pending = []; gen.runArgs = [:]; gen.appInfo = [:]
    let rs = (1...4).map { gen.currentRender(seed: $0) }, x = ["--model", "compact"], y = x + ["--lora", "/x/style.safetensors:1.00"]
    gen.pending = rs; gen.runArgs = [rs[0].output: x, rs[1].output: x, rs[2].output: y]
    let b1 = gen.takeBatch(), b2 = gen.takeBatch(), b3 = gen.takeBatch()
    check(b1.renders.map(\.seed) == [1, 2] && b1.args == x && b2.renders.map(\.seed) == [3] && b2.args == y, "leading run per LoRA set, rest waits")
    check(b3.renders.map(\.seed) == [4] && b3.args == gen.modelArgs() && gen.pending.isEmpty && gen.runArgs.isEmpty, "unregistered render runs with the sidebar's set")
    gen.tab = "i2i"; gen.layout = poster
    let masks = { (try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("masks").path).count) ?? 0 }
    let before = masks(); _ = gen.render(from: Job(url: lpng, prompt: "", seed: 42, seconds: 0))
    check(masks() == before, "render(from:) writes no mask PNG")
    // 11e. tiers: repo per tier, every tier has a download size and a name; a tier no longer offered falls back to compact
    check(Generator.tierRepos == ["compact": "VisualInference/MOSS-Image-SFT-MLX-compact", "8bit": "VisualInference/MOSS-Image-SFT-MLX-8bit"],
          "tier → repo: \(Generator.tierRepos)")
    check(Generator.tierSizes == ["compact": "12 GB", "8bit": "14 GB"] && Set(Generator.tierNames.keys) == Set(Generator.tierRepos.keys),
          "download sizes as upstream's table (12.1 / 14.1 GB), a name per tier")
    gen.loraState = [:]; gen.tier = "8bit"
    check(gen.modelArgs() == ["--model", "8bit"], "8-bit tier sends its name: \(gen.modelArgs())")
    gen.running = true; gen.enqueue([gen.currentRender(seed: 3)])   // queue only, no process
    check(gen.pending.last.flatMap { gen.appInfo[$0.output]?.tier } == "8bit", "an 8-bit render records its tier for re-renders")
    gen.tier = "compact"
    Generator.merge(AppInfo(prompt: "a poster, moss_vgouache_style kept as typed", layout: poster, tier: "retired-tier"), intoSidecarOf: lpng.path)
    gen.enqueue([gen.currentRender(seed: 4)], from: Job(url: lpng, prompt: "", seed: 42, seconds: 0))
    check(gen.pending.last.map { gen.runArgs[$0.output]?.prefix(2) == ["--model", "compact"] && gen.appInfo[$0.output]?.tier == "compact" } == true,
          "a sidecar's tier no longer offered re-renders with the current one")
    Generator.merge(AppInfo(prompt: "a poster, moss_vgouache_style kept as typed", layout: poster, tier: "8bit"), intoSidecarOf: lpng.path)
    gen.running = false; gen.pending = []; gen.runArgs = [:]; gen.appInfo = [:]
    UserDefaults.standard.set("retired-tier", forKey: "tier")
    check(Generator().tier == "compact" && UserDefaults.standard.string(forKey: "tier") == "compact", "a stored tier no longer offered comes back as compact")
    // known adapters: the 4-step ones set 4 steps, CFG 1; every few-step one is a Draft adapter
    let four = knownLoras.first { $0.id == "sft4" }!, fourName = Generator.loraName(repo: four.repo, file: four.file)
    check(fourName == "akhaliq__MOSS-Image-SFT-4-steps.safetensors", "library name distinct from the SFT DMD's")
    check(Generator.fewStep == Set(["MOSS-Image-SFT-8-steps-dmd.safetensors", "lodestones__MOSS-Image-SFT-8-steps-dmd.safetensors",
                                    "lodestones__MOSS-Image-SFT-8-steps-dmd__lora_latest.safetensors", fourName,
                                    "darask0__MOSS-Image_4-step_adapter_lora.safetensors"]), "few-step adapters: \(Generator.fewStep)")
    let keepSampling = (gen.steps, gen.guidance)
    gen.tier = "compact"; gen.loraState = [fourName: 1]; gen.apply(four)
    check(gen.loraState[fourName] == 1 && gen.steps == 4 && gen.guidance == 1, "4-step adapter: 4 steps, CFG 1")
    gen.apply(knownLoras.first { $0.id == "dmd8-latest" }!)
    check(gen.loraState["lodestones__MOSS-Image-SFT-8-steps-dmd__lora_latest.safetensors"] == 0.7, "dmd8-latest at the author's 0.7")
    // 11f. Quality: the args and sampling each one sends; Turbo/Full skip the DMD; edits fall back to Draft
    let dmd = "MOSS-Image-SFT-8-steps-dmd.safetensors", dmdSpec = "/l/" + dmd + ":1.00", style = "/l/style.safetensors:0.80"
    let keepQuality = gen.quality
    gen.tier = "compact"; gen.tab = "t2i"; gen.transparent = false; gen.layout = MossLayout()
    gen.loras = [dmd, "style.safetensors"]; gen.loraState = ["style.safetensors": 0.8]
    gen.quality = "full"; gen.quality = "draft"
    check(gen.loraState[dmd] == 1 && gen.steps == 8 && gen.guidance == 1, "Draft turns the DMD on when no few-step adapter is: 8 steps, CFG 1")
    var qr = gen.currentRender(seed: 1)
    check(gen.modelArgs() == ["--model", "compact", "--lora", dmdSpec, "--lora", style] && qr.steps == 8 && qr.guidance == 1, "Draft args: \(gen.modelArgs())")
    gen.quality = "turbo"; qr = gen.currentRender(seed: 1)
    check(gen.modelArgs() == ["--model", "compact", "--lora", style, "--turbo"] && qr.guidance == 3 && qr.init_image == nil && qr.references == nil,
          "Turbo: DMD left out, other LoRAs kept, --turbo, CFG 3: \(gen.modelArgs())")
    check(gen.loraState[dmd] == 1, "Turbo leaves the DMD on in the library")
    gen.quality = "full"; qr = gen.currentRender(seed: 1)
    check(gen.modelArgs() == ["--model", "compact", "--lora", style, "--lora", Generator.destripe.path + ":1.50"] && qr.steps == 50 && qr.guidance == 3,
          "Full: 50 steps, CFG 3, DMD out, destripe in: \(gen.modelArgs())")
    check(gen.neededAdapters == [Generator.destripe] && Generator.destripe.path.hasSuffix("/adapters/nynxz__MOSS-Image/loras/moss_sft_destripe_top64_bf16.safetensors"),
          "Full downloads destripe into the repo's folder layout")
    gen.steps = 30; qr = gen.currentRender(seed: 1)
    check(qr.steps == 30, "Full's steps stay editable")
    gen.quality = "turbo"; gen.tab = "i2i"; gen.initImage = "/x/src.png"
    qr = gen.currentRender(seed: 1)
    check(gen.effectiveQuality == "draft" && !gen.modelArgs().contains("--turbo") && gen.modelArgs().contains("--lora") && gen.modelArgs()[3] == dmdSpec
          && qr.steps == 8 && qr.guidance == 1 && qr.init_image == "/x/src.png", "Turbo on an edit renders as Draft: \(gen.modelArgs())")
    gen.tab = "t2i"; gen.initImage = ""; gen.tier = "8bit"
    check(gen.effectiveQuality == "turbo" && gen.modelArgs() == ["--model", "8bit", "--lora", style, "--turbo"], "Turbo on 8-bit: \(gen.modelArgs())")
    gen.quality = "full"
    check(gen.modelArgs().contains(Generator.destripe.path + ":1.50") && gen.neededAdapters == [Generator.destripe], "Full on 8-bit: destripe too")
    // different qualities never share a batch; the sidecar keeps the quality for re-renders
    gen.tier = "compact"; gen.running = true; gen.pending = []; gen.runArgs = [:]; gen.appInfo = [:]
    gen.quality = "draft"; gen.enqueue([gen.currentRender(seed: 1)]); gen.quality = "turbo"; gen.enqueue([gen.currentRender(seed: 2)])
    check(gen.pending.map { gen.appInfo[$0.output]?.quality } == ["draft", "turbo"], "each render records its quality")
    let qb1 = gen.takeBatch(), qb2 = gen.takeBatch()
    check(qb1.renders.map(\.seed) == [1] && !qb1.args.contains("--turbo") && qb2.renders.map(\.seed) == [2] && qb2.args.last == "--turbo", "Draft and Turbo run as separate batches")
    gen.quality = "draft"
    Generator.merge(AppInfo(prompt: "p", tier: "compact", quality: "turbo"), intoSidecarOf: lpng.path)
    gen.variations(of: Job(url: lpng, prompt: "", seed: 42, seconds: 0), count: 1)
    check(gen.pending.last.map { gen.runArgs[$0.output] == ["--model", "compact", "--lora", "/x/style.safetensors:1.00", "--turbo"] && gen.appInfo[$0.output]?.quality == "turbo" } == true,
          "a Turbo image's variations stay Turbo while the sidebar is on Draft")
    Generator.merge(AppInfo(prompt: "p", tier: "compact"), intoSidecarOf: lpng.path)
    gen.quality = "turbo"
    check(gen.modelArgs(Job(url: lpng, prompt: "", seed: 42, seconds: 0)) == ["--model", "compact", "--lora", "/x/style.safetensors:1.00"],
          "sidecar without a quality: its adapters, no --turbo")
    check((try? JSONDecoder().decode(AppInfo.self, from: Data(#"{"prompt":"old"}"#.utf8)))?.quality == nil, "older app info decodes, quality nil")
    gen.running = false; gen.pending = []; gen.runArgs = [:]; gen.appInfo = [:]; gen.initImage = ""
    gen.quality = keepQuality
    gen.layout = MossLayout(); gen.loras = []; gen.loraState = [:]; gen.loraDir = keepDir; (gen.steps, gen.guidance) = keepSampling
    // 11g. colour/depth control: "Regions from boxes" paints each box its colour into a map at output size (black
    // elsewhere, later boxes on top); imported maps; Control end per quality; --control; Turbo → Draft; re-renders keep it
    gen.tab = "t2i"; gen.tier = "compact"; gen.aspect = "custom"; gen.width = 1024; gen.height = 768; gen.quality = "full"; gen.quality = "draft"
    gen.layout = MossLayout(items: [LayoutItem(label: "character", caption: "a man in a blue coat", x0: 37, y0: 101, x1: 413, y1: 731),
                                    LayoutItem(label: "object", caption: "a red bicycle", x0: 590, y0: 380, x1: 1001, y1: 702),
                                    LayoutItem(label: "object", caption: "a lamp", x0: 350, y0: 50, x1: 450, y1: 200)])
    gen.regionControl = false; gen.controlColor = ""; gen.controlDepth = ""
    var cr = gen.currentRender(seed: 1)
    check(!gen.controlling && cr.control_color == nil && cr.control_end == nil && !gen.modelArgs().contains("--control"), "control off by default: no maps, no --control")
    check(Set((0..<12).map { "\(Generator.regionColor($0))" }).count == 12 && "\(Generator.regionColor(0))" == "\((r: UInt8(255), g: UInt8(0), b: UInt8(0)))",
          "12 boxes get 12 distinct region colours, the first pure red")
    gen.regionControl = true; cr = gen.currentRender(seed: 1)
    check(gen.controlling && cr.control_end == 0.25 && cr.control_depth == nil && gen.modelArgs().suffix(2) == ["--control", Generator.controlAdapter.path],
          "Regions from boxes on Draft: control_end 0.25, --control with the adapter: \(gen.modelArgs().suffix(2))")
    check(Generator.controlAdapter.path.hasSuffix("/adapters/darask0__MOSS-Image-color-depth-control/moss-control.safetensors")
          && gen.neededAdapters.contains(Generator.controlAdapter), "control adapter downloads on first use into adapters/")
    let cj = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(cr)) as! [String: Any]
    check(Set(cj.keys).isSubset(of: requestFields) && cj["control_color"] as? String == cr.control_color, "control JSON keys ⊆ Request fields: \(cj.keys.sorted())")
    if let cp = cr.control_color, let cb = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: cp))) ?? Data()) {
        check(cp.hasPrefix(tmp.appendingPathComponent("masks").path + "/") && cb.pixelsWide == 1024 && cb.pixelsHigh == 768, "colour map is output-sized, with the masks: \(cb.pixelsWide)x\(cb.pixelsHigh)")
        func px(_ x: Int, _ y: Int) -> [Int] { var p = [Int](repeating: 0, count: 4); cb.getPixel(&p, atX: x, y: y); return Array(p.prefix(3)) }
        func rgb(_ i: Int) -> [Int] { let c = Generator.regionColor(i); return [Int(c.r), Int(c.g), Int(c.b)] }
        check(px(37, 101) == rgb(0) && px(412, 730) == rgb(0) && px(200, 400) == rgb(0), "box 1 painted in colour 0 to its exact edges: \(px(37, 101))")
        check(px(590, 380) == rgb(1) && px(1000, 701) == rgb(1) && px(800, 500) == rgb(1), "box 2 painted in colour 1: \(px(800, 500))")
        check(px(400, 150) == rgb(2) && px(360, 60) == rgb(2), "a later box paints over an earlier one where they overlap")
        check(px(36, 400) == [0, 0, 0] && px(413, 400) == [0, 0, 0] && px(200, 100) == [0, 0, 0] && px(200, 731) == [0, 0, 0]
              && px(589, 500) == [0, 0, 0] && px(1001, 500) == [0, 0, 0] && px(500, 740) == [0, 0, 0] && px(1023, 0) == [0, 0, 0], "outside the boxes is black")
        // every pixel is black or one of the three colours: no blended edges
        let ids = Set([[0, 0, 0], rgb(0), rgb(1), rgb(2)])
        check(stride(from: 0, to: 1024, by: 7).allSatisfy { x in stride(from: 0, to: 768, by: 5).allSatisfy { ids.contains(px(x, $0)) } }, "flat colours only, no antialiased edges")
    } else { check(false, "colour map PNG readable") }
    gen.quality = "full"; check(gen.currentRender(seed: 1).control_end == 0.5, "Full presets Control end 0.5")
    gen.controlEnd = 0.7; check(gen.currentRender(seed: 1).control_end == 0.7, "Control end stays editable")
    gen.quality = "turbo"
    check(gen.effectiveQuality == "draft" && !gen.modelArgs().contains("--turbo") && gen.modelArgs().contains("--control") && gen.currentRender(seed: 1).control_end == 0.25,
          "Turbo with control renders as Draft, control end 0.25: \(gen.modelArgs())")
    gen.quality = "draft"
    gen.controlColor = "/x/colour.png"; gen.controlDepth = "/x/depth.png"; cr = gen.currentRender(seed: 1)
    check(cr.control_color == "/x/colour.png" && cr.control_depth == "/x/depth.png", "an imported colour map replaces the boxes' one; the depth map goes along")
    gen.regionControl = false; gen.controlColor = ""; cr = gen.currentRender(seed: 1)
    check(gen.controlling && cr.control_color == nil && cr.control_depth == "/x/depth.png", "a depth map alone controls too")
    gen.tab = "i2i"; gen.initImage = "/x/src.png"; cr = gen.currentRender(seed: 1)
    check(!gen.controlling && cr.control_depth == nil && !gen.modelArgs().contains("--control"), "control is Text-tab only")
    gen.tab = "t2i"; gen.initImage = ""; gen.controlDepth = ""; gen.regionControl = true
    // re-renders: the maps from parameters, the adapter from the sidecar's "control"; prune keeps a map a sidecar uses
    let cmap = gen.currentRender(seed: 1).control_color!, ctlPng = tmp.appendingPathComponent("ctl.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: ctlPng)
    try! #"{"parameters":{"prompt":"p","seed":3,"control_color":"\#(cmap)","control_depth":null,"control_end":0.25},"loras":[],"control":"/a/moss-control.safetensors"}"#
        .write(to: tmp.appendingPathComponent("ctl.json"), atomically: true, encoding: .utf8)
    gen.regionControl = false
    let cjob = Job(url: ctlPng, prompt: "", seed: 3, seconds: 0), back = gen.render(from: cjob)
    check(back?.control_color == cmap && back?.control_depth == nil && back?.control_end == 0.25, "render(from:) keeps the control maps and end")
    check(gen.modelArgs(cjob).suffix(2) == ["--control", "/a/moss-control.safetensors"], "a re-render takes --control from the sidecar with control off in the sidebar")
    check(gen.render(from: Job(url: lpng, prompt: "", seed: 42, seconds: 0))?.control_end == nil && !gen.modelArgs(Job(url: lpng, prompt: "", seed: 42, seconds: 0)).contains("--control"),
          "a sidecar without maps re-renders without control")
    gen.pruneMasks(); check(FileManager.default.fileExists(atPath: cmap), "prune keeps a colour map a sidecar uses")
    gen.trash(cjob); check(!FileManager.default.fileExists(atPath: cmap), "trashing the render trashes its colour map")
    gen.layout = MossLayout(); gen.quality = keepQuality; gen.aspect = "1:1"; gen.applyPreset()
    // 11h. character reference (CharRef): the picture as the only reference in ai-toolkit's format at 384², the card's
    // prefix before the prompt or the layout JSON (the engine adds "Picture 1: <image>" before it), the adapter as --lora,
    // the SFT tier and Quality as picked (Turbo → Draft); Full keeps block 22 skipped in the negative branch (the card's SLG 22)
    let charPic = tmp.appendingPathComponent("character.png").path, keepTransparent = gen.transparent
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: charPic))
    gen.tab = "t2i"; gen.tier = "compact"; gen.layout = MossLayout(); gen.loraDir = "/l"; gen.loras = [dmd]; gen.loraState = [dmd: 1]
    gen.transparent = false; gen.regionControl = true; gen.controlColor = ""; gen.controlDepth = ""; gen.uncondSkip = "22"; gen.slgLayers = ""
    gen.quality = "full"; gen.quality = "draft"; gen.prompt = "sitting in a café, reading a book"
    check(!gen.usingCharacter && gen.currentRender(seed: 1).references == nil && gen.currentRender(seed: 1).edit_format == nil, "no character picture: a plain text render")
    gen.characterRef = charPic
    var ch = gen.currentRender(seed: 1)
    check(ch.prompt == "Same character and art style as Picture 1. sitting in a café, reading a book", "character: the card's prefix, then the prompt: \(ch.prompt)")
    check(ch.references == [charPic] && ch.edit_format == "ai-toolkit" && ch.vision_pixels == 147_456 && ch.init_image == nil && ch.mask == nil && ch.strength == 1,
          "character: the picture as the only reference, ai-toolkit format at 384²")
    let chj = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(ch)) as! [String: Any]
    check(Set(chj.keys).isSubset(of: requestFields) && chj["edit_format"] as? String == "ai-toolkit" && chj["vision_pixels"] as? Int == 147_456 && chj["rgba"] == nil,
          "character JSON keys ⊆ Request fields: \(chj.keys.sorted())")
    check(gen.modelArgs() == ["--model", "compact", "--lora", "/l/" + dmd + ":1.00", "--lora", Generator.charRefAdapter.path] && ch.steps == 8 && ch.guidance == 1,
          "character on Draft: compact, the DMD and CharRef, 8 steps CFG 1: \(gen.modelArgs())")
    check(Generator.charRefAdapter.path.hasSuffix("/adapters/7err4__MOSS-Image-CharRef/moss_image_charref_v2.safetensors")
          && gen.neededAdapters.contains(Generator.charRefAdapter), "CharRef v2 downloads on first use into adapters/")
    check(!gen.controlling && ch.control_color == nil && !gen.modelArgs().contains("--control"), "character: region control is off")
    gen.transparent = true; ch = gen.currentRender(seed: 1)
    check(ch.rgba == nil && !gen.modelArgs().contains(Generator.alphaAdapter.path) && !ch.prompt.contains("transparent background"), "character: transparency is off")
    gen.transparent = false
    gen.quality = "full"; ch = gen.currentRender(seed: 1)
    check(ch.steps == 50 && ch.guidance == 3 && ch.uncond_skip_layers == [22] && ch.slg_layers.isEmpty && gen.modelArgs().contains(Generator.charRefAdapter.path)
          && !gen.modelArgs().contains("/l/" + dmd + ":1.00"), "character on Full: 50 steps, CFG 3, block 22 skipped in the negative branch, no DMD")
    gen.quality = "turbo"; ch = gen.currentRender(seed: 1)
    check(gen.effectiveQuality == "draft" && !gen.modelArgs().contains("--turbo") && ch.steps == 8 && ch.guidance == 1, "character on Turbo renders as Draft")
    gen.quality = "draft"; gen.tier = "8bit"
    check(gen.modelArgs().prefix(2) == ["--model", "8bit"], "character keeps the picked SFT tier")
    gen.tier = "compact"
    // a comic page: the prefix goes before the layout JSON, once
    gen.layout = MossLayout(items: [LayoutItem(label: "character", caption: "the girl waving", x0: 32, y0: 32, x1: 480, y1: 992),
                                    LayoutItem(label: "text", caption: "speech bubble", text: "Hi!", x0: 520, y0: 64, x1: 900, y1: 300)])
    ch = gen.currentRender(seed: 1)
    check(ch.prompt.hasPrefix("Same character and art style as Picture 1. {") && ch.prompt.components(separatedBy: "Picture 1").count == 2
          && ch.prompt.dropFirst(Generator.charRefPrefix.count) == Substring(gen.sentPrompt), "character with a layout: prefix, then the layout JSON, once: \(ch.prompt.prefix(80))")
    gen.layout = MossLayout()
    // the sidecar keeps what was typed; a re-render keeps the format; the Image tab does not use the picture
    gen.running = true; gen.pending = []; gen.runArgs = [:]; gen.appInfo = [:]
    gen.enqueue([gen.currentRender(seed: 5)])
    check(gen.pending.last.map { gen.appInfo[$0.output]?.prompt == "sitting in a café, reading a book" && gen.runArgs[$0.output]?.contains(Generator.charRefAdapter.path) == true } == true,
          "the sidecar's app prompt is as typed, the run args carry CharRef")
    gen.running = false; gen.pending = []; gen.runArgs = [:]; gen.appInfo = [:]
    let chPng = tmp.appendingPathComponent("char-out.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: chPng)
    try! JSONSerialization.data(withJSONObject: ["parameters": ["prompt": "p", "seed": 3, "width": 512, "height": 512, "references": [charPic], "edit_format": "ai-toolkit", "vision_pixels": 147_456]])
        .write(to: tmp.appendingPathComponent("char-out.json"))
    let chBack = gen.render(from: Job(url: chPng, prompt: "", seed: 3, seconds: 0))
    check(chBack?.references == [charPic] && chBack?.edit_format == "ai-toolkit" && chBack?.vision_pixels == 147_456, "render(from:) keeps the ai-toolkit format and vision size")
    try! JSONSerialization.data(withJSONObject: ["parameters": ["prompt": "p", "seed": 3, "width": 512, "height": 512, "references": [charPic], "edit_format": "chinoll", "vision_pixels": 147_456]])
        .write(to: tmp.appendingPathComponent("char-out.json"))
    check(gen.render(from: Job(url: chPng, prompt: "", seed: 3, seconds: 0)).map { $0.edit_format == nil && $0.vision_pixels == nil } == true, "a chinoll edit re-renders without the fields")
    gen.tab = "i2i"; gen.initImage = "/x/src.png"; ch = gen.currentRender(seed: 1)
    check(!gen.usingCharacter && ch.references == nil && ch.edit_format == nil && !ch.prompt.hasPrefix("Same character") && !gen.modelArgs().contains(Generator.charRefAdapter.path),
          "the character picture is Text-tab only")
    gen.tab = "t2i"; gen.initImage = ""
    gen.characterRef = chPng.path; gen.trash(Job(url: chPng, prompt: "", seed: 3, seconds: 0))
    check(gen.characterRef.isEmpty, "trashing the render used as the character picture clears it")
    gen.characterRef = ""; gen.transparent = keepTransparent; gen.regionControl = false; gen.loras = []; gen.loraState = [:]; gen.loraDir = keepDir
    gen.quality = keepQuality; (gen.steps, gen.guidance) = keepSampling
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
    // NSCache may evict at any time (memory pressure), so the same object is only required when nothing was evicted in between
    let evictions = EvictionCount(); ImageCache.cache.delegate = evictions
    func same(_ load: () -> NSImage?) -> Bool { let a = load(), n = evictions.n, b = load(); return a != nil && b != nil && (a === b || evictions.n != n) }
    check(same { ImageCache.thumbnail(cpng.path) } && same { ImageCache.image(cpng.path) }, "image cache returns the same object on repeat")
    let t1 = ImageCache.thumbnail(cpng.path), f1 = ImageCache.image(cpng.path)
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
    check(InfoView.summary(["app": ["prompt": "p", "tier": "8bit"]]).rows.first { $0.0 == "Model" }?.1 == "8-bit" && rowsInfo["Model"] == nil, "info shows the tier when recorded")

    // 11e. time remaining: rate from step 1 on, rest of this image plus the images after it
    check(Generator.eta(elapsed: 0, step: 1, steps: 8, after: 0) == nil, "no estimate at step 1")
    check(Generator.eta(elapsed: 12, step: 4, steps: 8, after: 0) == "~16 s left", "4 s/step, 4 steps left: \(Generator.eta(elapsed: 12, step: 4, steps: 8, after: 0) ?? "nil")")
    check(Generator.eta(elapsed: 12, step: 4, steps: 8, after: 2) == "~16 s left · ~1 min for all", "plus two 32 s images: \(Generator.eta(elapsed: 12, step: 4, steps: 8, after: 2) ?? "nil")")
    check(Generator.eta(elapsed: 5, step: 8, steps: 8, after: -1) == "~0 s left", "last step, no negative image count")
    gen.pending = []; check(gen.remaining == 0, "nothing running or queued: no badge")
    // 11f. queued renders come off one by one or all at once; the running batch stays (running faked: no process)
    gen.tab = "t2i"; gen.layout = MossLayout(); gen.prompt = "a lighthouse\nat dawn"
    gen.running = true; gen.batchTotal = 2; gen.batchDone = 0
    gen.enqueue((1...3).map { gen.currentRender(seed: $0) })
    let q = gen.pending
    check(gen.remaining == 5 && gen.queuedTitle(q[0]) == "a lighthouse", "queue lists the typed prompt's first line: \(gen.queuedTitle(q[0]))")
    gen.removeQueued(q[1].output)
    check(gen.pending.map(\.seed) == [1, 3] && gen.runArgs[q[1].output] == nil && gen.remaining == 4, "remove one by output path: badge drops")
    gen.removeQueued()
    check(gen.pending.isEmpty && gen.runArgs.isEmpty && gen.running && gen.remaining == 2, "remove all queued leaves the running batch")
    var untitled = q[0]; untitled.output = "/nowhere.png"; untitled.prompt = ""; untitled.init_image = "/x/src.png"
    check(gen.queuedTitle(untitled) == "Edit of src.png", "untitled edit named after its source")
    gen.running = false; gen.batchTotal = 0; gen.prompt = ""
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

    // 11h. recent prompts: newest first, re-use moves to the top, blank ignored, capped at 20
    var recent = ["b", "a"]
    recent = Generator.remembering("a", in: recent)
    check(recent == ["a", "b"], "re-used prompt moves to the top, no duplicate: \(recent)")
    recent = Generator.remembering("  c\n", in: recent)
    check(recent == ["c", "a", "b"], "new prompt goes first, trimmed: \(recent)")
    check(Generator.remembering(" \n ", in: recent) == recent, "blank prompt changes nothing")
    recent = (1...25).reduce([]) { Generator.remembering("p\($1)", in: $0) }
    check(recent.count == 20 && recent.first == "p25" && recent.last == "p6", "capped at 20, oldest dropped: \(recent.first ?? "") … \(recent.last ?? "")")

    // 11i. finished-batch notification text; Notifier.batchFinished itself is never called here (no bundle, no NSApp)
    let three = Notifier.content(count: 3, failed: false, prompt: "\n  a lighthouse at dawn \nfog, 35mm")
    check(three?.title == "3 images ready" && three?.body == "a lighthouse at dawn", "batch of 3: count in the title, first non-blank prompt line as body: \(String(describing: three))")
    check(Notifier.content(count: 1, failed: false, prompt: "x")?.title == "Image ready", "one image: singular title")
    check(Notifier.content(count: 2, failed: true, prompt: "")?.title == "Render failed" && Notifier.content(count: 0, failed: true, prompt: "")?.body == "", "failure wins over a partial count; empty prompt, empty body")
    check(Notifier.content(count: 0, failed: false, prompt: "x") == nil, "cancelled before any image: no notification")
    // 11i. download progress: tqdm bars on stderr → bytes done/total and rate, summed over files
    var bars: [String: Transfer] = [:]
    // classic tqdm (huggingface_hub before xet): one bar per file, two files at once, G units, \r-separated updates
    let classic = "\rmodel-00001-of-00002.safetensors:   0%|          | 0.00/5.37G [00:00<?, ?B/s]"
        + "\rmodel-00002-of-00002.safetensors:  10%|█         | 1.07G/10.7G [00:10<01:30, 107MB/s]"
        + "\rmodel-00001-of-00002.safetensors:  45%|████▌     | 2.42G/5.37G [00:30<00:40, 77.0MB/s]"
        + "\rconfig.json: 100%|██████████| 548/548 [00:00<00:00, 1.20kB/s]\n"
    check(Transfer.feed(classic, into: &bars) && bars.count == 3, "three byte bars, the later update of a file replacing its earlier one: \(bars.keys.sorted())")
    var sum = Transfer.sum(bars)
    check(abs(sum.done - (2.42e9 + 1.07e9 + 548)) < 1 && abs(sum.total - (5.37e9 + 10.7e9 + 548)) < 1 && abs(sum.rate - 184e6) < 1,
          "summed done/total; rate only of unfinished files: \(sum)")
    check(sum.summary == "3.5 GB of 16.1 GB · 184 MB/s · ~1 min left", "summary: \(sum.summary)")
    // huggingface_hub 2.x with hf_xet, as captured from snapshot_download with TQDM_POSITION=-1 (\u{1B}[A moves up a line)
    bars = [:]
    let xet = "\rDownloading bytes:           |  0.00B            \u{1B}[A\n\rFetching 10 files:   0%|          | 0/10 [00:00<?, ?it/s]\u{1B}[A"
        + "Warning: You are sending unauthenticated requests to the HF Hub.\n\n"
        + "\rReconstructing (incomplete total...):   0%|          |   548B /  521kB            \u{1B}[A"
        + "\rReconstructing (incomplete total...):   5%|▌         | 1.53MB / 28.2MB,  910kB/s  \u{1B}[A"
        + "\rDownloading bytes: ████▎     | 12.1MB, 11.4MB/s  \u{1B}[A\rFetching 10 files:  90%|█████████ | 9/10 [00:01<00:00,  5.76it/s]\u{1B}[A"
    check(Transfer.feed(xet, into: &bars) && bars.count == 1, "xet: only the reconstruct bar counts (no file counts, no total-less bytes): \(bars)")
    sum = Transfer.sum(bars)
    check(sum == Transfer(done: 1.53e6, total: 28.2e6, rate: 910e3), "xet bar: MB and kB scaled decimal: \(sum)")
    _ = Transfer.feed("\rReconstruction complete: 100%|██████████| 28.2MB / 28.2MB, 1.71MB/s  \u{1B}[A", into: &bars)
    check(bars.count == 1 && Transfer.sum(bars).done == 28.2e6, "the renamed final bar replaces, not adds: \(bars)")
    check(!Transfer.feed("\rstep 3/8     6.1 s\rFetching 30 files: 100%|██████████| 30/30 [00:00<00:00, 5000.00it/s]\nfetching VisualInference/x (cached after the first run)\n", into: &bars),
          "step lines, file counts and plain lines are not downloads")
    bars = [:]
    _ = Transfer.feed("\rdiffusion_pytorch_model.safetensors: reconstructing file:  40%|████      | 99.8MB / 250MB, 31.0MB/s  ", into: &bars)
    check(bars.keys.first == "diffusion_pytorch_model.safetensors: reconstructing file" && Transfer.sum(bars).total == 250e6, "the VAE encoder's single-file bar: \(bars)")
    check(Transfer().summary == "Starting…" && Transfer(done: 5e8, total: 2.5e8 * 4).summary == "500 MB of 1.0 GB", "summary before the total is known, and without a rate")
    // cache check: refs/main → trees/<commit>.json lists the files; complete once every one is in the snapshot
    let hub = tmp.appendingPathComponent("hub").path, repoDir = hub + "/models--org--m"
    check(!Generator.isCached("org/m", in: hub), "nothing downloaded: not cached")
    try! FileManager.default.createDirectory(atPath: repoDir + "/refs", withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(atPath: repoDir + "/trees", withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(atPath: repoDir + "/snapshots/abc/vae", withIntermediateDirectories: true)
    try! "abc".write(toFile: repoDir + "/refs/main", atomically: true, encoding: .utf8)
    try! #"{"format_version":1,"files":{"model_index.json":{"size":2},"vae/decoder.safetensors":{"size":9}}}"#.write(toFile: repoDir + "/trees/abc.json", atomically: true, encoding: .utf8)
    try! "{}".write(toFile: repoDir + "/snapshots/abc/model_index.json", atomically: true, encoding: .utf8)
    check(!Generator.isCached("org/m", in: hub), "a file of the listing missing (cancelled download): not cached")
    try! "w".write(toFile: repoDir + "/snapshots/abc/vae/decoder.safetensors", atomically: true, encoding: .utf8)
    check(Generator.isCached("org/m", in: hub), "every listed file in the snapshot: cached")
    // Download Model through a fake venv python: progress shows, queued renders wait for it, Cancel stops it
    let fakeBin = tmp.appendingPathComponent("fakebin"); try! FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try! """
    #!/bin/zsh
    print -r -- "$TQDM_POSITION $*" > $0.args
    printf '\\rReconstructing (incomplete total...):  50%%|█████     | 6.00GB / 12.0GB, 100MB/s  \\033[A' >&2
    sleep ${SLEEP:-1}
    """.write(to: fakeBin.appendingPathComponent("python"), atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBin.appendingPathComponent("python").path)
    FileManager.default.createFile(atPath: fakeBin.path + "/moss-mlx", contents: nil, attributes: [.posixPermissions: 0o755])
    gen.cli = fakeBin.appendingPathComponent("moss-mlx").path; gen.tier = "compact"; gen.running = false; gen.pending = []
    gen.downloadModel()
    check(gen.fetching && gen.transfer != nil, "Download Model starts the venv's python: \(gen.status)")
    var seen: Transfer?
    var until = Date().addingTimeInterval(5)
    while gen.fetching, Date() < until { if gen.transfer?.total ?? 0 > 0 { seen = gen.transfer }; await Task.sleep(seconds: 0.05) }
    let fetchArgs = (try? String(contentsOfFile: fakeBin.path + "/python.args", encoding: .utf8)) ?? ""
    check(fetchArgs.hasPrefix("-1 -c ") && fetchArgs.contains("snapshot_download") && fetchArgs.contains("VisualInference/MOSS-Image-SFT-MLX-compact"),
          "snapshot_download of the tier's repo, bars forced on: \(fetchArgs)")
    check(seen == Transfer(done: 6e9, total: 12e9, rate: 100e6) && gen.transfer == nil && gen.status == "Model downloaded", "progress shown, cleared at the end: \(String(describing: seen)) \(gen.status)")
    setenv("SLEEP", "10", 1)   // the fake python's environment comes from ours
    gen.downloadModel(); gen.enqueue([gen.currentRender(seed: 1)])
    check(gen.fetching && !gen.running && gen.pending.count == 1 && gen.status == "Queued until the download finishes", "a render queued during Download Model waits: \(gen.status)")
    gen.cancelDownload()
    until = Date().addingTimeInterval(5)
    while gen.fetching, Date() < until { await Task.sleep(seconds: 0.05) }
    check(!gen.fetching && !gen.running && gen.pending.isEmpty && gen.transfer == nil && gen.status == "Download cancelled", "Cancel stops it and drops what waited: \(gen.status)")
    unsetenv("SLEEP"); gen.cli = savedCLI
    // 11h2. engine home: a setup.sh install keeps today's paths, none means Application Support, a custom CLI wins
    let home = tmp.path + "/home", setupCLI = EngineHome.setupCLI(home: home)
    var eh = EngineHome(cli: setupCLI, home: home)
    check(eh.cli == home + "/Library/Application Support/MOSS Image/engine/bin/moss-mlx" && eh.python == home + "/Library/Application Support/MOSS Image/engine/bin/python"
          && eh.loras == home + "/Library/Application Support/MOSS Image/loras" && eh.adapters == home + "/Library/Application Support/MOSS Image/adapters",
          "no install: the engine, LoRAs and adapters in Application Support: \(eh)")
    try! FileManager.default.createDirectory(atPath: home + "/moss-mlx/bin", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: setupCLI, contents: nil, attributes: [.posixPermissions: 0o755])
    eh = EngineHome(cli: setupCLI, home: home)
    check(eh.cli == home + "/moss-mlx/bin/moss-mlx" && eh.python == home + "/moss-mlx/bin/python" && eh.loras == home + "/moss-mlx/loras"
          && eh.adapters == home + "/moss-mlx/adapters", "a ~/moss-mlx install: the paths as before: \(eh)")
    eh = EngineHome(cli: fakeBin.path + "/moss-mlx", home: home)
    check(eh.cli == fakeBin.path + "/moss-mlx" && eh.python == fakeBin.path + "/python" && eh.adapters == tmp.path + "/adapters", "a custom CLI setting wins over ~/moss-mlx: \(eh)")
    check(EngineHome(cli: fakeBin.path + "/python.args", home: home).root == EngineHome.appSupport(home: home), "a setting that is not executable: Application Support")
    let realHome = EngineHome(cli: EngineHome.setupCLI())
    if FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/moss-mlx/bin/moss-mlx") {
        check(realHome.cli == NSHomeDirectory() + "/moss-mlx/bin/moss-mlx" && realHome.loras == NSHomeDirectory() + "/moss-mlx/loras"
              && Generator.editAdapter.dir == NSHomeDirectory() + "/moss-mlx/adapters/" + Generator.editAdapter.repo.replacingOccurrences(of: "/", with: "__"),
              "this Mac's ~/moss-mlx: CLI, LoRA folder and adapter dirs unchanged")
    } else { print("skip  no ~/moss-mlx install on this Mac") }
    // 11h3. first-run setup: the checks before installing, how failures read, the library afterwards
    let mac14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0), gib: UInt64 = 1 << 30
    var pf = EngineSetup.preflight(root: home, appleSilicon: true, macOS: mac14, memory: 24 * gib, free: 50_000_000_000)
    check(pf.allSatisfy(\.ok) && pf[2].detail.contains("both models"), "24 GB, 50 GB free: every check passes, both tiers fit: \(pf.map(\.detail))")
    pf = EngineSetup.preflight(root: home, appleSilicon: true, macOS: mac14, memory: 16 * gib, free: 50_000_000_000)
    check(pf[2].ok && pf[2].detail.contains("Compact model fits"), "16 GB: Compact fits")
    pf = EngineSetup.preflight(root: home, appleSilicon: false, macOS: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0), memory: 8 * gib, free: 15_000_000_000)
    check(pf.map(\.ok) == [false, false, false, false] && pf.map(\.blocks) == [true, true, false, true], "Intel, macOS 13, 8 GB, 15 GB free: memory warns, the rest blocks")
    check(EngineSetup.freeSpace(home + "/Library/Application Support/MOSS Image/engine") > 0, "free space read from the nearest existing folder")
    check(!EngineSetup.needed, "no engine payload in this build: no setup sheet")
    check(EngineSetup.offline("error: Failed to install cpython\n  cause: dns error: failed to lookup address information") && EngineSetup.offline("requests.exceptions.ConnectionError: Max retries exceeded")
          && !EngineSetup.offline("error: Failed to download `idna==3.20`\n  cause: Hash mismatch for `idna==3.20`"), "offline told apart from other failures")
    let es = EngineSetup(root: home, payload: tmp.path)
    es.log = "Resolved 35 packages\nerror: Failed to download `idna==3.20`\n  cause: Hash mismatch for `idna==3.20`\n\n         Expected:\n           sha256:dead\n"
    check(es.errorText == "error: Failed to download `idna==3.20`\ncause: Hash mismatch for `idna==3.20`", "uv's error and its cause shown, not the hash lines: \(es.errorText)")
    es.log = "Traceback (most recent call last):\n  File x\nOSError: [Errno 28] No space left on device\n"
    check(es.errorText == "OSError: [Errno 28] No space left on device", "a Python failure shows its last line")
    let site = tmp.path + "/venv/lib/python3.12/site-packages/moss_image_mlx-0.2.0.dist-info"
    try! FileManager.default.createDirectory(atPath: site, withIntermediateDirectories: true)
    check(EngineHome(cli: tmp.path + "/venv/bin/moss-mlx", home: tmp.path + "/nohome").version == nil
          && EngineHome(cli: fakeBin.path + "/moss-mlx").version == nil, "no metadata: no version")
    try! FileManager.default.createDirectory(atPath: tmp.path + "/venv/bin", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: tmp.path + "/venv/bin/moss-mlx", contents: nil, attributes: [.posixPermissions: 0o755])
    check(EngineHome(cli: tmp.path + "/venv/bin/moss-mlx").version == "0.2.0", "the engine's version from its package metadata")
    let (keepLoras, keepState, setupKeepDir) = (gen.loras, gen.loraState, gen.loraDir)
    gen.loraDir = tmp.path + "/setup-loras"; gen.loraState = [:]
    try! FileManager.default.createDirectory(atPath: gen.loraDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: gen.loraDir + "/" + EngineSetup.dmd, contents: nil)
    gen.engineInstalled()
    check(gen.loras == [EngineSetup.dmd] && gen.loraState == [EngineSetup.dmd: 1], "after setup the DMD adapter is listed and on, as in setup.sh's library")
    gen.loraDir = setupKeepDir; gen.loras = keepLoras; gen.loraState = keepState
    // 11i. outpainting: geometry on the 16 px grid within the budget, mask strips with overlap, boxes move with the
    // picture, padded init and mask at output size, prompt fallback, the result becomes the unextended working image
    let fit = Generator.outpaint(source: CGSize(width: 1500, height: 1000), pad: Pad(), pixels: 1024 * 1024)
    check(fit.width == 1248 && fit.height == 832 && fit.image == CGRect(x: 0, y: 0, width: 1248, height: 832), "zero pad is the plain fitted size: \(fit)")
    let g = Generator.outpaint(source: CGSize(width: 1500, height: 1000), pad: Pad(left: 0.5), pixels: 1024 * 1024)
    check(g.width == 1536 && g.height == 688 && g.image == CGRect(x: 512, y: 0, width: 1024, height: 688), "left +50 %: picture at x 512, canvas 1536 × 688: \(g)")
    let all = Generator.outpaint(source: CGSize(width: 1024, height: 768), pad: Pad(left: 0.13, right: 0.31, top: 0.07, bottom: 0.4), pixels: 2 * 1024 * 1024)
    check([all.width, all.height, Int(all.image.minX), Int(all.image.minY), Int(all.image.width), Int(all.image.height)].allSatisfy { $0 % 16 == 0 }
          && Double(all.width * all.height) < 2.05 * 1024 * 1024 && Double(all.width * all.height) > 1.95 * 1024 * 1024
          && abs(all.image.width / all.image.height - 4.0 / 3) < 0.03, "odd pads: every edge on the 16 px grid, about 2 MP, picture keeps its aspect: \(all)")
    let b768 = Generator.outpaintBlend(CGRect(x: 0, y: 0, width: 768, height: 768)), b960 = Generator.outpaintBlend(CGRect(x: 0, y: 0, width: 960, height: 1400))
    let bSmall = Generator.outpaintBlend(CGRect(x: 0, y: 0, width: 300, height: 200))
    check(b768 == (12, 17) && b960 == (15, 22) && bSmall == (8, 12), "blend band 6 % of the shorter side, min 32 px: overlap band/4, feather 3/8 band: \(b768) \(b960) \(bSmall)")
    check(Generator.outpaintMask(canvas: CGSize(width: 1536, height: 688), image: g.image) == [CGRect(x: 0, y: 0, width: 522, height: 688)],
          "one extended side: one strip, 10 px (band 41 / 4) into the picture, none on the sides that touch the canvas edge")
    let strips = Generator.outpaintMask(canvas: CGSize(width: 400, height: 300), image: CGRect(x: 100, y: 50, width: 200, height: 200))
    func covered(_ x: CGFloat, _ y: CGFloat) -> Bool { strips.contains { $0.contains(CGPoint(x: x, y: y)) } }
    check(strips.count == 4 && covered(5, 5) && covered(395, 295) && covered(104, 150) && covered(150, 246) && !covered(110, 60) && !covered(290, 240),
          "all round: four strips cover the new area and 8 px (min band 32 / 4) of the picture, its inside is kept")
    let edge = Generator.outpaintMask(canvas: CGSize(width: 1200, height: 800), image: CGRect(x: 0, y: 0, width: 800, height: 800))
    check(edge == [CGRect(x: 788, y: 0, width: 412, height: 800)], "right only: the overlap reaches in on the right, nowhere else: \(edge)")
    let p169 = Generator.pad(to: 16.0 / 9, from: 1), p11 = Generator.pad(to: 1, from: 2)
    check(abs(p169.left - 7.0 / 18) < 1e-9 && p169.left == p169.right && p169.top == 0 && p11.top == 0.5 && p11.bottom == 0.5 && p11.left == 0,
          "presets: 1:1 → 16:9 adds 38.9 % left and right, 2:1 → 1:1 adds 50 % of the height top and bottom")
    let carried = Generator.mapped(MossLayout(items: [LayoutItem(x0: 100, y0: 100, x1: 200, y1: 300)]), from: CGRect(x: 0, y: 0, width: 1000, height: 1000), to: CGRect(x: 500, y: 20, width: 500, height: 500))
    check(carried.items[0].rect == CGRect(x: 550, y: 70, width: 50, height: 100), "boxes move and scale with the picture: \(carried.items[0].rect)")

    let duo = tmp.appendingPathComponent("duo.png")   // red stripe on the left 10 %, then blue to the middle, right half green
    let drep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1500, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: drep)
    NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 750, height: 1000).fill(); NSColor.green.setFill(); NSRect(x: 750, y: 0, width: 750, height: 1000).fill()
    NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 150, height: 1000).fill()
    NSGraphicsContext.restoreGraphicsState()
    try! drep.representation(using: .png, properties: [:])!.write(to: duo)
    gen.tab = "i2i"; gen.megapixels = 1; gen.prompt = ""; gen.layout = MossLayout(); gen.setSource(duo.path)
    gen.layout = MossLayout(items: [LayoutItem(label: "fill", x0: 624, y0: 104, x1: 1248, y1: 520)])
    gen.pad = Pad(left: 0.5)
    let box = gen.layout.items[0].rect
    check(gen.outpainting && gen.width == 1536 && gen.height == 688 && gen.imageRect == g.image, "setting a pad extends the canvas: \(gen.width)×\(gen.height) \(gen.imageRect ?? .zero)")
    check(abs(box.minX - 1024) < 0.5 && abs(box.maxX - 1536) < 0.5 && abs(box.minY - 86) < 0.5 && abs(box.maxY - 430) < 0.5, "a box keeps its place on the picture: \(box)")
    check(gen.sentPrompt.contains("The same picture.") && gen.sentPrompt.contains("extended beyond"), "extension with a box: the edit summary says so: \(gen.sentPrompt)")
    let ro = gen.currentRender(seed: 1)
    check(ro.strength == 1 && ro.width == 1536 && ro.height == 688 && ro.init_image?.hasPrefix(tmp.appendingPathComponent("masks").path) == true,
          "the render starts the new area from noise (strength 1), at the canvas size, from a padded init next to the masks: \(ro.init_image ?? "nil")")
    if let ip = ro.init_image, let ib = NSImage(contentsOfFile: ip)?.representations.first as? NSBitmapImageRep,
       let mp = ro.mask, let mb = NSImage(contentsOfFile: mp)?.representations.first as? NSBitmapImageRep {
        check(ib.pixelsWide == 1536 && ib.pixelsHigh == 688 && mb.pixelsWide == 1536 && mb.pixelsHigh == 688, "padded init and mask are output-sized")
        func c(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) { let v = ib.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!; return (v.redComponent, v.greenComponent, v.blueComponent) }
        check(c(700, 300).b > 0.8 && c(700, 300).g < 0.2 && c(1400, 300).g > 0.8 && c(1400, 300).b < 0.2, "the picture sits at its offset, unflipped: \(c(700, 300)) \(c(1400, 300))")
        // the red stripe at the picture's left edge (102 px) is stretched across the whole new area, not mirrored
        check(c(530, 300).r > 0.8 && c(470, 300).r > 0.8 && c(300, 300).r > 0.8 && c(300, 300).b < 0.2 && c(10, 5).r > 0.8,
              "the new area is the picture's edge stretched outwards: \(c(470, 300)) \(c(300, 300)) \(c(10, 5))")
        func white(_ x: Int, _ y: Int) -> Bool { (mb.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.5 }
        check(white(10, 300) && white(520, 300) && !white(524, 600) && !white(1000, 300) && white(1200, 300), "mask: the new area, 10 px of overlap and the box are white; the rest of the picture black")
    } else { check(false, "padded init and mask readable") }
    check(ro.mask_feather == 15, "the extension's feather spans the blend band (3/8 of 41 px, above the default 12): \(ro.mask_feather)")
    gen.maskFeather = 40; check(gen.currentRender(seed: 1).mask_feather == 40, "a wider feather set by hand wins"); gen.maskFeather = 12
    gen.layout = MossLayout()
    check(gen.sentPrompt == "The same picture." + Generator.extended, "empty prompt: the model is told to continue the scene: \(gen.sentPrompt)")
    gen.prompt = "a wide beach at dusk"
    check(gen.sentPrompt == "a wide beach at dusk", "a typed prompt describes the extended scene and goes as is")
    gen.prompt = ""
    // the result arrives (fake CLI: copies the padded init to the output): working image, unextended, same canvas
    let echo = tmp.appendingPathComponent("echo-cli")
    try! """
    #!/bin/zsh
    [[ $1 == --help ]] && exit 0
    out=$(sed -E 's/.*"output":"([^"]*)".*/\\1/; s#\\\\/#/#g' $2); init=$(sed -E 's/.*"init_image":"([^"]*)".*/\\1/; s#\\\\/#/#g' $2)
    cp $init $out; print -r -- "{\\"parameters\\":$(cat $2)}" > ${out%.png}.json; print $out
    """.write(to: echo, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: echo.path)
    gen.cli = echo.path; Generator.previewSupport[echo.path] = false; gen.loras = []; gen.loraState = [:]
    gen.layout = MossLayout(items: [LayoutItem(label: "fill", x0: 0, y0: 0, x1: 512, y1: 688)]); gen.pending = []; gen.generate()
    let untilDone = Date().addingTimeInterval(10)
    while gen.running || !gen.pending.isEmpty, Date() < untilDone { await Task.sleep(seconds: 0.05) }
    let res = gen.selected?.url.path ?? ""
    check(gen.initImage == res && gen.originalSource == duo.path && gen.pad == Pad() && gen.imageRect == nil && !gen.outpainting,
          "the extension becomes the working image, the Original pin stays, the pad resets: \(gen.status)")
    check(gen.width == 1536 && gen.height == 688 && abs(gen.layout.items[0].rect.width - 512) < 1, "same canvas afterwards, boxes stay put: \(gen.width)×\(gen.height) \(gen.layout.items[0].rect)")
    if let job = gen.selected, let v = gen.render(from: job), let vi = v.init_image {
        check(vi.contains("/masks/outpaint-") && v.mask != nil && v.width == 1536 && v.strength == Generator.extendStrength,"a variation re-renders from the sidecar's padded init and mask: \(vi)")
        gen.pruneMasks([vi])
        check(FileManager.default.fileExists(atPath: vi), "a padded init a sidecar refers to survives the mask prune")
    } else { check(false, "the extension's sidecar gives a render") }
    gen.cli = savedCLI; gen.layout = MossLayout(); gen.setSource(src.path)

    // 11j. cutout into a box: the picture's visible part fits the box (aspect kept, centred), the blend band runs along
    // its outline at output size, the composite becomes the working image and the blend is a retouch of the band only;
    // Generate as cutout renders the caption transparent at the box's aspect and places what arrives
    check(Generator.placedRect(CGSize(width: 200, height: 100), in: CGRect(x: 100, y: 100, width: 100, height: 100)) == CGRect(x: 100, y: 125, width: 100, height: 50),
          "a wide picture takes the box's width, centred vertically")
    check(Generator.placedRect(CGSize(width: 50, height: 200), in: CGRect(x: 0, y: 0, width: 300, height: 400)) == CGRect(x: 100, y: 0, width: 100, height: 400),
          "a tall picture takes the box's height (enlarged), centred horizontally")
    let cs = Generator.cutoutSize(CGSize(width: 180, height: 210), pixels: 1024 * 1024), cw = Generator.cutoutSize(CGSize(width: 1000, height: 50), pixels: 1024 * 1024)
    check(cs.width % 16 == 0 && cs.height % 16 == 0 && abs(Double(cs.width) / Double(cs.height) - 180.0 / 210) < 0.02 && abs(Double(cs.width * cs.height) / (1024 * 1024) - 1) < 0.03,
          "cutout size: the box's aspect at about 1 MP on the 16 px grid: \(cs)")
    check(cw == (2048, 512), "a 20:1 box renders at 4:1, no side under the CLI's floor: \(cw)")
    var am = [UInt8](repeating: 0, count: 40 * 30); for y in 5..<12 { for x in 20..<33 { am[y * 40 + x] = 200 } }; am[0] = 20
    check(Generator.opaqueBounds(am, width: 40, height: 30) == CGRect(x: 20, y: 5, width: 13, height: 7), "visible bounds: the opaque block, not the faint pixel")
    check(Generator.opaqueBounds([UInt8](repeating: 10, count: 100), width: 10, height: 10) == nil, "nothing visible: no bounds")
    var sq = [UInt8](repeating: 0, count: 40 * 40); for y in 10..<30 { for x in 10..<40 { sq[y * 40 + x] = 255 } }   // touches the right edge
    let band = Generator.edgeBand(sq, width: 40, height: 40, outer: 3, inner: 2)
    func on(_ x: Int, _ y: Int) -> Bool { band[y * 40 + x] == 255 }
    check(on(7, 20) && !on(6, 20) && on(11, 20) && !on(12, 20) && on(20, 7) && !on(20, 6) && on(20, 31) && on(7, 7) && !on(25, 20) && !on(39, 20),
          "band: up to 3 px outside the outline and 2 px inside, the inside and the far outside clear, none along the canvas edge")
    check(Generator.blendBand(CGRect(x: 0, y: 0, width: 180, height: 210)) == (18, 6, 6) && Generator.blendBand(CGRect(x: 0, y: 0, width: 600, height: 400)) == (30, 10, 10),
          "blend band: 10 % of the shorter side, min 24 px; 3/4 out, 1/4 in, feather 1/4")

    let street = tmp.appendingPathComponent("street.png"), post = tmp.appendingPathComponent("post.png")
    func drawPNG(_ url: URL, _ w: Int, _ h: Int, _ paint: (CGContext) -> Void) { let c = Generator.bitmap(w, h)!; paint(c); _ = Generator.writePNG(c.makeImage()!, to: url) }
    drawPNG(street, 512, 512) { $0.setFillColor(NSColor.blue.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 512, height: 512)) }
    drawPNG(post, 100, 100) { $0.setFillColor(NSColor.red.cgColor); $0.fill(CGRect(x: 40, y: 50, width: 20, height: 40)) }   // 20×40 visible, transparent around
    gen.tab = "i2i"; gen.megapixels = 0.25; gen.setSource(street.path)
    let holder = LayoutItem(label: "object", caption: "a red post", x0: 100, y0: 100, x1: 300, y1: 400)
    gen.layout = MossLayout(items: [holder]); gen.running = true; gen.pending = []   // running faked: the blend stays queued
    let jobsBefore = gen.jobs.count
    gen.place(post.path, in: holder.id)
    check(gen.width == 512 && gen.jobs.count == jobsBefore + 1 && gen.initImage == gen.jobs.first?.url.path && gen.initImage.hasPrefix(tmp.path)
          && gen.originalSource == street.path && gen.tab == "i2i", "the composite is a new history image and the working image; the Original pin stays; Image tab")
    if let cb = NSImage(contentsOfFile: gen.initImage)?.representations.first as? NSBitmapImageRep {
        func red(_ x: Int, _ y: Int) -> Bool { let v = cb.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!; return v.redComponent > 0.9 && v.blueComponent < 0.1 }
        // 20×40 into 200×300: ×7.5 → 150×300 at x 125…275, the box's full height
        check(cb.pixelsWide == 512 && red(130, 105) && red(270, 395) && !red(120, 250) && !red(280, 250) && !red(200, 50), "the visible part fills the box's height, centred, over the picture")
    } else { check(false, "composite readable") }
    if let blend = gen.pending.first, gen.pending.count == 1, let mp = blend.mask, let mb = NSImage(contentsOfFile: mp)?.representations.first as? NSBitmapImageRep {
        func white(_ x: Int, _ y: Int) -> Bool { (mb.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0) > 0.5 }   // a grey PNG
        check(blend.init_image == gen.initImage && blend.strength == Generator.blendStrength && blend.mask_feather == 6 && mp.contains("/masks/blend-")
              && blend.references == nil && blend.rgba == nil, "the blend: a retouch of the composite at the blend strength, band mask next to the masks, feather 6")
        check(mb.pixelsWide == 512 && white(110, 250) && !white(105, 250) && white(129, 250) && !white(132, 250) && !white(200, 250) && white(200, 90) && !white(20, 20),
              "band mask at output size: 18 px outside the post's outline, 6 px inside, the rest black")
        check(blend.prompt.contains("a red post") && blend.prompt.contains(#""caption":"The same picture. The marked object"#), "the blend prompt is the box as a layout item under the blend summary")
        check(gen.runArgs[blend.output]?.contains(Generator.editAdapter.path) == false, "no edit adapter in the blend")
    } else { check(false, "one blend render queued with a readable mask: \(gen.pending.count)") }
    gen.pending = []; gen.running = false
    var bare2 = holder; bare2.caption = " "; gen.layout = MossLayout(items: [bare2]); gen.generateCutout(in: holder.id)
    check(gen.pending.isEmpty && gen.status.contains("caption"), "Generate as cutout without a caption: refused, says why")
    if FileManager.default.fileExists(atPath: Generator.alphaAdapter.path) {   // else it would download 130 MB
        // fake CLI: logs its args; a render with an init copies it, one without returns the transparent post
        let fakeCut = tmp.appendingPathComponent("cutout-cli"), argsLog = tmp.appendingPathComponent("args.log")
        try! """
        #!/bin/zsh
        [[ $1 == --help ]] && exit 0
        print -r -- "$*" >> \(argsLog.path)
        line=$(cat $2); out=$(sed -E 's/.*"output":"([^"]*)".*/\\1/; s#\\\\/#/#g' <<< $line)
        if [[ $line == *init_image* ]]; then cp $(sed -E 's/.*"init_image":"([^"]*)".*/\\1/; s#\\\\/#/#g' <<< $line) $out; else cp \(post.path) $out; fi
        print -r -- "{\\"parameters\\":$line}" > ${out%.png}.json; print $out
        """.write(to: fakeCut, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCut.path)
        gen.cli = fakeCut.path; Generator.previewSupport[fakeCut.path] = false; gen.loras = []; gen.loraState = [:]
        gen.layout = MossLayout(items: [holder])
        let n0 = gen.jobs.count
        gen.generateCutout(in: holder.id)
        let until = Date().addingTimeInterval(10)
        while gen.running || !gen.pending.isEmpty, Date() < until { await Task.sleep(seconds: 0.05) }
        let calls = ((try? String(contentsOf: argsLog, encoding: .utf8)) ?? "").split(separator: "\n")
        check(calls.count == 2 && calls[0].contains(Generator.alphaAdapter.path) && !calls[1].contains(Generator.alphaAdapter.path) && !calls.joined().contains(Generator.editAdapter.path),
              "two batches: the cutout with the alpha adapter, then the blend without; no edit adapter: \(calls.count)")
        check(gen.jobs.count == n0 + 3 && gen.initImage == gen.jobs.first?.url.path, "cutout, composite and blend in the history; the blend is the working image: \(gen.jobs.count - n0)")
        if gen.jobs.count >= n0 + 3, let cut = gen.sidecar(gen.jobs[2].url) {
            let want = Generator.cutoutSize(holder.rect.size, pixels: 1024 * 1024)
            check(cut["rgba"] as? Bool == true && cut["width"] as? Int == want.width && cut["height"] as? Int == want.height && cut["init_image"] == nil
                  && (cut["prompt"] as? String) == "a red post" + Generator.alphaTrigger && gen.restore(gen.jobs[2].url)?.prompt == "a red post",
                  "the cutout: transparent, the box's aspect at 1 MP, the caption plus the alpha trigger: \(cut["width"] ?? 0)×\(cut["height"] ?? 0)")
            check(gen.sidecar(gen.jobs[0].url)?["init_image"] as? String == gen.jobs[1].url.path, "the blend started from the composite of the cutout")
        } else { check(false, "the cutout's sidecar") }
    } else { print("skip  no alpha adapter at \(Generator.alphaAdapter.path)") }
    gen.cli = savedCLI; gen.layout = MossLayout(); gen.megapixels = 1; gen.setSource(src.path)

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
        for k in knownLoras { check((try await HubSearch.files(k.repo)).contains(k.file), "known adapter on the Hub: \(k.repo)/\(k.file)") }
    } catch { print("skip  network: \(error.localizedDescription)") }

    // 14. ComfyUI graph builders (remote backend)
    func remoteGraph(_ shape: (inout Render) -> Void, loras: [ComfyGraph.LoRA] = [], slg: String = "") -> [String: Any] {
        var r = Render(prompt: "POS", negative_prompt: "NEG", width: 1024, height: 1024, steps: 25, guidance: 2.5, seed: 42,
                       uncond_skip_layers: [22], slg_layers: Generator.layers(slg), slg_scale: 0, slg_start: 0, slg_stop: 0.5,
                       init_image: nil, strength: 1, mask: nil, mask_feather: 12,
                       output: tmp.appendingPathComponent("g.png").path)
        shape(&r)
        return ComfyGraph.build(r, loras: loras, checkpoint: "unet.safetensors", textEncoder: "te.safetensors", vae: "v.safetensors")
    }
    func node(_ g: [String: Any], _ id: String) -> (String, [String: Any])? {
        guard let n = g[id] as? [String: Any], let ct = n["class_type"] as? String else { return nil }
        return (ct, n["inputs"] as? [String: Any] ?? [:])
    }
    func ref(_ v: Any?, _ target: String, _ slot: Int) -> Bool {
        let a = (v as? [Any]) ?? []
        return a.count == 2 && (a.first as? String) == target && (a.last as? Int) == slot
    }
    var t2i = remoteGraph({ _ in }, loras: [ComfyGraph.LoRA(name: "dmd.safetensors", scale: 0.9)])
    check(ComfyGraph.validate(t2i).isEmpty, "t2i graph has no dangling links: \(ComfyGraph.validate(t2i))")
    check(node(t2i, "1")?.1["unet_name"] as? String == "unet.safetensors", "checkpoint wired into UNETLoader")
    check(node(t2i, "2")?.1["type"] as? String == "moss_image" && node(t2i, "2")?.1["clip_name"] as? String == "te.safetensors", "CLIPLoader type moss_image + text encoder")
    let ks = node(t2i, "7")?.1 ?? [:]
    check((ks["seed"] as? Int) == 42 && (ks["steps"] as? Int) == 25 && (ks["cfg"] as? Double) == 2.5, "KSampler carries seed/steps/cfg: \(ks)")
    check(ks["sampler_name"] as? String == "er_sde" && ks["scheduler"] as? String == "simple", "sampler er_sde/simple as the official template")
    check(ref(ks["latent_image"], "8", 0), "t2i latent comes from EmptyFlux2LatentImage")
    check(ref(ks["model"], "100", 0), "KSampler samples the LoRA-adjusted model")
    check(node(t2i, "100")?.0 == "LoraLoaderModelOnly" && (node(t2i, "100")?.1["strength_model"] as? Double) == 0.9, "LoRA scale parsed from the spec (chain ids live in the reserved range)")
    check(ref(node(t2i, "100")?.1["model"], "1", 0), "LoRA hangs off the UNet")
    check(node(t2i, "8")?.1["width"] as? Int == 1024, "canvas size carried to EmptyFlux2LatentImage")
    check(node(t2i, "20") == nil, "no SLG node while skip-layer guidance is off")
    check((node(t2i, "5")?.1["text"] as? String) == "POS" && (node(t2i, "6")?.1["text"] as? String) == "NEG", "prompts pass through verbatim (layout JSON is already in the app-side compile)")
    let slgG = remoteGraph({ _ in }, slg: "22,1")
    let slgNode = node(slgG, "20")
    check(slgNode?.0 == "SkipLayerGuidanceDiTSimple" && (slgNode?.1["single_layers"] as? String) == "22,1" && (slgNode?.1["end_percent"] as? Double) == 0.5,
          "SLG node carries layers and window: \(slgNode?.1 ?? [:])")
    check(ref(node(slgG, "7")?.1["model"], "20", 0), "KSampler samples the SLG-modified model")
    var i2iPlain = remoteGraph({ $0.init_image = "srv/in.png"; $0.strength = 0.55 })
    check(node(i2iPlain, "21")?.0 == "LoadImage" && node(i2iPlain, "22")?.0 == "VAEEncode", "i2i encodes the uploaded source image")
    check(ref(node(i2iPlain, "7")?.1["latent_image"], "22", 0) && (node(i2iPlain, "7")?.1["denoise"] as? Double) == 0.55,
          "i2i latent from the encode, denoise = strength")
    check(node(i2iPlain, "8") == nil && node(i2iPlain, "25") == nil, "no empty canvas and no mask nodes without boxes")
    i2iPlain = remoteGraph({ $0.init_image = "srv/in.png"; $0.mask = "srv/ms.png"; $0.strength = 0.8 })
    check(node(i2iPlain, "23")?.0 == "LoadImageMask" && node(i2iPlain, "25")?.0 == "SetLatentNoiseMask", "masked: LoadImageMask fed straight to SetLatentNoiseMask")
    check(node(i2iPlain, "24") == nil, "no server-side blur node: the mask arrives pre-feathered from the app")
    check(ref(node(i2iPlain, "25")?.1["samples"], "22", 0) && ref(node(i2iPlain, "25")?.1["mask"], "23", 0), "mask applies to the encoded source latent")

    // app-side feathering must reproduce the CLI's own contract (moss_image_mlx tests/test_i2i.py::test_mask_feather,
    // ported): 256² mask, box y 100..(140 x 60..(200, feather 16 — interiors stay 1.0, the dilated edge ramps to zero
    let mrep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // setColor silently writes nothing in this headless harness (verified: colorAt reads back 0,0,0,0 even after a
    // fresh allocation and premultiplied probe), so the fixture is written pixel-byte directly: RGBA, alpha 255
    let bpr = mrep.bytesPerRow
    for y in 0..<256 { for x in 0..<256 {
        let p = mrep.bitmapData! + y * bpr + x * 4
        let on = (100..<140).contains(y) && (60..<200).contains(x)
        p[0] = on ? 255 : 0; p[1] = 0; p[2] = 0; p[3] = 255
    } }
    let mpath = tmp.appendingPathComponent("mask-fixture.png")
    try! mrep.representation(using: .png, properties: [:])!.write(to: mpath)
    let soft = Generator.featherMask(mpath.path, radius: 16)
    defer { if soft != mpath.path { try? FileManager.default.removeItem(atPath: soft) } }   // the harness does not leak /tmp files either
    if let sdata = try? Data(contentsOf: URL(fileURLWithPath: soft)), let srep = NSBitmapImageRep(data: sdata) {
        func v(_ x: Int, _ y: Int) -> Double { Double(srep.colorAt(x: x, y: y)?.redComponent ?? -1) }
        // the CLI's numpy soft[mask_row, mask_col] maps to CoreGraphics colorAt(x: col, y: row) — the swap matters:
        // col 100 vs row 120 sit in different parts of the 60..200 × 100..140 box. Interior: PIL's blur saturates the
        // uint8 interior at 255 (== 1.0 exactly); CoreImage's truncated kernel floors it near 0.98, which is the
        // accepted port tolerance (the bug this guards against reads ~0.64)
        check(v(100, 120) > 0.97, "painted interior stays fully regenerated (CLI contract soft[120,100] == 1.0, CoreImage kernel tolerance ≥ 0.97): \(v(100, 120))")
        check(v(100, 94) > 0.8, "dilated edge keeps its shape 10 px inside the dilated edge (CLI soft[94,100] > 0.8): \(v(100, 94))")
        check(v(100, 80) > 0 && v(100, 80) < 0.8 && v(100, 60) == 0, "4 px outside the dilated edge the ramp is mid-range, 24 px out it is zero (0 < soft[80,100] < 0.8, soft[60,100] == 0): \(v(100, 80)) \(v(100, 60))")
    } else { check(false, "featherMask output readable as a PNG") }
    let feathered0 = Generator.featherMask(mpath.path, radius: 0)
    defer { if feathered0 != mpath.path { try? FileManager.default.removeItem(atPath: feathered0) } }
    if let zdata = try? Data(contentsOf: URL(fileURLWithPath: feathered0)), let zrep = NSBitmapImageRep(data: zdata) {
        func z(_ x: Int, _ y: Int) -> Double { Double(zrep.colorAt(x: x, y: y)?.redComponent ?? -1) }
        check(z(199, 119) == 1.0 && z(200, 119) == 0.0, "feather 0 still binarizes (hard edge at the stroke): \(z(199, 119)) \(z(200, 119))")
    } else { check(false, "featherMask radius 0 output readable") }

    // 15. remote LoRA selection: the sidebar's set is authoritative, the settings text is a translation layer
    check(Generator.remoteLoRAList("style-remote.safetensors:0.9", loras: [], loraState: [:]).map { "\($0.name):\($0.scale)" } == ["style-remote.safetensors:0.9"],
          "a plain settings entry is an always-on remote extra")
    check(Generator.remoteLoRAList("", loras: ["gouache.safetensors"], loraState: [:]).isEmpty, "disabled sidebar adapters stay off remotely")
    let sidebar = Generator.remoteLoRAList("", loras: ["gouache.safetensors", "dmd.safetensors"], loraState: ["gouache.safetensors": 1, "dmd.safetensors": 0.9])
    check(sidebar.map { "\($0.name):\($0.scale)" } == ["gouache.safetensors:1.0", "dmd.safetensors:0.9"], "enabled sidebar adapters go 1:1 with their scales: \(sidebar)")
    let mapped = Generator.remoteLoRAList("gouache.safetensors=gouache-remote.safetensors:0.8, style-remote.safetensors:0.5",
                                          loras: ["gouache.safetensors", "dmd.safetensors"], loraState: ["gouache.safetensors": 1, "dmd.safetensors": 0.9])
    check(mapped.map { "\($0.name):\($0.scale)" } == ["gouache-remote.safetensors:0.8", "dmd.safetensors:0.9", "style-remote.safetensors:0.5"],
          "mappings translate enabled adapters in place; extras ride along: \(mapped)")
    check(Generator.remoteLoRAList("bad.txt=good.safetensors, nope", loras: ["a.safetensors"], loraState: ["a.safetensors": 1]).map { $0.name } == ["a.safetensors"],
          "malformed mapping lines drop without breaking the sidebar set")
    var remotePlain = gen.currentRender(seed: 3); remotePlain.references = nil; remotePlain.rgba = nil; remotePlain.keep_alpha = nil
    remotePlain.edit_format = nil; remotePlain.control_color = nil; remotePlain.control_depth = nil
    check(!Generator.needsLocal(remotePlain), "plain renders may go to ComfyUI")
    var remoteEdit = remotePlain; remoteEdit.references = ["/tmp/a.png"]
    var remoteAlpha = remotePlain; remoteAlpha.rgba = true
    var remoteControl = remotePlain; remoteControl.control_depth = "/tmp/d.png"
    check(Generator.needsLocal(remoteEdit) && Generator.needsLocal(remoteAlpha) && Generator.needsLocal(remoteControl),
          "edit, transparency and control renders stay local instead of degrading to plain i2i remotely")

    // 15b. F1 boundary: a long LoRA chain can never collide with the fixed node ids; validate catches every shape
    for count in [0, 1, 10, 15] {
        let many = (0..<count).map { ComfyGraph.LoRA(name: "l\($0).safetensors", scale: 0.5) }
        var g = remoteGraph({ $0.init_image = "srv/in.png" }, loras: many, slg: "22")
        check(ComfyGraph.validate(g).isEmpty, "\(count) LoRAs, slg + i2i: no dangling or self-referencing links: \(ComfyGraph.validate(g))")
        check(ref(node(g, "7")?.1["model"], "20", 0), "\(count) LoRAs: KSampler samples the SLG node")
        let last = String(99 + count)
        check(ref(node(g, "20")?.1["model"], count == 0 ? "1" : last, 0), "\(count) LoRAs: SLG samples \(count == 0 ? "the UNet" : "the last chain node \(last)")")
        if count > 0 { check(node(g, last)?.0 == "LoraLoaderModelOnly", "\(count) LoRAs: \(last) is a LoRA node") }
        g = remoteGraph({ _ in }, loras: many)
        check(ComfyGraph.validate(g).isEmpty && ref(node(g, "7")?.1["model"], count == 0 ? "1" : String(99 + count), 0), "\(count) LoRAs, plain t2i chain intact")
    }

    // 15c. WebSocket event parsing (F4): every kind the server emits, and gifs of garbage degrade to nil
    check(ComfyEvents.parse(#"{"type":"progress","data":{"value":7,"max":8,"prompt_id":"p"}}"#.data(using: .utf8)!) == .progress(id: "p", step: 7, of: 8),
          "progress event parses with the step pair")
    check(ComfyEvents.parse(#"{"type":"executing","data":{"node":null,"prompt_id":"p"}}"#.data(using: .utf8)!) == .executing(id: "p", node: nil),
          "a null node means the prompt finished")
    check(ComfyEvents.parse(#"{"type":"executing","data":{"node":"12","prompt_id":"p"}}"#.data(using: .utf8)!) == .executing(id: "p", node: "12"),
          "per-node executing still carries the node id")
    check(ComfyEvents.parse(#"{"type":"execution_error","data":{"prompt_id":"p"}}"#.data(using: .utf8)!) == .error(id: "p"),
          "execution_error parses")
    check(ComfyEvents.parse(Data([0xFF, 0xFE, 0x67, 0x61, 0x72, 0x62])) == nil
        && ComfyEvents.parse(#"{"type":"status","data":{"sid":"x"}}"#.data(using: .utf8)!) == nil,
          "malformed and non-progress events parse to nil, never crash")

    // 16. remote run path end to end: stub ComfyUI server, real runner
    let pyDir = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
    if FileManager.default.isExecutableFile(atPath: pyDir) {
        let stubScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("comfy_stub.py")
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!   // 1x1; every served image is these bytes
        let pngB64 = tmp.appendingPathComponent("stub.png.b64")
        try! onePixelPNG.base64EncodedString().write(to: pngB64, atomically: true, encoding: .utf8)

        func waitFor(_ condition: @autoclosure () -> Bool, _ seconds: Double) async -> Bool {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { if condition() { return true }; await Task.sleep(seconds: 0.15) }
            return condition()
        }
        func readDump(_ url: URL) async -> [String: Any] {
            for _ in 0..<40 {   // the stub rewrites the dump after every request; brief retries cover the write
                if let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
                await Task.sleep(seconds: 0.1)
            }
            return [:]
        }
        func spawnStub(_ port: Int, mode: String = "", nonce: String = "") -> (Process, URL) {
            let dump = tmp.appendingPathComponent("comfy-dump-\(port).json")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pyDir)
            p.arguments = [stubScript.path, String(port), pngB64.path, dump.path, mode, nonce]   // mode "" = poll-only moves on no ws
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run()
            return (p, dump)
        }
        func startStub(mode: String = "") async -> (Process, URL, String)? {
            let ports = mode.isEmpty ? [18789, 18790, 18791] : (mode == "progress" ? [18801] : [18802])
            let nonce = UUID().uuidString
            for port in ports {
                let (p, dump) = spawnStub(port, mode: mode, nonce: nonce)
                let base = URL(string: "http://127.0.0.1:\(port)")!
                var alive = false
                for _ in 0..<25 {
                    if (try? await ComfyClient(base: base).ping()) != nil { alive = true; break }
                    await Task.sleep(seconds: 0.2)
                }
                // a stale stub from an earlier run also answers the ping; only our nonce proves it's this one
                var ours = false
                if alive, let (d, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("system_stats")),
                   String(decoding: d, as: UTF8.self).contains(nonce) { ours = true }
                if alive && ours { return (p, dump, "http://127.0.0.1:\(port)") }
                p.terminate()   // something took this port, or a stale server owns it; try the next
            }
            return nil
        }

        if let (stubProc, dump, url) = await startStub() {
            gen.backend = "comfy"; gen.comfyURL = url
            gen.comfyCheckpoint = "mock-unet.safetensors"; gen.comfyTextEncoder = "mock-te.safetensors"; gen.comfyVAE = "mock-vae.safetensors"
            gen.comfyLoras = "dmd.safetensors:0.9"
            gen.randomSeed = false; gen.seed = 42; gen.steps = 8; gen.guidance = 1; gen.tier = "compact"
            gen.loras = []; gen.loraState = [:]

            // text to image: no uploads, settings forwarded, the served PNG lands locally, sidecar restorable
            let localBefore = gen.jobs.count
            gen.tab = "t2i"; gen.layout = MossLayout(); gen.prompt = "a sign SENT"
            gen.generate()
            check(await waitFor(gen.jobs.count == localBefore + 1, 30), "stub t2i run finished: \(gen.status)")
            check(gen.status == "Done", "t2i ends Done: \(gen.status)")
            if gen.jobs.count == localBefore + 1, let job = gen.jobs.first {
                check((try? Data(contentsOf: job.url)) == onePixelPNG, "the served PNG lands at the job's output path")
                check(gen.restore(job.url)?.prompt == "a sign SENT", "sidecar restores the typed prompt")
                let r = gen.render(from: job)
                check(r?.guidance == 1 && r?.steps == 8 && r?.seed == 42, "sidecar round-trips guidance/steps/seed")
            }
            var st = await readDump(dump)
            var graphs = st["prompts"] as? [[String: Any]] ?? []
            check(graphs.count == 1, "one prompt submitted for one render: \(graphs.count)")
            if let g = graphs.first {
                func inputs(_ id: String) -> [String: Any] { (g[id] as? [String: Any])?["inputs"] as? [String: Any] ?? [:] }
                check(inputs("5")["text"] as? String == "a sign SENT", "the typed prompt goes in verbatim")
                check(inputs("1")["unet_name"] as? String == "mock-unet.safetensors"
                    && inputs("2")["clip_name"] as? String == "mock-te.safetensors"
                    && inputs("3")["vae_name"] as? String == "mock-vae.safetensors", "server model files named from settings")
                check(inputs("7")["seed"] as? Int == 42 && inputs("7")["steps"] as? Int == 8 && inputs("7")["cfg"] as? Double == 1, "sampler settings forwarded")
                check(inputs("100")["lora_name"] as? String == "dmd.safetensors" && inputs("100")["strength_model"] as? Double == 0.9, "remote LoRA spec forwarded on the server's lora_name input")
                check(g["21"] == nil, "t2i uploads nothing")
            }
            let uploadsAfterT2I = (st["uploads"] as? [Any])?.count ?? 0
            check(uploadsAfterT2I == 0, "no uploads in text to image: \(uploadsAfterT2I)")
            let polls = (st["hits"] as? [String: Int])?.values.max() ?? 0
            check(polls >= 3, "the runner polled history until the image finished: \(polls) polls")

            // box edit: source PNG and mask uploaded, graph is LoadImage→VAEEncode + mask + SetLatentNoiseMask
            let src = tmp.appendingPathComponent("e2e-src.png")
            let img = NSImage(size: NSSize(width: 1024, height: 1024)); img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill(); img.unlockFocus()
            try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: src)
            let secondBefore = gen.jobs.count
            gen.initImage = src.path; gen.tab = "i2i"; gen.strength = 0.55; gen.megapixels = 1
            gen.layout = MossLayout(items: [LayoutItem(label: "text", caption: "sign", text: "49 kr.", x0: 10.4, y0: 10.6, x1: 200.2, y1: 120.5)])
            gen.prompt = "an edited scene"
            gen.generate()
            check(await waitFor(gen.jobs.count == secondBefore + 1, 40), "stub i2i run finished: \(gen.status)")
            st = await readDump(dump)
            graphs = st["prompts"] as? [[String: Any]] ?? []
            check(graphs.count == 2, "two prompts for two runs: \(graphs.count)")
            let uploadsAfterI2I = (st["uploads"] as? [Any])?.count ?? 0
            check(uploadsAfterI2I == 2, "source PNG and mask uploaded: \(uploadsAfterI2I)")
            if graphs.count == 2, let g = graphs.last {
                func inputs(_ id: String) -> [String: Any] { (g[id] as? [String: Any])?["inputs"] as? [String: Any] ?? [:] }
                check(g["21"] != nil && g["22"] != nil, "source image node chain present")
                check(g["23"] != nil && g["25"] != nil, "mask chain present for the box edit")
                check(ref(((g["25"] as? [String: Any])?["inputs"] as? [String: Any] ?? [:])["samples"], "22", 0), "mask applies to the encoded source")
                check(inputs("7")["denoise"] as? Double == 0.55, "denoise is the strength slider: \(inputs("7")["denoise"] ?? "nil")")
                check(g["8"] == nil, "no empty canvas in an edit")
            }
            if gen.jobs.count >= 2, let job = gen.jobs.first {
                check((try? Data(contentsOf: job.url)) == onePixelPNG, "the edit result also lands locally")
                check(gen.render(from: job)?.init_image == src.path, "the sidecar records the local source path")
            }

            stubProc.terminate()

            // ws mode: the socket drives the step counters the UI shows (progress 7/8 then finish); polling still lands the image
            if let (wsProc, _, wsURL) = await startStub(mode: "progress") {
                gen.comfyURL = wsURL; gen.prompt = "a sign SENT over ws"
                let beforeWS = gen.jobs.count
                gen.tab = "t2i"; gen.layout = MossLayout(); gen.generate()
                check(await waitFor(gen.jobs.count == beforeWS + 1, 30), "ws run finished: \(gen.status)")
                check(gen.step == 7 && gen.totalSteps == 8, "ws progress drove the step counters: \(gen.step)/\(gen.totalSteps)")
                check(!gen.status.isEmpty, "through the socket or the poll, some status is shown")
                wsProc.terminate()
            } else { print("skip  no free ws stub port") }

            // error mode: the history entry carries status_str error → fail fast, no image, queue drained
            if let (errProc, _, errURL) = await startStub(mode: "error") {
                gen.comfyURL = errURL; gen.prompt = "an OOM'd render"
                let beforeErr = gen.jobs.count
                gen.generate()
                check(await waitFor(gen.status.hasPrefix("ComfyUI:"), 20), "errored prompt fails fast: \(gen.status)")
                check(gen.jobs.count == beforeErr && gen.pending.isEmpty && !gen.running, "an errored prompt adds no image and unwinds")
                errProc.terminate()
            } else { print("skip  no free error stub port") }
        } else { print("skip  no free stub port in 18789-18791") }

        // a dead address reports a status instead of crashing; the queue drains
        gen.backend = "comfy"; gen.comfyURL = "http://127.0.0.1:18792"   // nothing listens there
        gen.tab = "t2i"; gen.layout = MossLayout(); gen.initImage = ""; gen.prompt = "tries a dead server"
        let jobsBeforeDead = gen.jobs.count
        gen.generate()
        check(await waitFor(gen.status.hasPrefix("ComfyUI:"), 15), "dead server reports a status: \(gen.status)")
        check(!gen.running && gen.jobs.count == jobsBeforeDead, "the runner wound down after the failure")
        gen.backend = "local"; gen.comfyURL = "http://127.0.0.1:18789"; gen.comfyLoras = ""
    } else { print("skip  no python3 for the ComfyUI stub") }

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

final class EvictionCount: NSObject, NSCacheDelegate {
    var n = 0
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) { n += 1 }
}
