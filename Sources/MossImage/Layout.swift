import SwiftUI
import AppKit

/// MOSS-Image layout: boxes in top-left pixel coordinates while editing, compiled to the model's
/// centred yxyx form (floor left/top, ceil right/bottom, then subtract the canvas centre).
struct LayoutItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var label = "object"       // object | character | text
    var caption = ""
    var text = ""              // visible characters, text items only
    var x0: Double, y0: Double, x1: Double, y1: Double

    var rect: CGRect { CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)) }
    mutating func set(_ r: CGRect) { x0 = r.minX.rounded(); y0 = r.minY.rounded(); x1 = r.maxX.rounded(); y1 = r.maxY.rounded() }
    var title: String { label == "text" && !text.isEmpty ? text : (caption.isEmpty ? label : caption) }
}

struct MossLayout: Codable, Equatable {
    var meta: [String] = []
    var canvas = "single"
    var items: [LayoutItem] = []

    func compiled(caption: String, width: Int, height: Int) -> String {
        let cx = Double(width) / 2, cy = Double(height) / 2
        var summary: [String: Any] = ["canvas": canvas, "caption": caption]
        if !meta.isEmpty { summary["meta"] = meta }
        let out: [String: Any] = [
            "summary": summary,
            "items": items.map { it -> [String: Any] in
                let r = it.rect
                var d: [String: Any] = ["label": it.label, "caption": it.caption,
                                        "bbox": [Int(floor(r.minY) - cy), Int(floor(r.minX) - cx), Int(ceil(r.maxY) - cy), Int(ceil(r.maxX) - cx)]]
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
}

/// Embedded layout editor: draw, move and resize boxes over the output canvas (or the source image in
/// image-to-image), with an inspector for the selected box.
struct LayoutCanvas: View {
    @ObservedObject var gen: Generator
    let background: NSImage?
    @State private var selected: UUID?
    @State private var drag: Drag?

    private enum Drag { case new(CGPoint, CGRect), move(UUID, CGRect, CGPoint), resize(UUID, CGRect, Corner) }
    private enum Corner: CaseIterable { case tl, tr, bl, br }
    private let handle: CGFloat = 7

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Toggle("Send boxes with the prompt", isOn: $gen.layoutMode).toggleStyle(.checkbox)
                    Spacer()
                    Text("Drag on empty space to draw. Drag a box to move, its corners to resize. ⌫ deletes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    let W = CGFloat(gen.width), H = CGFloat(gen.height)
                    let scale = min(geo.size.width / W, geo.size.height / H)
                    let size = CGSize(width: W * scale, height: H * scale)
                    ZStack(alignment: .topLeading) {
                        if let background {
                            CroppedImage(image: background).frame(width: size.width, height: size.height).opacity(0.85)
                        } else {
                            Rectangle().fill(Color(nsColor: .textBackgroundColor))
                        }
                        Rectangle().stroke(Color(nsColor: .separatorColor))
                        ForEach(gen.layout.items) { it in box(it, scale: scale) }
                        if case let .new(_, r) = drag {
                            Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .frame(width: r.width * scale, height: r.height * scale).offset(x: r.minX * scale, y: r.minY * scale)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { g in
                            let a = CGPoint(x: g.startLocation.x / scale, y: g.startLocation.y / scale)
                            let b = CGPoint(x: g.location.x / scale, y: g.location.y / scale)
                            if drag == nil { drag = begin(at: a, scale: scale) }
                            update(a: a, b: b)
                        }
                        .onEnded { _ in end() })
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .padding(16)
            Divider()
            inspector.frame(width: 280).padding(16)
        }
        .onDeleteCommand { if let s = selected { remove(s) } }
    }

    private func box(_ it: LayoutItem, scale: CGFloat) -> some View {
        let r = it.rect
        let isSel = it.id == selected
        let tint: Color = it.label == "text" ? .accentColor : (it.label == "character" ? .orange : .secondary)
        let local = CGRect(origin: .zero, size: CGSize(width: r.width * scale, height: r.height * scale))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(tint.opacity(isSel ? 0.16 : 0.08))
            Rectangle().stroke(isSel ? Color.accentColor : tint, lineWidth: isSel ? 2 : 1)
            Text(it.title).font(.caption).lineLimit(3).padding(3)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
            if isSel {
                ForEach(Corner.allCases, id: \.self) { c in
                    Rectangle().fill(Color.accentColor).frame(width: handle, height: handle)
                        .position(cornerPoint(c, local))
                }
            }
        }
        .frame(width: r.width * scale, height: r.height * scale)
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
            if !gen.layoutMode { gen.layoutMode = true }
        }
        drag = nil
    }

    private func remove(_ id: UUID) { var l = gen.layout; l.items.removeAll { $0.id == id }; gen.layout = l; selected = nil }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Boxes").font(.headline)
            if gen.layout.items.isEmpty {
                Text("None yet. Draw one, or tick Layout in the sidebar and press Enhance to let a model draft them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(gen.layout.items) { it in
                        HStack {
                            Circle().fill(it.label == "text" ? Color.accentColor : (it.label == "character" ? .orange : .secondary)).frame(width: 7, height: 7)
                            Text(it.title).lineLimit(1).font(.callout)
                            Spacer()
                        }
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .background(it.id == selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { selected = it.id }
                    }
                }
            }
            .frame(maxHeight: 140)
            Divider()
            if let s = selected, gen.layout.items.contains(where: { $0.id == s }) {
                let b = gen.item(s)
                Picker("Kind", selection: b.label) {
                    Text("Object").tag("object"); Text("Character").tag("character"); Text("Text").tag("text")
                }
                .pickerStyle(.segmented)
                if b.wrappedValue.label == "text" {
                    Text("Visible text").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: b.text).font(.body).frame(height: 56).border(Color(nsColor: .separatorColor))
                }
                Text("Caption · appearance, typography").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: b.caption).font(.body).frame(height: 84).border(Color(nsColor: .separatorColor))
                Grid(horizontalSpacing: 6, verticalSpacing: 4) {
                    GridRow { Text("x").foregroundStyle(.secondary); TextField("", value: b.x0, format: .number); Text("y").foregroundStyle(.secondary); TextField("", value: b.y0, format: .number) }
                    GridRow { Text("x2").foregroundStyle(.secondary); TextField("", value: b.x1, format: .number); Text("y2").foregroundStyle(.secondary); TextField("", value: b.y1, format: .number) }
                }
                .controlSize(.small)
                HStack {
                    Button("Duplicate") {
                        var copy = b.wrappedValue; copy.id = UUID(); copy.set(copy.rect.offsetBy(dx: 24, dy: 24).intersection(canvasRect))
                        var l = gen.layout; l.items.append(copy); gen.layout = l; selected = copy.id
                    }
                    Spacer()
                    Button("Delete", role: .destructive) { remove(s) }
                }
                .controlSize(.small)
            } else {
                Text("Select a box to edit it.").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            Divider()
            TextField("Meta tags", text: Binding(
                get: { gen.layout.meta.joined(separator: ", ") },
                set: { v in var l = gen.layout; l.meta = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; gen.layout = l }),
                prompt: Text("poster, infographic…"))
            Picker("Canvas", selection: Binding(get: { gen.layout.canvas }, set: { v in var l = gen.layout; l.canvas = v; gen.layout = l })) {
                Text("Single").tag("single"); Text("Multi panel").tag("multi_panel"); Text("Collage").tag("collage")
            }
            Text("The prompt field is the summary caption.").font(.caption).foregroundStyle(.secondary)
            Button("Clear all boxes", role: .destructive) { var l = gen.layout; l.items = []; gen.layout = l; selected = nil }
                .controlSize(.small).disabled(gen.layout.items.isEmpty)
        }
    }
}
