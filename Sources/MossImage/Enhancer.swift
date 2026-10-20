import Foundation

/// Prompt enhancer: one Claude Messages API call. Guidance condensed from OpenMOSS's
/// moss-image-prompt-enhancer skill (skills/moss-image-prompt-enhancer in the MOSS-Image repo).
enum Enhancer {
    struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static let system = """
    You expand image ideas into prompts for MOSS-Image, a text-to-image model with strong text rendering and \
    JSON layout control. Preserve the user's subjects, counts, relationships, medium, style, exclusions and any \
    intended visible wording. Resolve ordinary creative gaps yourself. Describe visible choices: subject and \
    action, appearance, setting, camera and framing, medium, lighting, materials, palette, mood. No quality tags, \
    no process notes, no explanations. Keep visible text verbatim, quoted exactly, in its original language. \
    Keep a minimalist brief minimalist.

    Output rules:
    - CAPTION mode: respond with exactly {"caption": "..."} — cohesive prose, spatial relations in words.
    - LAYOUT mode: respond with exactly one JSON object: {"summary": {"meta": [...], "canvas": "single", \
    "caption": "global scene and style description"}, "items": [{"label": "object|character|text", "caption": \
    "visible appearance; for text also typography and surface", "text": "exact visible characters, text items \
    only", "bbox": [x_min, y_min, x_max, y_max]}, ...]}. Boxes are integer pixels from the canvas top-left, within \
    the given width and height. Use boxes for coherent visible units; several may overlap naturally. Write real \
    copy, never placeholders. Make text boxes large enough for the glyphs at the declared resolution.
    Respond with JSON only, no markdown fences, no commentary.
    """

    static func run(apiKey: String, model: String, idea: String, want: String, width: Int, height: Int) async throws -> String {
        let user = want == "layout"
            ? "LAYOUT mode. Canvas \(width)×\(height) pixels. Idea: \(idea)"
            : "CAPTION mode. Idea: \(idea)"
        let body: [String: Any] = ["model": model, "max_tokens": 8000, "system": system,
                                   "messages": [["role": "user", "content": user]]]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw APIError(message: msg)
        }
        if json["stop_reason"] as? String == "refusal" { throw APIError(message: "The model declined this request.") }
        let text = (json["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw APIError(message: "Empty response") }
        if want == "caption" {
            // {"caption": "..."} -> plain text; tolerate a bare string
            if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
               let obj = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any],
               let cap = obj["caption"] as? String { return cap }
        }
        return text
    }
}

/// Hugging Face Hub search for adapters.
enum HubSearch {
    struct Model: Identifiable, Hashable { let id: String; let downloads: Int; let likes: Int }

    static func models(_ query: String) async throws -> [Model] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        c.queryItems = [.init(name: "search", value: query), .init(name: "limit", value: "40"), .init(name: "sort", value: "downloads")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let arr = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return arr.compactMap { m in
            guard let id = m["id"] as? String ?? m["modelId"] as? String else { return nil }
            return Model(id: id, downloads: m["downloads"] as? Int ?? 0, likes: m["likes"] as? Int ?? 0)
        }
    }

    /// .safetensors files in a repo.
    static func files(_ repo: String) async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://huggingface.co/api/models/\(repo)")!)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (obj["siblings"] as? [[String: Any]] ?? []).compactMap { $0["rfilename"] as? String }.filter { $0.hasSuffix(".safetensors") }
    }
}
