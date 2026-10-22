import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Generator {
    /// The Text tab's result view is up (layout editor closed).
    var showsResult: Bool { tab == "t2i" && !layoutOverlay }

    /// Select the neighbouring render in the history strip: -1 is newer (left), +1 older; stops at the ends.
    func selectAdjacent(_ by: Int) {
        guard !jobs.isEmpty else { return }
        let i = selected.flatMap { jobs.firstIndex(of: $0) } ?? 0
        selected = jobs[min(max(i + by, 0), jobs.count - 1)]
    }

    /// Image tab, and edits have replaced the working image: there is an original to compare against.
    var canCompare: Bool { tab == "i2i" && !initImage.isEmpty && !originalSource.isEmpty && originalSource != initImage }
    /// Space is held over something to compare: the canvas shows the original, without boxes or mask tint.
    var showsOriginal: Bool { comparing && canCompare }
    /// The picture behind the image tab's canvas.
    var canvasSource: String { showsOriginal ? originalSource : initImage }

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
    }

    /// The pasteboard's image as a path for setSource: an image file as is; bitmap data (screenshot, browser copy)
    /// written as PNG to <outputDir>/sources/, kept because initImage stores the path. Nil for anything else.
    func pastedImagePath(from pb: NSPasteboard) -> String? {
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            return Self.isImage(url) ? url.path : nil   // a copied non-image file also carries its icon: not that
        }
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let dir = URL(fileURLWithPath: outputDir).appendingPathComponent("sources")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return url.path
    }

    /// Start an image edit from this file.
    func startEdit(_ path: String) { setSource(path); tab = "i2i" }
}

extension View {
    /// An image file dropped here starts an image edit.
    func dropToEdit(_ gen: Generator) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            providers.first?.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), Generator.isImage(url) else { return }
                Task { @MainActor in gen.startEdit(url.path) }
            }
            return true
        }
    }
}

/// Image menu: ⌘⌫ moves the shown result to the Trash.
struct ImageCommands: Commands {
    @FocusedObject var gen: Generator?

    var body: some Commands {
        CommandMenu("Image") {
            Button("Move to Trash") { if let gen, let job = gen.selected { gen.trash(job) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(gen?.showsResult != true || gen?.selected == nil)
        }
    }
}

/// Window-wide keys that must not reach the image while text is being edited:
/// ←/→ step through the history on the result view; ⌘⌫ in a text field stays "delete to line start";
/// ⌘V with an image on the pasteboard starts an image edit. Text paste is untouched: it is never consumed while typing.
/// Holding Space in the Image tab shows the original on the canvas until it is let go.
/// Text fields and editors edit through an NSTextView, so `firstResponder is NSText` means typing.
struct KeyMonitor: NSViewRepresentable {
    let gen: Generator
    func makeNSView(context: Context) -> NSView { Monitor(gen: gen) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Monitor: NSView {
        let gen: Generator
        private var token: Any?
        private var resignToken: Any?
        init(gen: Generator) { self.gen = gen; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NSEvent.removeMonitor(token); self.token = nil }
            if let resignToken { NotificationCenter.default.removeObserver(resignToken); self.resignToken = nil }
            guard let window else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in self?.handle(e) ?? e }
            // Space let go after switching apps never sends its keyUp here
            resignToken = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gen.comparing = false }
            }
        }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard let window, e.window === window else { return e }
            let responder = window.firstResponder
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.charactersIgnoringModifiers == " " {
                if gen.comparing { if e.type == .keyUp { gen.comparing = false }; return nil }   // repeats swallowed while held
                // typing a space, or pressing a focused button, stays what it is
                guard e.type == .keyDown, mods.isEmpty, gen.canCompare, !(responder is NSText), !(responder is NSControl) else { return e }
                gen.comparing = true
                return nil
            }
            guard e.type == .keyDown else { return e }
            switch (e.specialKey, mods) {
            case (.leftArrow?, []), (.rightArrow?, []):
                // sliders, lists and other controls keep their arrows
                guard gen.showsResult, !(responder is NSText), !(responder is NSControl) else { return e }
                gen.selectAdjacent(e.specialKey == .leftArrow ? -1 : 1)
                return nil
            case (.delete?, [.command]):
                // the Image menu's ⌘⌫ would otherwise win over the text view's own binding
                guard let text = responder as? NSTextView else { return e }
                text.keyDown(with: e)
                return nil
            case (nil, [.command]) where e.charactersIgnoringModifiers?.lowercased() == "v":
                guard !(responder is NSText), let path = gen.pastedImagePath(from: .general) else { return e }
                gen.startEdit(path)
                return nil
            default:
                return e
            }
        }
    }
}

/// Help ▸ Keyboard Shortcuts (⌘/).
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: ShortcutsView.id) }.keyboardShortcut("/")
        }
    }
}

/// Every key and gesture the app handles, grouped by where it applies. Keep in step with KeyMonitor, the menus,
/// ImageScrollView and LayoutCanvas.
struct ShortcutsView: View {
    static let id = "shortcuts"
    static let groups: [(String, [(String, String)])] = [
        ("Generate", [
            ("Generate, or queue another while rendering", "⌘↩"),
        ]),
        ("Results", [
            ("Newer / older result", "← →"),
            ("Move to Trash", "⌘⌫"),
            ("Settings of the selected image", "⌘I"),
            ("Zoom at the pointer", "Scroll wheel, ⌘-scroll, pinch"),
            ("Pan", "Drag"),
            ("Drag the file to Finder or another app", "⌥-drag"),
            ("Fit / 2×", "Double-click"),
            ("Drag the image out as a file", "Drag a thumbnail"),
        ]),
        ("Layout editor", [
            ("Draw a box", "Drag on the canvas"),
            ("Move / resize a box", "Drag it / its corner"),
            ("Nudge the selected box 1 px", "← → ↑ ↓"),
            ("Nudge 10 px", "⇧ ← → ↑ ↓"),
            ("Delete the selected box", "⌫ or ⌦"),
            ("Undo / redo a box edit", "⌘Z  ⇧⌘Z"),
        ]),
        ("Image edits", [
            ("Edit the image on the pasteboard", "⌘V"),
            ("Edit an image file", "Drop it on the window"),
            ("Show the original", "Hold Space"),
        ]),
        ("Canvas", [
            ("Zoom", "Scroll wheel, ⌘-scroll, pinch"),
            ("Pan when zoomed", "Right- or middle-drag"),
        ]),
    ]

    var body: some View {
        // ponytail: no scroll view, the window takes the list's size (~600 pt); add one if the list outgrows small screens
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Self.groups, id: \.0) { group in
                GridRow {
                    Text(group.0).font(.headline).padding(.top, group.0 == Self.groups[0].0 ? 0 : 12).gridCellColumns(2)
                }
                ForEach(group.1, id: \.0) { row in
                    GridRow {
                        Text(row.1).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.0)
                    }
                }
            }
        }
        .padding(24)
        .fixedSize()
    }
}
