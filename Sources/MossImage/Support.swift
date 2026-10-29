import SwiftUI
import AppKit

/// Puts the app name and a sidebar toggle in the titlebar next to the traffic lights. macOS 27 no
/// longer draws the sidebar's navigation title there (it drops it entirely), so add the header
/// explicitly and size it to the sidebar, as macOS 14–26 did.
struct TitlebarTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []
        private weak var host: NSView?
        private var labelWidth: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.window === window else { return }
                self.install(on: window)
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        private func install(on window: NSWindow) {
            guard #available(macOS 27, *) else { return }  // earlier systems draw the sidebar header themselves
            let id = NSUserInterfaceItemIdentifier("moss-titlebar-title")
            guard !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == id }) else { return }

            let label = NSTextField(labelWithString: "MOSS Image")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .labelColor
            label.sizeToFit()
            labelWidth = label.frame.width

            let host = NSView(frame: NSRect(x: 0, y: 0, width: labelWidth + 34, height: 52))
            host.identifier = id
            label.frame.origin = NSPoint(x: 27, y: 17)
            host.addSubview(label)

            let toggle = NSButton(image: NSImage(systemSymbolName: "sidebar.left",
                                                 accessibilityDescription: "Toggle Sidebar")!,
                                  target: self, action: #selector(toggleSidebar(_:)))
            toggle.isBordered = false
            toggle.imagePosition = .imageOnly
            toggle.contentTintColor = .secondaryLabelColor
            toggle.focusRingType = .none
            toggle.toolTip = "Toggle Sidebar"
            toggle.setAccessibilityLabel("Toggle Sidebar")
            toggle.frame = NSRect(x: host.frame.width - 34, y: 14, width: 24, height: 24)
            toggle.autoresizingMask = [.minXMargin]
            host.addSubview(toggle)

            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = host
            accessory.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(accessory)
            self.host = host

            fit(host, in: window)
            // The system's sidebar toggle ends up underneath the header (and in the toolbar's overflow).
            // A SwiftUI `.toolbar(removing:)` shrinks the sidebar here, so remove the item directly.
            for delay in [0.4, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window else { return }
                    Self.removeSystemToggle(from: window)
                }
            }
            let center = NotificationCenter.default
            if let split = Self.splitView(in: window.contentView) {
                observers.append(center.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                                    object: split, queue: .main) { [weak self] _ in
                    guard let self, let host = self.host else { return }
                    self.fit(host, in: window)
                    DispatchQueue.main.async { Self.removeSystemToggle(from: window) }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                                object: window, queue: .main) { [weak self] _ in
                guard let self, let host = self.host else { return }
                self.fit(host, in: window)
                DispatchQueue.main.async { Self.removeSystemToggle(from: window) }
            })
        }

        /// Widen the header up to the sidebar's trailing edge. A fixed width cannot work: the
        /// sidebar is resizable, and the toggle must stay at its edge.
        private func fit(_ host: NSView, in window: NSWindow) {
            guard let split = Self.splitView(in: window.contentView),
                  let sidebar = split.arrangedSubviews.first else { return }
            let minX = host.convert(CGRect.zero, to: nil).minX
            let width = max(labelWidth + 72, sidebar.frame.width - minX - 8)
            if abs(host.frame.width - width) > 0.5 { host.frame.size.width = width }
        }

        private static func removeSystemToggle(from window: NSWindow) {
            guard let toolbar = window.toolbar,
                  let index = toolbar.items.firstIndex(where: {
                      $0.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
                  }) else { return }
            toolbar.removeItem(at: index)
        }

        @objc private func toggleSidebar(_ sender: Any?) {
            let action = #selector(NSSplitViewController.toggleSidebar(_:))
            if window?.firstResponder?.tryToPerform(action, with: nil) != true {
                NSApp.sendAction(action, to: nil, from: sender)
            }
        }

        private static func splitView(in root: NSView?) -> NSSplitView? {
            guard let root else { return nil }
            if let split = root as? NSSplitView { return split }
            for view in root.subviews {
                if let split = splitView(in: view) { return split }
            }
            return nil
        }
    }
}

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

/// Switches the scroll views of the view it backs (a Form and the text editors in it) to thin, auto-hiding
/// overlay scrollers, also when System Settings shows scroll bars always or a mouse is connected.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // AppKit puts the system style back when the preference changes (with "Automatic": once it sees a mouse)
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(apply), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            apply()
        }

        @objc func apply() {
            DispatchQueue.main.async { [weak self] in   // after AppKit's own handling of the notification
                // a .background sits beside the Form's scroll view, not inside it: climb to the first ancestor that has one
                var v = self?.superview
                while let view = v, Self.scrollViews(in: view).isEmpty { v = view.superview }
                // ponytail: a text editor created after this (box edit toggled) keeps the system style until the next apply
                for sv in v.map(Self.scrollViews) ?? [] {
                    sv.scrollerStyle = .overlay
                    sv.autohidesScrollers = true
                    sv.verticalScroller?.controlSize = .small
                }
            }
        }

        static func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { (($0 as? NSScrollView).map { [$0] } ?? []) + scrollViews(in: $0) }
        }
    }
}

