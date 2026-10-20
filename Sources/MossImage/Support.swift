import SwiftUI
import AppKit

/// With MOSS_SCREENSHOT=<png path> in the environment, captures the window 2 s after launch and quits.
struct WindowSnapshot: NSViewRepresentable {
    /// Writing a PNG path into this file makes the running app capture its window there (used by tests/docs).
    static let requestFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moss-image-snapshot-request")

    static func capture(_ window: NSWindow, to path: String) {
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]) else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard let path = try? String(contentsOf: Self.requestFile, encoding: .utf8), let window = v.window else { return }
            try? FileManager.default.removeItem(at: Self.requestFile)
            Self.capture(window, to: path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let path = ProcessInfo.processInfo.environment["MOSS_SCREENSHOT"] else { return v }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            defer { NSApp.terminate(nil) }
            if let window = v.window { Self.capture(window, to: path) }
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
