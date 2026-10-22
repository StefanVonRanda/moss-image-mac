import SwiftUI
import AppKit

/// MOSS-Image layout: boxes in top-left pixel coordinates while editing, compiled to the model's
/// centred yxyx form (floor left/top, ceil right/bottom, then subtract the canvas centre).
struct LayoutItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var label = "text"         // text | object | character | fill (fill: regenerate the area, no layout item is sent)
    var caption = ""
    var text = ""              // visible characters, text items only
    var x0: Double, y0: Double, x1: Double, y1: Double

    var rect: CGRect { CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)) }
    mutating func set(_ r: CGRect) { x0 = r.minX.rounded(); y0 = r.minY.rounded(); x1 = r.maxX.rounded(); y1 = r.maxY.rounded() }
    var title: String {
        switch label {
        case "text": return text.isEmpty ? "⚠︎ no visible text" : text
        case "fill": return caption.isEmpty ? "fill with background" : "fill: " + caption
        default: return caption.isEmpty ? label : caption
        }
    }
    var isFill: Bool { label == "fill" }
}

// ponytail: hand-written decode because synthesized Codable ignores the defaults above, so one box missing
// a field failed the whole stored layout. Encoding stays synthesized (same JSON as before).
extension LayoutItem {
    init(from decoder: Decoder) throws {   // coordinates are required: a box without them is dropped by MossLayout
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x0 = try c.decode(Double.self, forKey: .x0); y0 = try c.decode(Double.self, forKey: .y0)
        x1 = try c.decode(Double.self, forKey: .x1); y1 = try c.decode(Double.self, forKey: .y1)
        if let v = try? c.decode(UUID.self, forKey: .id) { id = v }
        if let v = try? c.decode(String.self, forKey: .label) { label = v }
        if let v = try? c.decode(String.self, forKey: .caption) { caption = v }
        if let v = try? c.decode(String.self, forKey: .text) { text = v }
    }
}

extension MossLayout {
    private struct Lossy: Decodable { let item: LayoutItem?; init(from decoder: Decoder) { item = try? LayoutItem(from: decoder) } }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode([String].self, forKey: .meta) { meta = v }
        if let v = try? c.decode(String.self, forKey: .canvas) { canvas = v }
        items = ((try? c.decode([Lossy].self, forKey: .items)) ?? []).compactMap(\.item)   // a malformed box drops only itself
    }
}

struct MossLayout: Codable, Equatable {
    var meta: [String] = []
    var canvas = "single"
    var items: [LayoutItem] = []

    /// Boxes that become layout items (fill boxes only shape the mask).
    var placed: [LayoutItem] { items.filter { !$0.isFill } }

