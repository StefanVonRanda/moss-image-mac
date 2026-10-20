import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ControlsView: View {
    @ObservedObject var gen: Generator
    @State private var showDownload = false
    @State private var showLayout = false
    @State private var showMask = false
    @AppStorage("showAdvanced") private var showAdvanced = false

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "safetensors")!]
        panel.message = "Choose a LoRA .safetensors file to copy into the library"
        if panel.runModal() == .OK, let url = panel.url { gen.importLora(url) }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.message = "Choose a source image"
        if panel.runModal() == .OK, let url = panel.url { gen.initImage = url.path; gen.maskPath = "" }
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $gen.prompt)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                HStack {
                    Button(gen.enhancing ? "Enhancing…" : "Enhance") { gen.enhance() }
                        .disabled(gen.enhancing || gen.prompt.isEmpty)
                        .help("Expand the idea into a detailed caption (or a layout, in layout mode) with Claude")
                    if gen.promptBeforeEnhance != nil { Button("Revert") { gen.revertEnhance() } }
                    Spacer()
                    Toggle("Layout", isOn: $gen.layoutMode).toggleStyle(.checkbox)
                        .help("Send the prompt as a MOSS-Image layout with text and object boxes")
                    Button("Edit layout…") { showLayout = true }
                }
                .controlSize(.small)
                if gen.layoutMode {
                    Text(gen.layout.items.isEmpty ? "No boxes yet. Edit layout… or Enhance." : "\(gen.layout.items.count) boxes · prompt is the summary caption")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Prompt") }

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

            Section("Source image") {
                if gen.initImage.isEmpty {
                    HStack {
                        Text("None · text to image").foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: pickImage).controlSize(.small)
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        if let img = NSImage(contentsOf: URL(fileURLWithPath: gen.initImage)) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(URL(fileURLWithPath: gen.initImage).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            HStack {
                                Text("Strength")
                                Slider(value: $gen.strength, in: 0.1...1, step: 0.05)
                                Text(String(format: "%.2f", gen.strength)).monospacedDigit().frame(width: 36)
                            }
                            .controlSize(.small)
                            .help("How much to change: 0.3 keeps the picture, 0.8 only keeps the composition")
                            HStack {
                                Button(gen.maskPath.isEmpty ? "Edit mask…" : "Mask set · edit…") { showMask = true }
                                Button("Choose…", action: pickImage)
                                Spacer()
                                Button("Clear") { gen.initImage = ""; gen.maskPath = "" }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                providers.first?.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in gen.initImage = url.path; gen.maskPath = "" }
                }
                return true
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
                    .contentShape(Rectangle())
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
        }
        .sheet(isPresented: $showDownload) { DownloadSheet(gen: gen) }
        .sheet(isPresented: $showLayout) { LayoutEditor(gen: gen) }
        .sheet(isPresented: $showMask) { MaskEditor(gen: gen) }
        .formStyle(.grouped)
        .background(OverlayScrollers())
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
            Text("Known few-step adapters").font(.subheadline).foregroundStyle(.secondary)
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
