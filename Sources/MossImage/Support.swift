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

/// Decoded images by path for view bodies, reloaded when the file's modification date changes.
enum ImageCache {
    private final class Entry { let image: NSImage, date: Date; init(_ i: NSImage, _ d: Date) { image = i; date = d } }
    private static let cache: NSCache<NSString, Entry> = { let c = NSCache<NSString, Entry>(); c.totalCostLimit = 512 << 20; return c }()

    /// Full-size image (canvas backgrounds).
    static func image(_ path: String) -> NSImage? { load(path, thumbnail: 0) }
    /// Short side at least `pixels` (72 pt at 2x by default), for aspect-fill thumbnails.
    static func thumbnail(_ path: String, pixels: Int = 144) -> NSImage? { load(path, thumbnail: pixels) }

    // ponytail: one stat per call to catch rewrites; fine for ~80 thumbnails per body
    private static func load(_ path: String, thumbnail px: Int) -> NSImage? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        let key = "\(px):\(path)" as NSString
        if let e = cache.object(forKey: key), e.date == date { return e.image }
        let image: NSImage, pixels: Int
        if px > 0 {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = p?[kCGImagePropertyPixelWidth] as? Int ?? px, h = p?[kCGImagePropertyPixelHeight] as? Int ?? px
            let side = px * max(w, h) / max(1, min(w, h))   // long side that gives the short side `px`
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary) else { return nil }
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)); pixels = cg.width * cg.height
        } else {
            guard let img = NSImage(contentsOfFile: path), let rep = img.representations.first else { return nil }
            image = img; pixels = rep.pixelsWide * rep.pixelsHigh
        }
        cache.setObject(Entry(image, date), forKey: key, cost: pixels * 4)
        return image
    }
}
