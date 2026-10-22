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

    var body: some View {
        content.onGeometryChange(for: Bool.self) { $0.size.width < 960 } action: { narrow = $0 }
            .background(WindowSnapshot()).background(KeyMonitor(gen: gen)).focusedSceneObject(gen)
            // Settings writes the same defaults keys. Works because Generator only reads them: an @AppStorage that
            // its object has set keeps that value and stops following outside writes.
            .onChange(of: gen.outputDir) { gen.loadHistory() }
            .onChange(of: gen.loraDir) { gen.refreshLoras() }
    }

    private var content: some View {
        NavigationSplitView {
            ControlsView(gen: gen)
                .navigationSplitViewColumnWidth(min: 300, ideal: 312, max: 420)   // 312 (+8) + the detail's 440 = the 760 minimum
                .navigationTitle("MOSS Image")
                .toolbar { ToolbarItem(placement: .principal) { Text("MOSS Image").font(.headline) } }
        } detail: {
            DetailView(gen: gen)
                .frame(minWidth: 440)
                .navigationTitle("")
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("", selection: $gen.tab) {
                    Text("Text").tag("t2i")
                    Text("Image").tag("i2i")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Text to image, or edit an image")
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
    @AppStorage("cli") var cli = NSHomeDirectory() + "/moss-mlx/bin/moss-mlx"
    @AppStorage("loraDir") var loraDir = NSHomeDirectory() + "/moss-mlx/loras"
    @AppStorage("outputDir") var outputDir = NSHomeDirectory() + "/Pictures/MOSS Image"
    @AppStorage("enhancerBackend") var enhancerBackend = "local"
    @AppStorage("enhancerModel") var enhancerModel = "claude-opus-5-5"
    @AppStorage("localModel") var localModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    @State private var apiKey = Keychain.read("anthropic-api-key") ?? ""

    var body: some View {
        Form {
            Section("Paths") {
                PathRow(title: "moss-mlx executable", path: $cli, folder: false)
                if !FileManager.default.isExecutableFile(atPath: cli) {
                    Text("No executable at this path. Run ./setup.sh from the app's folder, then choose bin/moss-mlx in the folder it installed into (~/moss-mlx by default).")
                        .font(.caption).foregroundStyle(.red)
                }
                PathRow(title: "LoRA folder", path: $loraDir)
                PathRow(title: "Output folder", path: $outputDir)
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
