import SwiftUI
import AppKit

@main
struct MossImageApp: App {
    var body: some Scene {
        WindowGroup("MOSS Image") {
            ContentView()
                .frame(minWidth: 760, minHeight: 520)   // a tiling window manager's narrow tile: sidebar 300 + detail 440
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1240, height: 820)
        .commands { ImageCommands(); LayoutUndoCommands(); HelpCommands() }
        Settings { SettingsView() }
        Window("Keyboard Shortcuts", id: ShortcutsView.id) { ShortcutsView() }
            .windowResizability(.contentSize)
    }
}

/// ⌘Z / ⇧⌘Z: a text view being edited keeps its own undo (the window's UndoManager); otherwise the layout's.
struct LayoutUndoCommands: Commands {
    @FocusedObject private var gen: Generator?
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { run("undo:") { $0.undoLayout() } }.keyboardShortcut("z")
            Button("Redo") { run("redo:") { $0.redoLayout() } }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
    // ponytail: always enabled with plain titles: the same item serves text views, so disabling it on an empty layout stack would block their ⌘Z
    private func run(_ action: String, _ layout: (Generator) -> Void) {
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.sendAction(Selector(action), to: nil, from: nil) } else if let gen { layout(gen) }
    }
}

struct ContentView: View {
    @StateObject private var gen = Generator()
    @State private var narrow = false   // under the old 960 pt minimum: the Layout button drops its title so Generate stays in the toolbar
    @State private var setup = EngineSetup.needed ? EngineSetup.bundled.map { EngineSetup(root: EngineHome.appSupport(), payload: $0) } : nil

    var body: some View {
        content.onGeometryChange(for: Bool.self) { $0.size.width < 960 } action: { narrow = $0 }
            .background(WindowSnapshot()).background(TitlebarTitle()).background(KeyMonitor(gen: gen)).focusedSceneObject(gen)
            // Settings writes the same defaults keys. Works because Generator only reads them: an @AppStorage that
            // its object has set keeps that value and stops following outside writes.
            .onChange(of: gen.outputDir) { gen.loadHistory() }
            .onChange(of: gen.loraDir) { gen.refreshLoras() }
            .onReceive(NotificationCenter.default.publisher(for: .engineInstalled)) { _ in gen.engineInstalled() }
            .sheet(isPresented: Binding(get: { setup != nil }, set: { if !$0 { setup = nil } })) {
                if let setup { SetupView(setup: setup, modelSize: Generator.tierSizes[gen.tier] ?? "12 GB") }
            }
    }

    private var content: some View {
        NavigationSplitView {
            ControlsView(gen: gen)
                .navigationSplitViewColumnWidth(min: 300, ideal: 312, max: 420)   // 312 (+8) + the detail's 440 = the 760 minimum
                .navigationTitle("MOSS Image")
        } detail: {
            DetailView(gen: gen)
                .frame(minWidth: 440)
                .navigationTitle("")
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("", selection: $gen.tab) {
                    Text("Text").tag("t2i")
                    Text("Edit").tag("edit")
                    Text("Image").tag("i2i")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Text: a new picture from a prompt. Edit: say what to change in a picture. Image: re-render a picture, its boxes or an extension")
            }
            ToolbarItem(placement: .automatic) {
                if gen.tab == "t2i" {
                    Button { gen.layoutOverlay.toggle() } label: {
                        Label(gen.layout.items.isEmpty ? "Layout" : "Layout · \(gen.layout.items.count)",
                              systemImage: gen.layoutOverlay ? "rectangle.3.group.fill" : "rectangle.3.group")
                            .foregroundStyle(gen.layoutOverlay ? Color.accentColor : Color.primary)
                    }
                    .labelStyle(NarrowLabelStyle(narrow: narrow))
                    .help(gen.layoutOverlay ? "Hide the layout editor" : "Draw text and object boxes over the result; they are sent with the prompt")
                }
            }
            ToolbarItem(placement: .automatic) {
                if gen.running { Button("Cancel", action: gen.cancel) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(gen.running ? "Queue" : "Generate", action: gen.generate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘↩ · while a render runs, queues another with the current settings")
            }
        }
    }
}

/// Title and icon, or the icon alone when `narrow`.
private struct NarrowLabelStyle: LabelStyle {
    let narrow: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if narrow { IconOnlyLabelStyle().makeBody(configuration: configuration) } else { TitleAndIconLabelStyle().makeBody(configuration: configuration) }
    }
}

struct SettingsView: View {
    @AppStorage("cli") var cli = EngineHome.setupCLI()
    @AppStorage("loraDir") var loraDir = EngineHome.current.loras
    @AppStorage("outputDir") var outputDir = NSHomeDirectory() + "/Pictures/MOSS Image"
    @AppStorage("enhancerBackend") var enhancerBackend = "local"
    @AppStorage("enhancerModel") var enhancerModel = "claude-opus-5-5"
    @AppStorage("localModel") var localModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    // ComfyUI remote backend
    @AppStorage("backend") var backend = "local"
    @AppStorage("comfyURL") var comfyURL = "http://127.0.0.1:8188"
    @AppStorage("comfyCheckpoint") var comfyCheckpoint = "moss_image_sft_int8_convrot.safetensors"
    @AppStorage("comfyTextEncoder") var comfyTextEncoder = "qwen3.5_9b_w4a8_gptq.safetensors"
    @AppStorage("comfyVAE") var comfyVAE = "flux2-vae_small.safetensors"
    @AppStorage("comfyLoras") var comfyLoras = ""
    @State private var apiKey = Keychain.read("anthropic-api-key") ?? ""
    @State private var comfyToken = Keychain.read("comfy-token") ?? ""
    @State private var pingResult = ""
    @State private var reinstall: EngineSetup?

