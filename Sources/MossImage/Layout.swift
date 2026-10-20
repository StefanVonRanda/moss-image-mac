import SwiftUI

/// MOSS-Image layout: boxes in top-left pixel coordinates while editing, compiled to the model's
/// centred yxyx form (floor left/top, ceil right/bottom, then subtract the canvas centre).
struct LayoutItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var label = "object"       // object | character | text
    var caption = ""
    var text = ""              // visible characters, text items only
    var x0: Double, y0: Double, x1: Double, y1: Double

    var rect: CGRect { CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)) }
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
        return (layout, caption)
    }
}

/// Draw boxes on a canvas sized like the output, edit each box's label, text and caption.
struct LayoutEditor: View {
    @ObservedObject var gen: Generator
    @Environment(\.dismiss) private var dismiss
    @State private var layout: MossLayout
    @State private var selected: UUID?
    @State private var dragStart: CGPoint?
    @State private var dragRect: CGRect?

    init(gen: Generator) { self.gen = gen; _layout = State(initialValue: gen.layout) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Layout · \(gen.width) × \(gen.height)").font(.headline)
                Spacer()
                Text("Drag to draw a box. Click to select. ⌫ deletes.").foregroundStyle(.secondary).font(.caption)
            }
            HStack(alignment: .top, spacing: 16) {
                GeometryReader { geo in
                    let scale = min(geo.size.width / CGFloat(gen.width), geo.size.height / CGFloat(gen.height))
                    let size = CGSize(width: CGFloat(gen.width) * scale, height: CGFloat(gen.height) * scale)
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color(nsColor: .textBackgroundColor)).border(Color(nsColor: .separatorColor))
                        ForEach(layout.items) { it in
                            let r = it.rect
                            ZStack(alignment: .topLeading) {
                                Rectangle().stroke(it.id == selected ? Color.accentColor : Color.secondary, lineWidth: it.id == selected ? 2 : 1)
                                    .background(Rectangle().fill((it.label == "text" ? Color.accentColor : Color.secondary).opacity(0.08)))
                                Text(it.label == "text" && !it.text.isEmpty ? it.text : it.label)
                                    .font(.caption).lineLimit(2).padding(3)
                            }
                            .frame(width: r.width * scale, height: r.height * scale)
                            .offset(x: r.minX * scale, y: r.minY * scale)
                            .onTapGesture { selected = it.id }
                        }
                        if let d = dragRect {
                            Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .frame(width: d.width * scale, height: d.height * scale).offset(x: d.minX * scale, y: d.minY * scale)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            let a = CGPoint(x: g.startLocation.x / scale, y: g.startLocation.y / scale)
                            let b = CGPoint(x: g.location.x / scale, y: g.location.y / scale)
                            dragRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                                .intersection(CGRect(x: 0, y: 0, width: gen.width, height: gen.height))
                        }
                        .onEnded { _ in
                            if let d = dragRect, d.width > 8, d.height > 8 {
                                let item = LayoutItem(x0: d.minX.rounded(), y0: d.minY.rounded(), x1: d.maxX.rounded(), y1: d.maxY.rounded())
                                layout.items.append(item); selected = item.id
                            }
                            dragRect = nil
                        })
                }
                .frame(minWidth: 480, minHeight: 360)

                VStack(alignment: .leading, spacing: 8) {
                    if let i = layout.items.firstIndex(where: { $0.id == selected }) {
                        Picker("Kind", selection: $layout.items[i].label) {
                            Text("Object").tag("object"); Text("Character").tag("character"); Text("Text").tag("text")
                        }
                        if layout.items[i].label == "text" {
                            Text("Visible text").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $layout.items[i].text).font(.body).frame(height: 60)
                        }
                        Text("Caption (appearance, typography)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $layout.items[i].caption).font(.body).frame(height: 90)
                        HStack {
                            TextField("x", value: $layout.items[i].x0, format: .number); TextField("y", value: $layout.items[i].y0, format: .number)
                            TextField("x2", value: $layout.items[i].x1, format: .number); TextField("y2", value: $layout.items[i].y1, format: .number)
                        }
                        .controlSize(.small)
                        Button("Delete box", role: .destructive) { layout.items.remove(at: i); selected = nil }
                    } else {
                        Text("No box selected").foregroundStyle(.secondary)
                    }
                    Divider()
                    TextField("Meta tags (poster, infographic…)", text: Binding(
                        get: { layout.meta.joined(separator: ", ") },
                        set: { layout.meta = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    Picker("Canvas", selection: $layout.canvas) {
                        Text("Single").tag("single"); Text("Multi panel").tag("multi_panel"); Text("Collage").tag("collage")
                    }
                    Spacer()
                    Text("Summary caption is the prompt field.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 260)
            }
            HStack {
                Button("Clear all", role: .destructive) { layout.items = []; selected = nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use layout") { gen.layout = layout; gen.layoutMode = !layout.items.isEmpty; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 520)
        .onDeleteCommand { if let s = selected { layout.items.removeAll { $0.id == s }; selected = nil } }
    }
}