/// Keeps the sidebar's scrollable content below the window's real header: the titlebar and, when the window is
/// tabbed, the tab bar. SwiftUI insets the sidebar form by the titlebar height only, so a tab bar leaves the top
/// 36 pt of the form scrolling under it (the section header and the first row get clipped).
struct SidebarHeaderInset: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Finder)?.update() }

    final class Finder: NSView {
        private var timer: Timer?
        private var cover: NSView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            timer?.invalidate(); timer = nil
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(update), name: name, object: window)
            }
            // Showing or hiding a tab bar changes contentLayoutRect without a window resize. Polling is cheap here:
            // the comparison below only touches the scroll view when the inset really changed.
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            update()
        }

        override func removeFromSuperview() {
            timer?.invalidate(); timer = nil
            super.removeFromSuperview()
        }

        deinit { timer?.invalidate() }

        @objc func update() {
            DispatchQueue.main.async { [weak self] in   // after AppKit has laid out the new header height
                guard let self, let window = self.window, window.contentLayoutRect.height > 0 else { return }
                // a .background sits beside the Form's scroll view, not inside it: climb to the first ancestor that has one
                var v = self.superview
                while let view = v, Self.scrollViews(in: view).isEmpty { v = view.superview }
                guard let scroll = v.map(Self.scrollViews)?.first else { return }
                let top = scroll.convert(scroll.bounds, to: nil).maxY   // window coordinates
                let inset = min(max(0, top - window.contentLayoutRect.maxY), scroll.bounds.height)
                if scroll.contentInsets.top != inset {
                    scroll.contentInsets.top = inset
                    scroll.scrollerInsets.top = inset
                }
                // The inset shifts the document, but AppKit still draws scrolled rows under a translucent header.
                // A fixed cover over the scroll view hides them and leaves the content below the real header.
                if inset > 0 {
                    let cover = self.cover ?? HeaderCover()
                    self.cover = cover
                    // Keep it topmost: AppKit can add its own header views after a layout pass.
                    if cover.superview !== scroll || scroll.subviews.last !== cover {
                        scroll.addSubview(cover, positioned: .above, relativeTo: nil)
                    }
                    cover.isHidden = false
                    cover.frame = NSRect(x: 0, y: scroll.isFlipped ? 0 : scroll.bounds.height - inset,
                                         width: scroll.bounds.width, height: inset)
                } else {
                    self.cover?.isHidden = true
                }
            }
        }

        static func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { (($0 as? NSScrollView).map { [$0] } ?? []) + scrollViews(in: $0) }
        }
    }
}

/// The fixed strip over the top of the sidebar's scroll view: the window's header material, never a hit target.
private final class HeaderCover: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        autoresizingMask = [.width, .minYMargin]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Decoded images by path for view bodies, reloaded when the file's modification date changes.
enum ImageCache {
    final class Entry { let image: NSImage, date: Date; init(_ i: NSImage, _ d: Date) { image = i; date = d } }
    static let cache: NSCache<NSString, Entry> = { let c = NSCache<NSString, Entry>(); c.totalCostLimit = 512 << 20; return c }()   // not private: the checks count its evictions

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

/// Where the engine lives. The `cli` setting wins when it points at an executable: a setup.sh install
/// (`~/moss-mlx`, the setting's default) or any other, with loras/ and adapters/ beside its bin/. Otherwise the app's
/// own install in Application Support: engine/ (the venv), loras/, adapters/.
struct EngineHome {
    let cli: String    // the moss-mlx executable; the venv's python sits beside it
    let root: String

    var python: String { (cli as NSString).deletingLastPathComponent + "/python" }
    var loras: String { root + "/loras" }
    var adapters: String { root + "/adapters" }

    /// The `cli` setting's default: where setup.sh installs.
    static func setupCLI(home: String = NSHomeDirectory()) -> String { home + "/moss-mlx/bin/moss-mlx" }
    static func appSupport(home: String = NSHomeDirectory()) -> String { home + "/Library/Application Support/MOSS Image" }

    init(cli setting: String, home: String = NSHomeDirectory()) {
        // The release app's engine lives at <root>/engine/bin/moss-mlx, while a setup.sh install uses
        // <root>/bin/moss-mlx. Settings shows the resolved path, and can store it; both layouts must
        // resolve to the same root, or LoRAs and adapters point inside engine/ and come up empty.
        let support = Self.appSupport(home: home), supportCLI = support + "/engine/bin/moss-mlx"
        if setting == supportCLI {
            cli = setting; root = support
        } else if FileManager.default.isExecutableFile(atPath: setting) {
            cli = setting; root = ((setting as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        } else {
            root = support; cli = supportCLI
        }
    }

    /// From the stored `cli` setting, as Generator and Settings read it.
    static var current: EngineHome { EngineHome(cli: UserDefaults.standard.string(forKey: "cli") ?? setupCLI()) }
}