    var body: some View {
        Form {
            Section("Engine") {
                let home = EngineHome(cli: cli), installed = FileManager.default.isExecutableFile(atPath: home.cli)
                LabeledContent("Location", value: home.root).textSelection(.enabled)
                LabeledContent("Version", value: installed ? home.version ?? "unknown" : "not installed")
                if let payload = EngineSetup.bundled, home.root == EngineHome.appSupport() {
                    Button(installed ? "Reinstall Engine…" : "Install Engine…") { reinstall = EngineSetup(root: home.root, payload: payload) }
                } else if !installed {
                    Text("No executable at this path. Run ./setup.sh from the app's folder, then choose bin/moss-mlx in the folder it installed into (~/moss-mlx by default).")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Section("Paths") {
                // shows the CLI that runs: the setting's when it is executable, else the app's own engine
                PathRow(title: "moss-mlx executable", path: Binding(get: { EngineHome(cli: cli).cli }, set: { cli = $0 }), folder: false)
                PathRow(title: "LoRA folder", path: $loraDir)
                PathRow(title: "Output folder", path: $outputDir)
            }
            Section("Image backend") {
                Picker("Generate on", selection: $backend) {
                    Text("This Mac (moss-mlx)").tag("local")
                    Text("ComfyUI server").tag("comfy")
                }
                .pickerStyle(.radioGroup)
                if backend == "comfy" {
                    TextField("Server address", text: $comfyURL, prompt: Text("http://host:8188"))
                    SecureField("Auth token (optional)", text: $comfyToken)
                        .onChange(of: comfyToken) { Keychain.write("comfy-token", comfyToken) }
                    TextField("Checkpoint", text: $comfyCheckpoint, prompt: Text("UNETLoader unet_name"))
                    TextField("Text encoder", text: $comfyTextEncoder, prompt: Text("moss_image CLIP"))
                    TextField("VAE", text: $comfyVAE, prompt: Text("flux2-vae_small"))
                    TextField("LoRAs on the server", text: $comfyLoras, prompt: Text("dmd.safetensors:1.0, name:0.8"))
                    HStack {
                        Button("Test connection") {
                            pingResult = "…"
                            let base = URL(string: comfyURL.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://127.0.0.1:8188")!
                            Task {
                                do { pingResult = try await ComfyClient(base: base, token: Keychain.read("comfy-token") ?? "").ping() }
                                catch { pingResult = "✕ " + ((error as? ComfyError)?.errorDescription ?? error.localizedDescription) }
                            }
                        }.disabled(pingResult == "…")
                        Text(pingResult).font(.caption).foregroundStyle(pingResult.hasPrefix("✕") ? .red : .secondary)
                    }
                    Text("The server needs ComfyUI 0.42+ with MOSS-Image support. Model files are named as in its models folder (see the official template for the three expected files). LoRAs must be installed on the server; names as your local library, one per adapter with an optional strength.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The model tier selector in the sidebar only applies to the local backend; remotely the checkpoint field decides. Skip-layer guidance applies; negative-branch skip layers are not offered by ComfyUI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Prompt enhancer") {
                Picker("Backend", selection: $enhancerBackend) {
                    Text("Local model (mlx-lm)").tag("local")
                    Text("Claude API").tag("claude")
                }
                if enhancerBackend == "local" {
                    TextField("MLX model", text: $localModel)
                    Text("Any mlx-community chat model. Downloaded on first use (about 2.5 GB for the default), then runs in a few seconds.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    SecureField("Anthropic API key", text: $apiKey)
                        .onChange(of: apiKey) { Keychain.write("anthropic-api-key", apiKey) }
                    TextField("Model", text: $enhancerModel)
                    Text("Stored in your login keychain. One request per click.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .sheet(isPresented: Binding(get: { reinstall != nil }, set: { if !$0 { reinstall = nil } })) {
            if let reinstall { SetupView(setup: reinstall) }
        }
    }
}

/// A path field plus a Choose… button. The field commits on Return or focus loss, not per keystroke, so the
/// Generator never creates or scans a half-typed folder.
private struct PathRow: View {
    let title: String
    @Binding var path: String
    var folder = true

    var body: some View {
        HStack {
            TextField(title, value: $path, format: Verbatim())
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.canCreateDirectories = folder
                panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
        }
    }

    /// Identity format: TextField(value:format:) only writes the binding on commit.
    struct Verbatim: ParseableFormatStyle, ParseStrategy {
        var parseStrategy: Verbatim { self }
        func format(_ value: String) -> String { value }
        func parse(_ value: String) -> String { value }
    }
}
