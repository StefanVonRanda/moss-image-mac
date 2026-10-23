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
                    if gen.layoutMode {
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

                category("Size", $sizeExpanded) {
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
}

// ponytail: hardcoded list; move to a JSON file when it grows past a handful
let knownLoras = [
    KnownLora(id: "dmd8", repo: "lodestones/MOSS-Image-SFT-8-steps-dmd", file: "lora.safetensors",
              steps: 8, guidance: 1, trigger: nil, note: "Few-step: 8 steps, no CFG, strength 1.0 (lodestones, Apache-2.0)"),
    KnownLora(id: "dmd8-latest", repo: "lodestones/MOSS-Image-SFT-8-steps-dmd", file: "lora_latest.safetensors",
              steps: 8, guidance: 1, trigger: nil, note: "Newer few-step checkpoint, author suggests strength 0.7"),
    KnownLora(id: "gouache", repo: "axiomofmind/Moss-image-gouache-lora", file: "pytorch_lora_weights.safetensors",
              steps: nil, guidance: nil, trigger: "moss_vgouache_style", note: "Vintage gouache illustration style (axiomofmind, Apache-2.0); trigger word set automatically"),
]

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
                        gen.downloadLora(repo: k.repo, file: k.file) {
                            if let s = k.steps { gen.steps = s }
                            if let g = k.guidance { gen.guidance = g }
                            if k.file == "lora_latest.safetensors" { gen.enable(gen.loras.first { $0.hasSuffix("__lora_latest.safetensors") } ?? "", scale: 0.7) }
                            if let t = k.trigger, let file = gen.loras.first(where: { $0.hasPrefix(k.repo.replacingOccurrences(of: "/", with: "__")) }) {
                                var tr = gen.loraTriggers; tr[file] = t; gen.loraTriggers = tr
                            }
                        }
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
