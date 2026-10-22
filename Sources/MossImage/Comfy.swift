import Foundation

/// Remote backend: drives a ComfyUI server (0.42+ with MOSS-Image support) over its HTTP+WebSocket API.
/// Graphs are built in API format from the same native nodes the official template's subgraph wraps
/// (UNETLoader · CLIPLoader type moss_image · VAELoader · KSampler er_sde/simple · SkipLayerGuidanceDiTSimple);
/// init-image, mask and LoRA support come from the generic LoadImage/VAEEncode/SetLatentNoiseMask/LoraLoaderModelOnly
/// nodes. The app's compiled layout JSON *is* the model's prompt format, so layout needs no Comfy-specific node.

/// One workflow in ComfyUI API format: nodes addressed by id, inputs flattened to "12": ["4", 0].
enum ComfyGraph {
    struct LoRA { let name: String; let scale: Double }   // server-side filename, e.g. "dmd.safetensors"

    /// Builds the graph for one render. `initImage`/`mask` are names previously uploaded to the server.
    /// The positive prompt carries the app's layout JSON unchanged; the upsampler is not used.
    static func build(_ r: Render, loras: [LoRA], checkpoint: String, textEncoder: String, vae: String) -> [String: Any] {
        var g: [String: Any] = [:]
        func put(_ id: String, classType: String, inputs: [String: Any]) { g[id] = ["class_type": classType, "inputs": inputs] }

        put("1", classType: "UNETLoader", inputs: ["unet_name": checkpoint, "weight_dtype": "default"])
        put("2", classType: "CLIPLoader", inputs: ["clip_name": textEncoder, "type": "moss_image", "device": "default"])
        put("3", classType: "VAELoader", inputs: ["vae_name": vae])
        put("5", classType: "CLIPTextEncode", inputs: ["text": r.prompt, "clip": ["2", 0]])
        put("6", classType: "CLIPTextEncode", inputs: ["text": r.negative_prompt, "clip": ["2", 0]])

        // model path: UNet → LoRA chain (application order, ids in a reserved range so a long chain can never
        // collide with the fixed nodes below) → skip-layer guidance
        var modelRef: [Any] = ["1", 0]
        for (i, lora) in loras.enumerated() {
            let id = String(100 + i)
            put(id, classType: "LoraLoaderModelOnly", inputs: ["lora_name": lora.name, "strength_model": lora.scale, "model": modelRef])
            modelRef = [id, 0]
        }
        let slg = r.slg_layers
        if !slg.isEmpty {
            put("20", classType: "SkipLayerGuidanceDiTSimple",
                inputs: ["model": modelRef, "double_layers": "", "single_layers": slg.map(String.init).joined(separator: ","),
                         "start_percent": r.slg_start, "end_percent": r.slg_stop])
            modelRef = ["20", 0]
        }

        // latent source: empty canvas, or the source image encoded at the render's size; the mask arrives
        // already feathered from the app (no server-side blur node — it would be a custom-node dependency)
        if let source = r.init_image {
            put("21", classType: "LoadImage", inputs: ["image": source])
            put("22", classType: "VAEEncode", inputs: ["pixels": ["21", 0], "vae": ["3", 0]])
            var latent: [Any] = ["22", 0]
            if let mask = r.mask {
                put("23", classType: "LoadImageMask", inputs: ["image": mask, "channel": "red"])
                put("25", classType: "SetLatentNoiseMask", inputs: ["samples": ["22", 0], "mask": ["23", 0]])
                latent = ["25", 0]
            }
            put("7", classType: "KSampler",
                inputs: ["model": modelRef, "positive": ["5", 0], "negative": ["6", 0], "latent_image": latent,
                         "seed": r.seed, "steps": r.steps, "cfg": r.guidance, "sampler_name": "er_sde", "scheduler": "simple", "denoise": r.strength])
        } else {
            put("8", classType: "EmptyFlux2LatentImage", inputs: ["width": r.width, "height": r.height, "batch_size": 1])
            put("7", classType: "KSampler",
                inputs: ["model": modelRef, "positive": ["5", 0], "negative": ["6", 0], "latent_image": ["8", 0],
                         "seed": r.seed, "steps": r.steps, "cfg": r.guidance, "sampler_name": "er_sde", "scheduler": "simple", "denoise": 1])
        }

        put("9", classType: "VAEDecode", inputs: ["samples": ["7", 0], "vae": ["3", 0]])
        put("30", classType: "SaveImage", inputs: ["images": ["9", 0], "filename_prefix": "moss-remote/" + String(r.seed)])
        return g
    }

    /// Sanity headlessly checked in Tests/checks: every link points at an existing node (no dangling refs, no
    /// self-references, no cycles), which is what silently corrupts a graph when node ids collide.
    static func validate(_ g: [String: Any]) -> [String] {
        var problems: [String] = []
        for (id, node) in g {
            guard let n = node as? [String: Any], let inputs = n["inputs"] as? [String: Any] else { problems.append("node \(id) malformed"); continue }
            for (k, v) in inputs {
                if let ref = v as? [Any], ref.count == 2, let target = ref[0] as? String {
                    if g[target] == nil { problems.append("\(id).\(k) → missing node \(target)") }
                    if target == id { problems.append("\(id).\(k) references itself") }
                }
            }
        }
        return problems
    }
}

/// HTTP client for one ComfyUI server. All calls async; the session is shared because the app talks to one
/// server at a time. Poll-free: submission returns a prompt id, WebSocket events drive progress, per-image
/// completion is read from /history/{id}.
final class ComfyClient {
    let base: URL
    private let token: String
    /// multipart upload boundary, fixed: ComfyUI's Python multipart parser accepts any token not present in the body
    private let boundary = "mossimage-b7f3c9d4"

