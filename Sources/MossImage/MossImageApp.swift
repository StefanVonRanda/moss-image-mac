import SwiftUI
import AppKit

@main
struct MossImageApp: App {
    var body: some Scene {
        WindowGroup("MOSS Image") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
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
            PreviewView(gen: gen)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    if gen.running { Button("Cancel", action: gen.cancel) }
                    Button(gen.running ? "Queue" : "Generate", action: gen.generate)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("⌘↩ · while a render runs, queues another with the current settings")
                }
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("cli") var cli = NSHomeDirectory() + "/moss-mlx/bin/moss-mlx"
    @AppStorage("loraDir") var loraDir = NSHomeDirectory() + "/moss-mlx/loras"
    @AppStorage("outputDir") var outputDir = NSHomeDirectory() + "/Pictures/MOSS Image"
    @AppStorage("enhancerModel") var enhancerModel = "claude-opus-5-5"
    @State private var apiKey = Keychain.read("anthropic-api-key") ?? ""

    var body: some View {
        Form {
            Section("Paths") {
                TextField("moss-mlx executable", text: $cli)
                TextField("LoRA folder", text: $loraDir)
                TextField("Output folder", text: $outputDir)
            }
            Section {
                SecureField("Anthropic API key", text: $apiKey)
                    .onChange(of: apiKey) { Keychain.write("anthropic-api-key", apiKey) }
                TextField("Model", text: $enhancerModel)
            } header: { Text("Prompt enhancer") } footer: {
                Text("Stored in your login keychain. Used only by the Enhance button, one request per click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}

/// With MOSS_SCREENSHOT=<png path> in the environment, captures the window 2 s after launch and quits.
struct WindowSnapshot: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        guard let path = ProcessInfo.processInfo.environment["MOSS_SCREENSHOT"] else { return v }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            defer { NSApp.terminate(nil) }
            guard let window = v.window,
                  let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]) else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Finds the enclosing NSScrollView and switches it to thin, auto-hiding overlay scrollers.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                var v = self?.superview
                while let view = v, !(view is NSScrollView) { v = view.superview }
                guard let sv = v as? NSScrollView else { return }
                sv.scrollerStyle = .overlay
                sv.autohidesScrollers = true
                sv.verticalScroller?.controlSize = .small
            }
        }
    }
}
