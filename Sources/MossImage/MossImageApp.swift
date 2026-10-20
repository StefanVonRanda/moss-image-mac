import SwiftUI
import AppKit

@main
struct MossImageApp: App {
    var body: some Scene {
        WindowGroup("MOSS Image") {
            ContentView()
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1240, height: 820)
        Settings { SettingsView() }
    }
}

struct ContentView: View {
    @StateObject private var gen = Generator()

    var body: some View {
        content.background(WindowSnapshot())
    }

    private var content: some View {
        NavigationSplitView {
            ControlsView(gen: gen)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            DetailView(gen: gen)
                .frame(minWidth: 620)
        }
        .toolbarBackground(.visible, for: .windowToolbar)
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
                    .labelStyle(.titleAndIcon)
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
                TextField("moss-mlx executable", text: $cli)
                TextField("LoRA folder", text: $loraDir)
                TextField("Output folder", text: $outputDir)
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