    /// The model-facing prompt: compact layout JSON, or the plain caption when no box places anything.
    func compiled(caption: String, width: Int, height: Int) -> String {
        guard !placed.isEmpty else { return caption }
        let cx = Double(width) / 2, cy = Double(height) / 2
        var summary: [String: Any] = ["canvas": canvas, "caption": caption]
        if !meta.isEmpty { summary["meta"] = meta }
        let out: [String: Any] = [
            "summary": summary,
            "items": placed.map { it -> [String: Any] in
                let r = it.rect
                func x(_ v: CGFloat) -> Double { min(max(v, 0), Double(width)) }   // clamped to the canvas
                func y(_ v: CGFloat) -> Double { min(max(v, 0), Double(height)) }
                var d: [String: Any] = ["label": it.label, "caption": it.caption,
                                        "bbox": [Int(floor(y(r.minY)) - cy), Int(floor(x(r.minX)) - cx), Int(ceil(y(r.maxY)) - cy), Int(ceil(x(r.maxX)) - cx)]]
                if it.label == "text" { d["text"] = it.text }
                return d
            },
            "bbox_coord_space": "abs_centralized",
            "bbox_format": "yxyx",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse the enhancer's draft (abs xyxy, top-left, with width/height) into an editable layout.
    static func fromDraft(_ text: String) -> (layout: MossLayout, caption: String)? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let summary = obj["summary"] as? [String: Any], let caption = summary["caption"] as? String,
              let items = obj["items"] as? [[String: Any]] else { return nil }
        var layout = MossLayout(meta: summary["meta"] as? [String] ?? [], canvas: summary["canvas"] as? String ?? "single")
        for it in items {
            guard let b = it["bbox"] as? [Double], b.count == 4 else { continue }
            layout.items.append(LayoutItem(label: it["label"] as? String ?? "object", caption: it["caption"] as? String ?? "",
                                           text: it["text"] as? String ?? "", x0: b[0], y0: b[1], x1: b[2], y1: b[3]))
        }
        return layout.items.isEmpty ? nil : (layout, caption)
    }

    /// Inverse of `compiled`: the model's centred yxyx layout back to editable boxes on a `width`×`height` canvas.
    static func fromCompiled(_ text: String, width: Int, height: Int) -> (layout: MossLayout, caption: String)? {
        guard text.hasPrefix("{"), text.contains(#""bbox_format":"yxyx""#), var d = fromDraft(text) else { return nil }
        let cx = Double(width) / 2, cy = Double(height) / 2
        for i in d.layout.items.indices {   // fromDraft read [top, left, bottom, right] into x0, y0, x1, y1
            let b = d.layout.items[i]
            (d.layout.items[i].x0, d.layout.items[i].y0, d.layout.items[i].x1, d.layout.items[i].y1) = (b.y0 + cx, b.x0 + cy, b.y1 + cx, b.x1 + cy)
        }
        return d
    }
}

/// Embedded layout editor: draw, move and resize boxes over the output canvas (or the source image in
/// image-to-image), with an inspector for the selected box.
struct LayoutCanvas: View {
    @ObservedObject var gen: Generator
    let background: NSImage?
    var showMask = false             // tint the box areas that will be regenerated (image to image)
    var showInspector = true
    @State private var selected: UUID?
    @State private var drag: Drag?
    @State private var dragBefore: MossLayout?    // the layout when the gesture began: a whole drag is one undo step
    @AppStorage("inspectorHidden") private var inspectorHidden = false
    @State private var narrow = false             // no room for the inspector beside the canvas: it floats over it on demand
    @State private var inspectorFloating = false  // narrow only: the inspector toggle shows it over the canvas
    @AppStorage("layoutBlank") private var layoutBlank = true            // text to image: blank canvas unless the result is wanted behind the boxes
    @AppStorage("overlaysHidden") private var overlaysHidden = false     // eye button: show the picture without boxes or mask tint
    @State private var zoom: CGFloat = 1          // 1 = fit the view, up to 8x
    @State private var pinch: CGFloat = 1
    @State private var wheelMonitor: Any?
    @State private var panMonitor: Any?
    @State private var scrollHandle = ScrollViewHandle()
    @FocusState private var canvasFocused: Bool

    private enum Drag { case new(CGPoint, CGRect), move(UUID, CGRect, CGPoint), resize(UUID, CGRect, Corner) }
    private var shownBackground: NSImage? { (!showMask && layoutBlank) ? nil : background }
    private var overlaysOff: Bool { overlaysHidden || (showMask && gen.showsOriginal) }   // eye button, or Space held: the picture as it is
    /// Blank page: white in light mode, a light grey in dark mode so it does not glare.
    private var paper: Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.82, alpha: 1) : .white })
    }
    private enum Corner: CaseIterable { case tl, tr, bl, br }
    private let handle: CGFloat = 7

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Text(gen.layout.items.isEmpty ? "Drag on the picture to draw a box" : "\(gen.layout.items.count) " + (gen.layout.items.count == 1 ? "box" : "boxes"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    // narrow window: the hint goes first, then the text above truncates; the buttons always stay
                    ViewThatFits(in: .horizontal) {
                        Text("⌫ deletes · wheel zooms · right-drag pans" + (showMask ? " · hold Space for the original" : "")).font(.caption).foregroundStyle(.tertiary).fixedSize()
                        Text("⌫ deletes · wheel zooms" + (showMask ? " · Space: original" : "")).font(.caption).foregroundStyle(.tertiary).fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                    Spacer(minLength: 0)
                    if !showMask, background != nil {
                        Button { layoutBlank.toggle() } label: { Image(systemName: layoutBlank ? "photo" : "photo.fill") }
                            .controlSize(.small)
                            .help(layoutBlank ? "Show the last result behind the boxes" : "Blank canvas: hide the last result behind the boxes")
                    }
                    if shownBackground != nil {
                        Button { overlaysHidden.toggle() } label: { Image(systemName: overlaysHidden ? "eye.slash" : "eye") }
                            .controlSize(.small)
                            .help(overlaysHidden ? "Show boxes" : "Hide boxes and mask tint to see the picture as it is")
                    }
                    HStack(spacing: 4) {
                        Button("−") { setZoom(zoom / 1.5) }.disabled(zoom <= 1).accessibilityLabel("Zoom out")
                        Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 44)
                        Button("+") { setZoom(zoom * 1.5) }.disabled(zoom >= 8).accessibilityLabel("Zoom in")
                        Button("Fit") { setZoom(1) }.disabled(zoom == 1)
                    }
                    .controlSize(.small).fixedSize()
                    if showInspector {
                        Button { if narrow { inspectorFloating.toggle() } else { inspectorHidden.toggle() } } label: { Image(systemName: "sidebar.trailing") }
                            .controlSize(.small)
                            .padding(.leading, 12)
                            .help((narrow ? inspectorFloating : !inspectorHidden) ? "Hide the box inspector" : "Show the box inspector")
                    }
                }
                GeometryReader { geo in
                    let W = CGFloat(gen.width), H = CGFloat(gen.height)
                    let fit = min(geo.size.width / W, geo.size.height / H)
                    let scale = fit * zoom * pinch
                    let size = CGSize(width: W * scale, height: H * scale)
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        if let background = shownBackground {
                            CroppedImage(image: background).frame(width: size.width, height: size.height)
                        } else {
                            Rectangle().fill(paper)
                        }
                        if let preview = gen.preview { LivePreview(image: preview).frame(width: size.width, height: size.height) }
                        if showMask, !overlaysOff, !gen.layout.items.isEmpty {
                            MaskStrokes(strokes: gen.boxStrokes, scale: scale, color: .orange.opacity(0.3)).frame(width: size.width, height: size.height)
                        }
                        if gen.layout.items.isEmpty, drag == nil, shownBackground == nil, gen.preview == nil {
                            Text("Drag here to draw the first box")
                                .foregroundStyle(Color.black.opacity(0.35))
                                .frame(width: size.width, height: size.height)
                        }
                        if !overlaysOff { ForEach(gen.layout.items) { it in box(it, scale: scale) } }
                        if !overlaysOff, let s = selected, let it = gen.layout.items.first(where: { $0.id == s }) {
                            let r = it.rect.intersection(canvasRect)
                            Button { remove(s) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                                    .symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("Delete this box (⌫)")
                            .position(x: r.maxX * scale, y: r.minY * scale)
                        }
                        if case let .new(_, r) = drag {
                            Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .frame(width: r.width * scale, height: r.height * scale).offset(x: r.minX * scale, y: r.minY * scale)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .background(paper)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.25)))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($canvasFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.delete) { if let s = selected { remove(s); return .handled }; return .ignored }
                    .onKeyPress(.deleteForward) { if let s = selected { remove(s); return .handled }; return .ignored }
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { nudge($0) }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { g in
                            guard !overlaysOff else { return }
                            let a = CGPoint(x: g.startLocation.x / scale, y: g.startLocation.y / scale)
                            let b = CGPoint(x: g.location.x / scale, y: g.location.y / scale)
                            if drag == nil { canvasFocused = true; dragBefore = gen.layout; drag = begin(at: a, scale: scale) }
                            update(a: a, b: b)
                        }
                        .onEnded { _ in end() })
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { pinch = $0.magnification }
                        .onEnded { _ in setZoom(zoom * pinch); pinch = 1 })
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)   // centred while it fits, scrollable once it doesn't
                    .background(scrollHandle)
                    }
                    .overlay(alignment: .top) {
                        if showMask, gen.showsOriginal {
                            Text("Original").font(.caption.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule()).padding(8)
                        }
                    }
                    .onAppear { installWheelZoom(); installRightDragPan() }
                    .onDisappear {
                        if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
                        if let m = panMonitor { NSEvent.removeMonitor(m); panMonitor = nil }
                    }
                }
                .overlay(alignment: .trailing) {
                    if showInspector, narrow, inspectorFloating {
                        inspector.frame(width: 250).frame(maxHeight: .infinity)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.3), radius: 8)
                    }
                }
                Text(String(gen.width) + " × " + String(gen.height) + " px").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInspector, !inspectorHidden, !narrow {
                Divider()
                inspector.frame(width: 250)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)   // reports the column's width even while the inspector still overflows it
        // ponytail: fixed 680 pt cut-off (canvas ~400 pt beside the inspector); measure the header if that ever drifts
        .onGeometryChange(for: Bool.self) { $0.size.width < 680 } action: { narrow = $0 }
        .onDeleteCommand { if let s = selected { remove(s) } }
    }

    private func setZoom(_ z: CGFloat) { zoom = min(max(z, 1), 8) }

    /// Mouse wheel (or ⌘ + trackpad scroll) zooms; plain trackpad scrolling is left to the ScrollView for panning.
    private func installWheelZoom() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let wheel = event.phase == [] && event.momentumPhase == []
            guard wheel || event.modifierFlags.contains(.command) else { return event }
            guard let window = event.window, window.isKeyWindow, let view = window.contentView,
                  let hit = view.hitTest(view.convert(event.locationInWindow, from: nil)), hit.isDescendant(of: view),
                  gen.tab == "i2i" || gen.layoutOverlay else { return event }
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            setZoom(zoom * factor)
            return nil
        }
    }

    /// Right- or middle-button drag pans the zoomed canvas.
    private func installRightDragPan() {
        guard panMonitor == nil else { return }
        panMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDragged, .otherMouseDragged]) { event in
            guard let sv = scrollHandle.scrollView, let window = event.window, window == sv.window,
                  sv.bounds.contains(sv.convert(event.locationInWindow, from: nil)) else { return event }
            var origin = sv.contentView.bounds.origin
            origin.x -= event.deltaX
            origin.y -= event.deltaY * (sv.contentView.isFlipped ? 1 : -1)
            sv.contentView.scroll(to: origin)
            sv.reflectScrolledClipView(sv.contentView)
            return nil
        }
    }

    private func tint(_ label: String) -> Color {
        switch label { case "text": return .accentColor; case "character": return .orange; case "fill": return .pink; default: return .teal }
    }
    private func chip(_ label: String) -> String {
        switch label { case "text": return "T"; case "character": return "C"; case "fill": return "F"; default: return "O" }
    }

    private func box(_ it: LayoutItem, scale: CGFloat) -> some View {
        let r = it.rect.intersection(canvasRect)
        let isSel = it.id == selected
        let tint = tint(it.label)
        let w = max(r.width * scale, 1), h = max(r.height * scale, 1)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(tint.opacity(isSel ? 0.16 : 0.08))
            Rectangle().stroke(Color.black.opacity(0.5), lineWidth: isSel ? 5 : 3)   // halo so the box reads over photos
            Rectangle().stroke(tint, lineWidth: isSel ? 3 : 1.5)
            // a preview of what the box asks for: the visible text, or the caption in small grey
            Group {
                if it.label == "text" {
                    Text(it.text.isEmpty ? "text" : it.text)
                        .font(.system(size: h * 0.55, weight: .semibold))
                        .minimumScaleFactor(0.05).lineLimit(it.text.filter { $0 == "\n" }.count + 1)
                        .foregroundStyle(it.text.isEmpty ? Color.black.opacity(0.35) : (shownBackground == nil ? Color.black : Color.primary))
                        .shadow(color: shownBackground == nil ? .clear : Color(nsColor: .windowBackgroundColor), radius: 2)
                } else {
                    Text(it.isFill ? (it.caption.isEmpty ? "fill with background" : it.caption) : (it.caption.isEmpty ? it.label : it.caption))
                        .font(.caption).multilineTextAlignment(.center).lineLimit(4)
                        .foregroundStyle(shownBackground == nil ? Color.black.opacity(0.7) : Color.primary)
                        .padding(4).background(shownBackground == nil ? Color.white.opacity(0.7) : Color(nsColor: .windowBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(6)
            .frame(width: w, height: h)
            // kind chip
            Text(chip(it.label))
                .font(.caption2.bold()).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(tint, in: RoundedRectangle(cornerRadius: 3))
                .offset(x: 3, y: 3)
            if isSel {
                ForEach(Corner.allCases, id: \.self) { c in
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: handle + 1, height: handle + 1)
                        .position(cornerPoint(c, CGRect(x: 0, y: 0, width: w, height: h)))
                }
            }
        }
        .frame(width: w, height: h)
        .offset(x: r.minX * scale, y: r.minY * scale)
        .allowsHitTesting(false)
    }

    private func cornerPoint(_ c: Corner, _ r: CGRect) -> CGPoint {
        switch c {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func begin(at p: CGPoint, scale: CGFloat) -> Drag {
        let items = gen.layout.items
        if let s = selected, let it = items.first(where: { $0.id == s }) {
            let grab = (handle + 4) / scale
            for c in Corner.allCases {
                let cp = cornerPoint(c, it.rect)
                if abs(cp.x - p.x) <= grab && abs(cp.y - p.y) <= grab { return .resize(s, it.rect, c) }
            }
        }
        if let it = items.last(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) {
            selected = it.id
            return .move(it.id, it.rect, p)
        }
        selected = nil
        return .new(p, CGRect(origin: p, size: .zero))
    }

    private var canvasRect: CGRect { CGRect(x: 0, y: 0, width: gen.width, height: gen.height) }

    private func update(a: CGPoint, b: CGPoint) {
        guard let d = drag else { return }
        switch d {
        case .new:
            drag = .new(a, CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(canvasRect))
        case let .move(id, r0, p0):
            var r = r0.offsetBy(dx: b.x - p0.x, dy: b.y - p0.y)
            r.origin.x = min(max(0, r.origin.x), CGFloat(gen.width) - r.width)
            r.origin.y = min(max(0, r.origin.y), CGFloat(gen.height) - r.height)
            setRect(id, r)
        case let .resize(id, r0, c):
            var x0 = r0.minX, y0 = r0.minY, x1 = r0.maxX, y1 = r0.maxY
            switch c {
            case .tl: x0 = b.x; y0 = b.y
            case .tr: x1 = b.x; y0 = b.y
            case .bl: x0 = b.x; y1 = b.y
            case .br: x1 = b.x; y1 = b.y
            }
            setRect(id, CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)).intersection(canvasRect))
        }
    }

    private func setRect(_ id: UUID, _ r: CGRect) { var it = gen.item(id).wrappedValue; it.set(r); gen.item(id).wrappedValue = it }

    private func end() {
        if case let .new(_, r) = drag, r.width > 8, r.height > 8 {
            var it = LayoutItem(x0: 0, y0: 0, x1: 0, y1: 0); it.set(r)
            var l = gen.layout; l.items.append(it); gen.layout = l
            selected = it.id
            if gen.usingSource, gen.strength < 1 { gen.strength = 1 }  // a box in image-to-image means "replace what is inside it"
        }
        drag = nil
        if let b = dragBefore { gen.recordUndo(b) }; dragBefore = nil
    }

    private func remove(_ id: UUID) { let before = gen.layout; var l = before; l.items.removeAll { $0.id == id }; gen.layout = l; gen.recordUndo(before); selected = nil }

    /// Arrow keys move the selected box 1 px (⇧ 10 px), clamped to the canvas; a run of nudges is one undo step.
    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard let s = selected, let it = gen.layout.items.first(where: { $0.id == s }) else { return .ignored }
        let d: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        var r = it.rect
        switch press.key {
        case .leftArrow: r.origin.x -= d
        case .rightArrow: r.origin.x += d
        case .upArrow: r.origin.y -= d
        default: r.origin.y += d
        }
        r.origin.x = min(max(0, r.origin.x), CGFloat(gen.width) - r.width)
        r.origin.y = min(max(0, r.origin.y), CGFloat(gen.height) - r.height)
        let before = gen.layout; setRect(s, r); gen.recordUndo(before, coalesce: "nudge" + s.uuidString)
        return .handled
    }

    /// An inspector binding that records undo; typing in one field coalesces into one step via `key`.
    private func tracked<T>(_ b: Binding<T>, _ key: String? = nil) -> Binding<T> {
        Binding(get: { b.wrappedValue }, set: { v in let before = gen.layout; b.wrappedValue = v; gen.recordUndo(before, coalesce: key) })
    }

    private var inspector: some View {
        Form {
            Section("Boxes") {
                if gen.layout.items.isEmpty {
                    Text("None yet. Draw one, or press Enhance.").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(gen.layout.items) { it in
                    HStack(spacing: 8) {
                        Text(chip(it.label))
                            .font(.caption2.bold()).foregroundStyle(.white).frame(width: 16, height: 16)
                            .background(tint(it.label), in: RoundedRectangle(cornerRadius: 3))
                        Text(it.title).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = it.id }
                    .contextMenu { Button("Delete box", role: .destructive) { remove(it.id) } }
                    .listRowBackground(it.id == selected ? Color.accentColor.opacity(0.15) : nil)
                }
            }
            if let s = selected, gen.layout.items.contains(where: { $0.id == s }) {
                let b = gen.item(s), k = s.uuidString
                Section("Selected box") {
                    if b.wrappedValue.rect.height < 40 || b.wrappedValue.rect.width < 40 {
                        Text("Only \(Int(b.wrappedValue.rect.width)) × \(Int(b.wrappedValue.rect.height)) px at the output size: too small to render. Raise Pixels in the sidebar or enlarge the box.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Picker("Kind", selection: tracked(b.label)) {
                        Text("Text").tag("text"); Text("Object").tag("object"); Text("Character").tag("character")
                        if gen.usingSource { Divider(); Text("Fill (regenerate only)").tag("fill") }
                    }
                    if b.wrappedValue.label == "fill" {
                        Text("The area is regenerated to match its surroundings. No layout item is sent. Describe what should appear only if it is not plain background.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if b.wrappedValue.label == "text" {
                        TextField("Visible text", text: tracked(b.text, "text" + k), prompt: Text("the exact words to render"), axis: .vertical).lineLimit(1...4)
                        if b.wrappedValue.text.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Required: these are the characters the model will draw. The caption below only describes their look.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    TextField(b.wrappedValue.isFill ? "Should show" : "Caption", text: tracked(b.caption, "caption" + k),
                              prompt: Text(b.wrappedValue.isFill ? "empty = plain background" : (b.wrappedValue.label == "text" ? "font, colour, weight, surface" : "what it looks like")), axis: .vertical).lineLimit(2...6)
                    LabeledContent("Position") {
                        HStack(spacing: 4) {
                            TextField("x", value: tracked(b.x0, "x0" + k), format: .number.grouping(.never)); TextField("y", value: tracked(b.y0, "y0" + k), format: .number.grouping(.never))
                        }
                    }
                    LabeledContent("Corner") {
                        HStack(spacing: 4) {
                            TextField("x", value: tracked(b.x1, "x1" + k), format: .number.grouping(.never)); TextField("y", value: tracked(b.y1, "y1" + k), format: .number.grouping(.never))
                        }
                    }
                    HStack {
                        Button("Duplicate") {
                            var copy = b.wrappedValue; copy.id = UUID(); copy.set(copy.rect.offsetBy(dx: 24, dy: 24).intersection(canvasRect))
                            let before = gen.layout; var l = before; l.items.append(copy); gen.layout = l; gen.recordUndo(before); selected = copy.id
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { remove(s) }
                    }
                }
            }
            Section("Scene") {
                TextField("Meta", text: tracked(Binding(
                    get: { gen.layout.meta.joined(separator: ", ") },
                    set: { v in var l = gen.layout; l.meta = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; gen.layout = l }), "meta"),
                    prompt: Text("poster, infographic…"))
                Picker("Canvas", selection: tracked(Binding(get: { gen.layout.canvas }, set: { v in var l = gen.layout; l.canvas = v; gen.layout = l }))) {
                    Text("Single").tag("single"); Text("Multi panel").tag("multi_panel"); Text("Collage").tag("collage")
                }
                Text("The prompt field is the summary caption.").font(.caption).foregroundStyle(.secondary)

                Button("Clear all boxes", role: .destructive) { let before = gen.layout; var l = before; l.items = []; gen.layout = l; gen.recordUndo(before); selected = nil }
                    .disabled(gen.layout.items.isEmpty)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }
}

/// Finds the NSScrollView that SwiftUI created for the surrounding ScrollView, so events can pan it.
struct ScrollViewHandle: NSViewRepresentable {
    final class Box { weak var view: NSScrollView? }
    private let box = Box()
    var scrollView: NSScrollView? { box.view }

    func makeNSView(context: Context) -> NSView { Finder(box: box) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        let box: Box
        init(box: Box) { self.box = box; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var v = superview
            while let view = v, !(view is NSScrollView) { v = view.superview }
            box.view = v as? NSScrollView
        }
    }
}
