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

    static func userMessage(idea: String, want: String, width: Int, height: Int) -> String {
        want == "layout" ? "LAYOUT mode. Canvas \(width)×\(height) pixels. Idea: \(idea)" : "CAPTION mode. Idea: \(idea)"
    }

    /// {"caption": "..."} -> plain text; tolerates a bare string.
    static func caption(from text: String) -> String {
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
           let obj = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any],
           let cap = obj["caption"] as? String { return cap }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local model through mlx-lm in the engine's venv (`EngineHome.python`).
    static func local(python: String, model: String, idea: String, want: String, width: Int, height: Int) async throws -> String {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let script = tmp.appendingPathComponent("moss-enhance.py"), sys = tmp.appendingPathComponent("moss-enhance-system.txt")
        try localScript.write(to: script, atomically: true, encoding: .utf8)
        try system.write(to: sys, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script.path, model, sys.path, userMessage(idea: idea, want: want, width: width, height: height)]
        // Files, not Pipes: first-run download progress fills a 64 KB stderr pipe and deadlocks a sequential read.
        let outURL = tmp.appendingPathComponent("moss-enhance-\(UUID().uuidString).out"), errURL = outURL.deletingPathExtension().appendingPathExtension("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil); FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        p.standardOutput = out; p.standardError = err
        // Wait on terminationHandler so no thread blocks while the model loads.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
        try? out.close(); try? err.close()
        let data = (try? Data(contentsOf: outURL)) ?? Data()
        let errText = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            if errText.contains("No module named 'mlx_lm'") { throw APIError(message: "mlx-lm is not installed. Run setup.sh again, or: \(python) -m pip install mlx-lm") }
            throw APIError(message: errText.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)")
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw APIError(message: "Empty response from the local model") }
        return text
    }

    // ponytail: the script lives in scripts/enhance_local.py too; keep the two in sync
    static let localScript = """
    import sys
    from mlx_lm import load, generate
    model_id, system_file, user = sys.argv[1], sys.argv[2], sys.argv[3]
    model, tok = load(model_id)
    messages = [{"role": "system", "content": open(system_file).read()}, {"role": "user", "content": user}]
    try:
        prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)
    except TypeError:
        prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
    print(generate(model, tok, prompt=prompt, max_tokens=1500, verbose=False))
    """

    static func claude(apiKey: String, model: String, idea: String, want: String, width: Int, height: Int) async throws -> String {
        let user = userMessage(idea: idea, want: want, width: width, height: height)
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
