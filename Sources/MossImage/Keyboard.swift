import SwiftUI
import AppKit

extension Generator {
    /// The Text tab's result view is up (layout editor closed).
    var showsResult: Bool { tab == "t2i" && !layoutOverlay }

    /// Select the neighbouring render in the history strip: -1 is newer (left), +1 older; stops at the ends.
    func selectAdjacent(_ by: Int) {
        guard !jobs.isEmpty else { return }
        let i = selected.flatMap { jobs.firstIndex(of: $0) } ?? 0
        selected = jobs[min(max(i + by, 0), jobs.count - 1)]
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
/// ←/→ step through the history on the result view; ⌘⌫ in a text field stays "delete to line start".
/// Text fields and editors edit through an NSTextView, so `firstResponder is NSText` means typing.
struct KeyMonitor: NSViewRepresentable {
    let gen: Generator
    func makeNSView(context: Context) -> NSView { Monitor(gen: gen) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Monitor: NSView {
        let gen: Generator
        private var token: Any?
        init(gen: Generator) { self.gen = gen; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NSEvent.removeMonitor(token); self.token = nil }
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) ?? e }
        }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard let window, e.window === window else { return e }
            let responder = window.firstResponder
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
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
            default:
                return e
            }
        }
    }
}