    init(base: URL, token: String = "") {
        self.base = base; self.token = token
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        if !token.isEmpty { req.setValue("Bearer " + token.replacingOccurrences(of: "\n", with: ""), forHTTPHeaderField: "Authorization") }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        req.timeoutInterval = 120
        return req
    }

    private static func string(from data: Data, resp: URLResponse) -> String {
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { return "HTTP \(http.statusCode)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// POST /upload/image — the server stores under the given subdirectory/name; returns that "filename".
    func upload(pngAt path: String, as name: String) async throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else { throw ComfyError.message("Could not read \(path)") }
        var body = Data()
        func part(_ s: String) { body.append(Data(s.utf8)) }
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(data)
        part("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--\(boundary)--\r\n")
        let (data_, resp) = try await URLSession.shared.data(for: request("upload/image", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
        let text = Self.string(from: data_, resp: resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data_) as? [String: Any], let file = obj["name"] as? String else {
            throw ComfyError.message("Upload rejected: \(text.split(separator: "\n").last.map(String.init) ?? text)")
        }
        return obj["subfolder"] as? String == nil || (obj["subfolder"] as? String)?.isEmpty == true
            ? file : "\(obj["subfolder"] as! String)/\(file)"
    }

    /// POST /prompt — queues the graph; resolves to the prompt id whose history shows the outputs.
    func submit(_ graph: [String: Any], clientId: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["prompt": graph, "client_id": clientId])
        let (data, resp) = try await URLSession.shared.data(for: request("prompt", method: "POST", body: body, contentType: "application/json"))
        let err = Self.string(from: data, resp: resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["prompt_id"] as? String else {
            // ComfyUI reports graph validation failures as {"error": ..., "node_errors": ...}
            let nodeErrs = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["node_errors"] as? [String: Any]
            let first = nodeErrs?.values.first as? [String: Any]
            throw ComfyError.message((first?["errors"] as? [[String: Any]])?.first?["message"] as? String
                ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? err.split(separator: "\n").last.map(String.init) ?? err)
        }
        return id
    }

    struct Output { let filename: String, subfolder: String, type: String }

    /// GET /history/{id} — the outputs of one prompt. A prompt that failed server-side (OOM, node crash) carries
    /// `status.status_str == "error"`; failing fast here is what keeps a prompt failure from looking like a
    /// still-running one when the WebSocket isn't up.
    func outputs(_ promptId: String) async throws -> [Output] {
        let (data, resp) = try await URLSession.shared.data(for: request("history/\(promptId)"))
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw ComfyError.message("history HTTP \(http.statusCode)") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entry = root[promptId] as? [String: Any] else { return [] }
        if let status = entry["status"] as? [String: Any], status["status_str"] as? String == "error" {
            var detail = ""
            if let messages = status["messages"] as? [[Any]], let payload = messages.last?.last as? [String: Any] {
                detail = (payload["exception_message"] as? String) ?? (payload["exception_type"] as? String) ?? ""
            }
            throw ComfyError.message(detail.isEmpty ? "the prompt failed on the server." : detail)
        }
        guard let out = entry["outputs"] as? [String: Any] else { return [] }
        return out.values.flatMap { ($0 as? [String: Any])?["images"] as? [[String: Any]] ?? [] }.compactMap { im in
            guard let filename = im["filename"] as? String else { return nil }
            return Output(filename: filename, subfolder: im["subfolder"] as? String ?? "", type: im["type"] as? String ?? "output")
        }
    }

    /// GET /view — the bytes of one output image.
    func fetch(_ o: Output) async throws -> Data {
        var c = URLComponents(url: base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "filename", value: o.filename), URLQueryItem(name: "subfolder", value: o.subfolder), URLQueryItem(name: "type", value: o.type)]
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: c.url!))
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw ComfyError.message("view HTTP \(http.statusCode)") }
        return data
    }

    /// POST /interrupt — cancels the running prompt; queued ones keep it for the next submission.
    func interrupt() async { try? await URLSession.shared.data(for: request("interrupt", method: "POST")) }

    /// GET /system_stats — cheap reachability/identity check for the Settings pane.
    func ping() async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for: request("system_stats"))
        let text = Self.string(from: data, resp: resp)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sys = obj["system"] as? [String: Any], let os = sys["os"] as? String, let py = sys["python_version"] as? String else {
            throw ComfyError.message(text.isEmpty ? "no response" : text.split(separator: "\n").last.map(String.init) ?? "unknown error")
        }
        return "\(os) · ComfyUI · Python \(py.split(separator: " ").first ?? "")"
    }
}

enum ComfyError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let m): return m } }
}

/// Progress per queued render. The server's events drive the UI's step/total and batch bookkeeping; images are
/// picked up from /history when the prompt finishes.
enum ComfyEvents {
    enum Event: Equatable {
        case executing(id: String, node: String?)   // node nil = the prompt finished
        case progress(id: String, step: Int, of: Int)
        case error(id: String)
    }

    /// One JSON line of the /ws stream. Preview frames (binary) are not parsed here; v1 shows steps only.
    static func parse(_ data: Data) -> Event? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = obj["type"] as? String,
              let d = obj["data"] as? [String: Any], let id = d["prompt_id"] as? String else { return nil }
        switch type {
        case "executing":
            return d["node"] as? String == nil ? .executing(id: id, node: nil) : .executing(id: id, node: d["node"] as? String)
        case "execution_error":
            return .error(id: id)
        case "progress":
            let v = (d["value"] as? Int) ?? Int(d["value"] as? Double ?? 0)
            let m = (d["max"] as? Int) ?? Int(d["max"] as? Double ?? 0)
            return .progress(id: id, step: v, of: m)
        default:
            return nil
        }
    }
}
