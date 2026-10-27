import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A category header: uppercase and tracked, with the chevron on the right. The whole row toggles.
private struct CategoryHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(.system(size: 11.5, weight: .semibold))
                        .tracking(1.3)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                Divider().padding(.top, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

struct ControlsView: View {
    @ObservedObject var gen: Generator
    @State private var showDownload = false
    @State private var loraToTrash: String?
    @AppStorage("promptExpanded") private var promptExpanded = true
    @AppStorage("sourceExpanded") private var sourceExpanded = true
    @AppStorage("extendExpanded") private var extendExpanded = true
    @AppStorage("sizeExpanded") private var sizeExpanded = true
    @AppStorage("loraExpanded") private var loraExpanded = true
    @AppStorage("showAdvanced") private var showAdvanced = false
    @State private var showAllLoras = false

    private func pickSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.message = "Choose a source image"
        if panel.runModal() == .OK, let url = panel.url { gen.setSource(url.path) }
    }

    private func pickReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.message = "Choose a picture for the prompt to refer to"
        if panel.runModal() == .OK, let url = panel.url { gen.addReference(url.path) }
    }

    /// Instruction edit: the pictures in the order the prompt numbers them, the added ones with a remove button.
    private var referenceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(Array(gen.references.enumerated()), id: \.element) { i, path in
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let img = ImageCache.thumbnail(path) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                                else { Color.secondary.opacity(0.2) }   // moved or deleted: still sent, the CLI reports it
                            }
                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 5))
                            .help(path)
                            if i > 0 {
                                Button { gen.removeReference(path) } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).offset(x: 5, y: -5)
                                .accessibilityLabel("Remove picture \(i + 1)")
                            }
                        }
                        Text(verbatim: "\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Add reference…") { pickReference() }
                    .controlSize(.small).disabled(gen.references.count >= Generator.maxReferences)
                    .help("Up to \(Generator.maxReferences) pictures. Or drop an image or a history thumbnail here.")
            }
            Text(gen.references.count > 1 ? "The prompt calls these picture 1, picture 2\u{2026} in this order; picture 1 is the one edited, e.g. \u{201C}Put the fox from picture 2 on the street in picture 1\u{201D}."
                                          : "Add pictures for the prompt to refer to as picture 2, 3, 4: drop them here, or \u{201C}Use as reference\u{201D} on a result.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .dropToReference(gen)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "safetensors")!]
        panel.message = "Choose a LoRA .safetensors file to copy into the library"
        if panel.runModal() == .OK, let url = panel.url { gen.importLora(url) }
    }

    /// One side of the extension: percent field and 5 % stepper, with the pixels it adds to the output.
    private func padRow(_ side: String, _ key: WritableKeyPath<Pad, Double>, px: Int?) -> some View {
        let percent = Binding(get: { gen.pad[keyPath: key] * 100 },
                              set: { var p = gen.pad; p[keyPath: key] = min(max($0, 0), 300) / 100; gen.pad = p })
        return LabeledContent(side) {
            HStack(spacing: 4) {
                TextField(side, value: percent, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 52)
                Text("%").foregroundStyle(.secondary)
                Stepper(side, value: percent, in: 0...300, step: 5).labelsHidden()
                Text(verbatim: "\(px ?? 0) px").monospacedDigit().foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
            }
        }
    }

    private var qualityNote: String {
        switch gen.quality {
        case "turbo" where gen.effectiveQuality == "draft":
            return gen.usingSource ? "Turbo makes new pictures only: this edit renders as Draft."
                : gen.controlling ? "Turbo takes no control maps: this render goes as Draft." : "Turbo is trained for the SFT models: Base renders as Draft."
        case "turbo": return "15 passes, about twice Draft's time and close to Full. Few-step adapters stay off for it and Steps don't apply. The first run downloads 600 MB."
        case "full": return "The official 50 steps with CFG 3, about 12\u{00D7} Draft's time. Few-step adapters stay off for it; a destripe adapter removes faint vertical stripes."
        default: return gen.fewStepOn ? "\(gen.steps) steps with the few-step adapter: fastest." : "No few-step adapter is on: renders at the Steps and CFG in Advanced."
        }
    }

    /// A category block: the header row, a rule, then its controls while it is expanded.
    @ViewBuilder
    private func category<Content: View>(_ title: String, _ expanded: Binding<Bool>,
                                         @ViewBuilder content: () -> Content) -> some View {
        Section {
            if expanded.wrappedValue { content() }
        } header: {
            CategoryHeader(title: title, isExpanded: expanded)
        }
    }

    var body: some View {
        Form {
            category("Prompt", $promptExpanded) {
                    if gen.isBoxEdit {
                        Text("Not used for box edits. The words to render go in the boxes; everything outside them is kept.")
                            .foregroundStyle(.secondary).frame(minHeight: 60)
                    } else {
                        TextEditor(text: $gen.prompt)
                            .font(.body)
                            .frame(minHeight: 140)
                            .scrollContentBackground(.hidden)
                    }
                    HStack {
                        Button(gen.enhancing ? "Enhancing…" : "Enhance") { gen.enhance() }
                            .disabled(gen.enhancing || gen.prompt.isEmpty)
                            .help("Expand the idea into a detailed caption (or a layout, in layout mode) with the Enhance model chosen in Settings")
                        if gen.promptBeforeEnhance != nil { Button("Revert") { gen.revertEnhance() } }
                        if !gen.recentPrompts.isEmpty {
                            Menu("Recent") {
                                ForEach(gen.recentPrompts, id: \.self) { p in
                                    let line = p.split(whereSeparator: \.isNewline).joined(separator: " ")
                                    Button(line.count > 60 ? line.prefix(60) + "…" : line) { gen.prompt = p }.help(p)
                                }
                                Divider()
                                Button("Clear recent") { gen.recentPrompts = [] }
                            }
                            .fixedSize()
                            .help("Prompts you generated with, newest first")
                        }
                        Spacer()
                        if gen.layoutMode {
                            Button("Clear boxes") { let before = gen.layout; var l = before; l.items = []; gen.layout = l; gen.recordUndo(before) }
                                .help("Remove all layout boxes; the prompt goes back to a plain caption")
                        }
                    }
                    .controlSize(.small)
                    if gen.tab == "t2i" {
                        Toggle("Transparent background", isOn: $gen.transparent)
                            .help("A PNG with an alpha channel: the subject only, no background. Downloads a 130 MB adapter on first use.")
                        if gen.transparent {
                            Text("Describe the subject, not a scene; \u{201C}isolated on a transparent background\u{201D} is added for you. Boxes work too, but a prompt or box that names a setting (a forest, a sign on a wall) brings the background back. The adapter (paralaif) is for non-commercial use.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if gen.layoutMode, !gen.instructing {
                        Text(gen.usingSource ? "\(gen.layout.items.count) boxes. A text box's caption defaults to the surrounding style; name a colour or font only if it should differ."
                                             : "\(gen.layout.items.count) layout boxes are sent. The prompt is the scene's summary caption: describe the whole picture. Words to render go in text boxes.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !gen.tinyBoxes.isEmpty {
                            Text("\(gen.tinyBoxes.count) box(es) under 40 px at this output size. Raise Pixels or draw bigger.").font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                if gen.tab == "i2i", !gen.initImage.isEmpty {
                    category("Source image", $sourceExpanded) {
                        HStack(spacing: 10) {
                            if let img = ImageCache.thumbnail(gen.initImage) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            Text(URL(fileURLWithPath: gen.initImage).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Change…") { pickSource() }.controlSize(.small)
                        }
                        .dropToReference(gen)
                        Picker("Edit by", selection: $gen.editMode) {
                            Text("Strength").tag("retouch")
                            Text("Instruction").tag("instruct")
                        }
                        .pickerStyle(.segmented)
                        .help("Strength re-renders the picture, its boxes or an extension. Instruction keeps the picture and changes what the prompt names.")
                        if gen.sourceHasAlpha {
                            Toggle("Keep transparency", isOn: $gen.keepAlpha)
                                .help("The result gets the source's alpha channel, so the cutout stays a cutout.")
                                .disabled(gen.outpainting)
                            Text(gen.outpainting ? "Not while extending: the new area has no alpha." : gen.keepAlpha
                                 ? "The source's outline is reused as is: suits edits that keep the shape (colour, material, texture), not ones that move or add things."
                                 : "Transparent areas are filled with grey for the edit and the result is opaque.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if gen.instructing {
                            referenceRow
                            Text("Say what to change in the prompt, e.g. \u{201C}Make the jacket red, keep everything else\u{201D}. The result becomes the source, so edits can follow one another. Boxes are not used. Downloads a 300 MB adapter on first use.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                        LabeledContent(gen.layout.items.isEmpty ? "Strength" : "Strength in boxes") {
                            HStack {
                                Slider(value: $gen.strength, in: 0.1...1, step: 0.05)
                                Text(String(format: "%.2f", gen.strength)).monospacedDigit().frame(width: 36)
                            }
                        }
                        .help(gen.layout.items.isEmpty ? "No boxes: the whole image is re-rendered. 0.3 keeps the picture, 0.8 keeps only the composition."
                                                        : "Applies inside the boxes only. 1.0 replaces the content, lower values retouch it.")
                        .disabled(gen.outpainting)
                        Text(gen.outpainting ? "Extending: the new area (and any boxes) is generated at full strength; the rest stays identical."
                             : gen.layout.items.isEmpty ? "Whole image is re-rendered at this strength." : "Only the box areas are regenerated; the rest stays identical.")
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if !gen.instructing {
                    category("Extend canvas", $extendExpanded) {
                        padRow("Left", \.left, px: gen.imageRect.map { Int($0.minX) })
                        padRow("Right", \.right, px: gen.imageRect.map { gen.width - Int($0.maxX) })
                        padRow("Top", \.top, px: gen.imageRect.map { Int($0.minY) })
                        padRow("Bottom", \.bottom, px: gen.imageRect.map { gen.height - Int($0.maxY) })
                        HStack {
                            Menu("Extend to") {
                                ForEach(Generator.aspects, id: \.0) { a in Button(a.0) { gen.extend(to: a.1) } }
                                Divider()
                                Button("+25 % all round") { gen.pad = Pad(left: 0.125, right: 0.125, top: 0.125, bottom: 0.125) }
                            }
                            .fixedSize()
                            .help("Grow the canvas to an aspect, evenly on both sides; or 12.5 % on every side")
                            Spacer()
                            Button("Reset") { gen.pad = Pad() }.disabled(gen.pad == Pad())
                        }
                        .controlSize(.small)
                        Text(gen.outpainting ? "Output " + String(gen.width) + " × " + String(gen.height) + ". The hatched area is generated and blends into the picture's edges. The prompt describes the whole, larger picture; leave it empty to just continue the scene."
                                             : "Percent of the image's width (left, right) or height (top, bottom). The output stays within the pixel budget.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    }
                }

                category("Quality and size", $sizeExpanded) {
                    Picker("Quality", selection: $gen.quality) {
                        Text("Draft").tag("draft")
                        Text("Turbo").tag("turbo")
                        Text("Full").tag("full")
                    }
                    .pickerStyle(.segmented)
                    .help("Draft: a few steps with the DMD adapter. Turbo: the engine's trained 15-pass sampler, close to Full. Full: the official 50 steps with CFG 3.")
                    Text(qualityNote).font(.caption).foregroundStyle(.secondary)
                    if gen.usingSource {
                        LabeledContent("Aspect", value: "Source image")
                    } else {
                        Picker("Aspect", selection: Binding(get: { gen.aspect == "source" ? "custom" : gen.aspect }, set: { gen.aspect = $0 })) {
                            ForEach(Generator.aspects, id: \.0) { Text($0.0).tag($0.0) }
                            Divider()
                            Text("Custom").tag("custom")
                        }
                        .onChange(of: gen.aspect) { gen.applyPreset() }
                    }
                    if gen.aspect == "custom" || (gen.aspect == "source" && !gen.usingSource) {
                        // value fields write on Return or focus loss, so boxes rescale once per typed size, not per keystroke
                        TextField("Width", value: Binding(get: { gen.width }, set: { gen.resize($0, gen.height) }), format: .number.grouping(.never))
                        TextField("Height", value: Binding(get: { gen.height }, set: { gen.resize(gen.width, $0) }), format: .number.grouping(.never))
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

                category("LoRA", $loraExpanded) {
                    if gen.loras.isEmpty {
                        Text("No adapters in the library.").foregroundStyle(.secondary)
                    }
                    // the active adapters with their rows; the whole library only on request, or when none is on
                    let active = gen.loras.filter { gen.loraState[$0] != nil }
                    ForEach(showAllLoras || active.isEmpty ? gen.loras : active, id: \.self) { file in
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
                            Button("Move to Trash…") { loraToTrash = file }
                        }
                    }
                    if !active.isEmpty, active.count < gen.loras.count {
                        Button(showAllLoras ? "Show active only" : "Show all (\(gen.loras.count))") { showAllLoras.toggle() }
                            .buttonStyle(.link).controlSize(.small)
                    }
                    HStack {
                        Button("Add file…", action: pickFile)
                        Button("Download…") { showDownload = true }.disabled(gen.downloading)
                        Spacer()
                        Button("Show folder") { NSWorkspace.shared.open(URL(fileURLWithPath: gen.loraDir)) }
                    }
                    .controlSize(.small)
                }

                category("Advanced", $showAdvanced) {
                    Group {
                        Stepper("Steps: \(gen.steps)", value: $gen.steps, in: 1...100)
                        HStack {
                            Text("CFG")
                            Slider(value: $gen.guidance, in: 1...8, step: 0.5)
                            Text(String(format: "%.1f", gen.guidance)).monospacedDigit().frame(width: 30)
                        }
                    }
                    .disabled(gen.effectiveQuality == "turbo")
                    .help(gen.effectiveQuality == "turbo" ? "Turbo runs its own schedule with CFG 3." : "Picking a Quality sets these; change them here if you like.")
                    TextField("Negative prompt", text: $gen.negative)
                    Toggle("Random seed", isOn: $gen.randomSeed)
                    TextField("Seed", value: $gen.seed, format: .number).disabled(gen.randomSeed)
                    Picker("Model", selection: $gen.tier) {
                        Text("Compact · 7 GB").tag("compact")
                        Text("8-bit · 9 GB").tag("8bit")
                        Text("Base 8-bit · 10 GB").tag(Generator.baseTier)
                    }
                    .help("Peak memory per model. Base is the checkpoint before fine-tuning, for adapters made for it (Base 8-step DMD).")
                    if gen.tab == "i2i" {
                        Stepper("Mask edge softness: \(gen.maskFeather) px", value: $gen.maskFeather, in: 0...64, step: 4)
                            .help("How far the regenerated patch blends into its surroundings. 0 gives a hard seam.")
                    }
                    TextField("Negative-branch skip layers", text: $gen.uncondSkip, prompt: Text("22"))
                        .help("Blocks skipped in the negative branch under CFG. Official default 22. Empty disables.")
                    TextField("Skip-layer guidance layers", text: $gen.slgLayers, prompt: Text("off"))
                        .help("Blocks to skip for skip-layer guidance, e.g. 8,9,10. Works without CFG too.")
                    if !gen.slgLayers.isEmpty {
                        HStack {
                            Text("SLG scale")
                            Slider(value: $gen.slgScale, in: 0...6, step: 0.25)
                            Text(String(format: "%.2f", gen.slgScale)).monospacedDigit().frame(width: 36)
                        }
                        HStack {
                            Text("SLG window")
                            Slider(value: $gen.slgStart, in: 0...1, step: 0.05)
                            Slider(value: $gen.slgStop, in: 0...1, step: 0.05)
                            Text(String(format: "%.2f–%.2f", gen.slgStart, gen.slgStop)).monospacedDigit().frame(width: 70)
                        }
                        .help("Fraction of the denoising schedule during which skip-layer guidance is active")
                    }
                }
        }
        .sheet(isPresented: $showDownload) { DownloadSheet(gen: gen) }
        .confirmationDialog("Move \(loraToTrash ?? "") to the Trash?", isPresented: Binding(get: { loraToTrash != nil }, set: { if !$0 { loraToTrash = nil } }),
                            presenting: loraToTrash) { file in
            Button("Move to Trash", role: .destructive) { gen.trashLora(file) }
        } message: { _ in Text("Its scale and trigger word are forgotten. You can put the file back from the Trash.") }
        .formStyle(.grouped)
        .background(OverlayScrollers())
    }
}

struct KnownLora: Identifiable {
    let id: String
    let repo: String
    let file: String
    let steps: Int?          // nil: leave sampling as it is
    let guidance: Double?
    let trigger: String?
    let note: String
    var strength: Double? = nil   // nil: 1.0, as every download is turned on
    var forBase = false           // made for the Base checkpoint: left off on the SFT tiers
}

// ponytail: hardcoded list; move to a JSON file when it grows past a handful
let knownLoras = [
    KnownLora(id: "dmd8", repo: "lodestones/MOSS-Image-SFT-8-steps-dmd", file: "lora.safetensors",
              steps: 8, guidance: 1, trigger: nil, note: "Few-step: 8 steps, no CFG, strength 1.0 (lodestones, Apache-2.0)"),
    KnownLora(id: "dmd8-latest", repo: "lodestones/MOSS-Image-SFT-8-steps-dmd", file: "lora_latest.safetensors",
              steps: 8, guidance: 1, trigger: nil, note: "Newer few-step checkpoint, author suggests strength 0.7", strength: 0.7),
    KnownLora(id: "sft4", repo: "akhaliq/MOSS-Image-SFT-4-steps", file: "lora.safetensors", steps: 4, guidance: 1, trigger: nil,
              note: "SFT model, 4 steps (v2), no CFG, strength 1.0; 6–8 steps above 1024² (akhaliq, Apache-2.0)"),
    KnownLora(id: "rapid4", repo: "darask0/MOSS-Image_4-step_adapter_lora", file: "lora.safetensors", steps: 4, guidance: 1, trigger: nil,
              note: "SFT model, 4 steps, no CFG; trained for its own sampler, author warns of a purple cast on others (darask0, Apache-2.0)"),
    KnownLora(id: "base-dmd8", repo: "lodestones/MOSS-Image-Base-8-steps-dmd", file: "lora.safetensors", steps: 8, guidance: 1, trigger: nil,
              note: "Base model only (Advanced ▸ Model ▸ Base 8-bit): 8 steps, no CFG, strength 1.0 (lodestones, Apache-2.0)", forBase: true),
    KnownLora(id: "gouache", repo: "axiomofmind/Moss-image-gouache-lora", file: "pytorch_lora_weights.safetensors",
              steps: nil, guidance: nil, trigger: "moss_vgouache_style", note: "Vintage gouache illustration style (axiomofmind, Apache-2.0); trigger word set automatically"),
]

extension Generator {
    /// After a known adapter's download, which turned it on at 1.0: its strength, step/CFG preset and trigger word.
    /// One made for Base stays off on an SFT tier with sampling untouched; its note says which model it is for.
    func apply(_ k: KnownLora) {
        let name = Self.loraName(repo: k.repo, file: k.file)
        if k.forBase, tier != Self.baseTier {
            var st = loraState; st[name] = nil; loraState = st
            status = "Downloaded \(name), left off: it is for the Base model (Advanced ▸ Model)"
            return
        }
        if k.steps != nil { quality = "draft" }   // a few-step adapter is what Draft renders with
        if let s = k.steps { steps = s }
        if let g = k.guidance { guidance = g }
        if let s = k.strength { enable(name, scale: s) }
        if let t = k.trigger { var tr = loraTriggers; tr[name] = t; loraTriggers = tr }
    }
}

struct DownloadSheet: View {
    @ObservedObject var gen: Generator
    @Environment(\.dismiss) private var dismiss
    @State private var query = "moss-image"
    @State private var results: [HubSearch.Model] = []
    @State private var searching = false
    @State private var chosen: HubSearch.Model?
    @State private var files: [String] = []
    @State private var repo = ""
    @State private var file = "lora.safetensors"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download a LoRA from Hugging Face").font(.headline)
            HStack {
                TextField("Search the Hub", text: $query).onSubmit { search() }
                Button("Search") { search() }.disabled(searching)
                if searching { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .top, spacing: 12) {
                List(results, selection: $chosen) { m in
                    HStack {
                        Text(m.id).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(m.downloads) ↓").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(m)
                }
                .frame(height: 220)
                VStack(alignment: .leading, spacing: 6) {
                    Text(chosen?.id ?? "Pick a repository").font(.subheadline).lineLimit(1).truncationMode(.middle)
                    if files.isEmpty, chosen != nil { Text("No .safetensors files").foregroundStyle(.secondary).font(.caption) }
                    ForEach(files, id: \.self) { f in
                        HStack {
                            Text(f).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Get") { gen.downloadLora(repo: chosen!.id, file: f); dismiss() }.controlSize(.small)
                        }
                    }
                    Spacer()
                }
                .frame(width: 230, height: 220)
            }
            .onChange(of: chosen) { _, m in
                files = []
                guard let m else { return }
                Task { files = (try? await HubSearch.files(m.id)) ?? [] }
            }
            Divider()
            Text("Known adapters").font(.subheadline).foregroundStyle(.secondary)
            ForEach(knownLoras) { k in
                HStack {
                    VStack(alignment: .leading) {
                        Text(k.repo + " · " + k.file).font(.body)
                        Text(k.note).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Get") {
                        gen.downloadLora(repo: k.repo, file: k.file) { gen.apply(k) }
                        dismiss()
                    }
                }
            }
            Divider()
            HStack {
                TextField("Repository", text: $repo, prompt: Text("user/repo"))
                TextField("File", text: $file)
                Button("Download") { gen.downloadLora(repo: repo, file: file); dismiss() }
                    .disabled(repo.split(separator: "/").count != 2 || file.isEmpty)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 640)
        .task { search() }
    }

    private func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        Task {
            results = (try? await HubSearch.models(query)) ?? []
            searching = false
        }
    }
}
