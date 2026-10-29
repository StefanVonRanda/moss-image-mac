import Foundation

/// A full MOSS-Image image model in one `.safetensors` file, as community finetunes such as kromoss ship it
/// (ComfyUI's `model.diffusion_model.` layout). The engine loads a diffusers-style transformer directory, so the
/// file is converted once into `…/models/<name>-<size>-<mtime>/transformer`:
///
/// - `model.diffusion_model.` is dropped;
/// - each block's fused `proj.qkv` is split into `proj.q`, `proj.k` and `proj.v` (the MLX model keeps them apart);
/// - `time_embedding.2` becomes `time_embedding.1` (the MLX model has two time layers, the original three);
/// - `rope.bands` and components that are not the image transformer (text encoder, VAE) are dropped.
///
/// Only the header is read and the data is copied block by block, so converting a 10 GB checkpoint keeps memory
/// flat. The text encoder, tokenizer and VAE still come from the selected downloaded tier: `--model` keeps its
/// tier and the converted directory goes as `--transformer`.
enum Checkpoint {
    /// Bump when the key mapping or the output layout changes, so cached conversions are rebuilt.
    static let version = 1

    enum Failure: LocalizedError {
        case unreadable(String)
        case notAModel(String)
        case notMoss(String)
        case incompatible(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let s): return s
            case .notAModel(let s): return s
            case .notMoss(let s): return s
            case .incompatible(let s): return s
            }
        }
    }

    /// One tensor as the safetensors header describes it; offsets are absolute in the file, so the data can be
    /// copied straight from the source.
    struct Tensor {
        var name: String
        var dtype: String
        var shape: [Int]
        var begin: Int
        var end: Int
        var bytes: Int { end - begin }
    }

    /// What the converter learned from the file, before any data is copied.
    struct Summary {
        var layers: Int
        var dim: Int
        var name: String
    }

    private struct Manifest: Codable {
        var source: String
        var size: Int64
        var modified: Double
        var version: Int
    }

    // MARK: header

    /// Read the safetensors header only: tensor names, dtypes, shapes and byte ranges.
    static func tensors(of url: URL) throws -> [Tensor] {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path), let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 8 else {
            throw Failure.unreadable("\(url.lastPathComponent) is empty or unreadable.")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.unreadable("Could not open \(url.lastPathComponent).")
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else {
            throw Failure.notAModel("\(url.lastPathComponent) is not a .safetensors file.")
        }
        var n: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &n) { head.copyBytes(to: $0) }
        n = UInt64(littleEndian: n)
        guard n > 1, n < 100 << 20, Int64(8 + Int(n)) <= size else {
            throw Failure.notAModel("\(url.lastPathComponent) is not a .safetensors file.")
        }
        guard let json = try? handle.read(upToCount: Int(n)),
              let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw Failure.notAModel("\(url.lastPathComponent) has an unreadable safetensors header.")
        }
        let dataStart = 8 + Int(n), dataSize = Int(size) - dataStart
        var out: [Tensor] = []
        for (name, value) in obj where name != "__metadata__" {
            guard let t = value as? [String: Any], let dtype = t["dtype"] as? String,
                  let shape = t["shape"] as? [Int], shape.allSatisfy({ $0 >= 0 }),
                  let offsets = t["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0], offsets[1] <= dataSize,
                  let element = elementSize(dtype) else {
                throw Failure.notAModel("\(url.lastPathComponent) has a malformed tensor \(name).")
            }
            let count = shape.reduce(1, *) * element
            guard count == offsets[1] - offsets[0] else {
                throw Failure.notAModel("\(url.lastPathComponent): \(name) has inconsistent sizes.")
            }
            out.append(Tensor(name: name, dtype: dtype, shape: shape,
                              begin: dataStart + offsets[0], end: dataStart + offsets[1]))
        }
        guard !out.isEmpty else { throw Failure.notAModel("\(url.lastPathComponent) has no tensors.") }
        return out
    }

    private static func elementSize(_ dtype: String) -> Int? {
        switch dtype {
        case "F64", "I64", "U64": return 8
        case "F32", "I32", "U32": return 4
        case "F16", "BF16", "I16", "U16": return 2
        case "I8", "U8", "BOOL", "F8_E4M3", "F8_E5M2", "F8_E4M3FN": return 1
        default: return nil
        }
    }

    /// Is this a LoRA rather than a full model? Used for a plain error message, not conversion.
    static func looksLikeLoRA(_ tensors: [Tensor]) -> Bool {
        tensors.contains { t in
            let n = t.name
            return n.contains(".lora_") || n.hasPrefix("lora_unet_") || n.hasSuffix(".alpha")
                || n.contains("lora_A") || n.contains("lora_B")
        }
    }

    /// ComfyUI's int8/FP8 repacks are not the MLX layout the engine loads: say so instead of copying 10 GB first.
    private static func checkSupported(_ tensors: [Tensor], file: String) throws {
        let quantized = tensors.contains { t in
            if t.name.hasSuffix(".weight_scale") || t.name.hasSuffix(".comfy_quant") { return true }
            return t.name.hasSuffix(".weight") && ["U8", "I8", "F8_E4M3", "F8_E5M2", "F8_E4M3FN"].contains(t.dtype)
        }
        guard !quantized else {
            throw Failure.incompatible("\(file) is a quantized ComfyUI checkpoint. Choose its bf16 or fp16 build.")
        }
    }

    // MARK: inspection and conversion

    /// Validate the architecture and return what the UI shows, without writing anything.
    static func summary(of url: URL) throws -> Summary {
        let tensors = try tensors(of: url)
        guard !looksLikeLoRA(tensors) else {
            throw Failure.notAModel("\(url.lastPathComponent) is a LoRA, not a full model. Add it in the LoRA library.")
        }
        try checkSupported(tensors, file: url.lastPathComponent)
        let mapped = try mapped(tensors, file: url.lastPathComponent)
        let layout = try layout(of: mapped, file: url.lastPathComponent)
        return Summary(layers: layout.layers, dim: layout.dim, name: url.deletingPathExtension().lastPathComponent)
    }

    /// A cached conversion of `source`, or convert it now. Returns the `transformer/` directory to pass as
    /// `--transformer`. `progress` is called on the converting thread with 0…1.
    @discardableResult
    static func install(_ source: URL, root: String, progress: @escaping (Double) -> Void = { _ in }) throws -> String {
        let url = source.standardizedFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 8 else {
            throw Failure.unreadable("\(url.lastPathComponent) is empty or unreadable.")
        }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stem = slug(url.deletingPathExtension().lastPathComponent)
        let models = URL(fileURLWithPath: root).appendingPathComponent("models")
        let dir = models.appendingPathComponent("\(stem)-\(size)-\(Int(modified))")
        let transformer = dir.appendingPathComponent("transformer")
        let manifest = Manifest(source: url.path, size: size, modified: modified, version: version)
        let manifestURL = dir.appendingPathComponent("manifest.json")

        if let data = try? Data(contentsOf: manifestURL), let cached = try? JSONDecoder().decode(Manifest.self, from: data),
           cached.source == manifest.source, cached.size == size, abs(cached.modified - modified) < 1, cached.version == version,
           FileManager.default.fileExists(atPath: transformer.appendingPathComponent("model.safetensors").path),
           FileManager.default.fileExists(atPath: transformer.appendingPathComponent("config.json").path) {
            return transformer.path
        }

        let tensors = try tensors(of: url)
        guard !looksLikeLoRA(tensors) else {
            throw Failure.notAModel("\(url.lastPathComponent) is a LoRA, not a full model. Add it in the LoRA library.")
        }
        try checkSupported(tensors, file: url.lastPathComponent)
        let mapped = try mapped(tensors, file: url.lastPathComponent)
        let layout = try layout(of: mapped, file: url.lastPathComponent)
        try checkDiskSpace(for: size, at: models)

        let fm = FileManager.default
        try fm.createDirectory(at: transformer, withIntermediateDirectories: true)
        do {
            try write(mapped, from: url, to: transformer.appendingPathComponent("model.safetensors"), progress: progress)
            try writeConfig(layout, to: transformer.appendingPathComponent("config.json"))
            let encoded = try JSONEncoder().encode(manifest)
            try encoded.write(to: manifestURL, options: .atomic)
        } catch {
            try? fm.removeItem(at: dir)   // never leave a half-converted model that a later run might trust
            throw error
        }
        return transformer.path
    }

    private static func checkDiskSpace(for size: Int64, at models: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)
        guard let free = try? models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return }
        let needed = size + (1 << 30)   // the copy plus a little working room
        if free < needed {
            let gb = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
            throw Failure.incompatible("Not enough free space for the converted copy: \(gb(size)) needed, \(gb(free)) available.")
        }
    }

    // MARK: key mapping

    private struct Layout {
        var dim: Int
        var ffn: Int
        var heads: Int
        var layers: Int
        var textDim: Int
        var freq: Int
        var latent: Int
    }

    /// Strip the ComfyUI prefix, rename time_embedding.2, split fused qkv, drop non-transformer tensors.
    private static func mapped(_ tensors: [Tensor], file: String) throws -> [Tensor] {
        let prefixes = ["model.diffusion_model.", "diffusion_model.", "transformer.", "model."]
        var out: [Tensor] = []
        var names = Set<String>()
        for tensor in tensors {
            var name = tensor.name
            if let prefix = prefixes.first(where: { name.hasPrefix($0) }) {
                name = String(name.dropFirst(prefix.count))
            }
            if name == "rope.bands" { continue }   // derived at load
            if name.hasPrefix("time_embedding.2.") {
                name = "time_embedding.1." + name.dropFirst("time_embedding.2.".count)
            }
            guard !name.isEmpty else { continue }
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 5, parts[0] == "layers", Int(parts[1]) != nil, parts[2] == "proj", parts[3] == "qkv" {
                guard tensor.shape.count >= 1, tensor.shape[0] > 0, tensor.shape[0] % 3 == 0 else {
                    throw Failure.incompatible("\(file): \(tensor.name) is not a fused 3-way projection (shape \(tensor.shape)).")
                }
                let rows = tensor.bytes / tensor.shape[0], each = tensor.shape[0] / 3
                for (i, leaf) in ["q", "k", "v"].enumerated() {
                    let begin = tensor.begin + i * each * rows
                    try append(Tensor(name: "layers.\(parts[1]).proj.\(leaf).\(parts[4])", dtype: tensor.dtype,
                                      shape: [each] + Array(tensor.shape.dropFirst()), begin: begin,
                                      end: begin + each * rows), to: &out, names: &names)
                }
                continue
            }
            guard isTransformer(name) else { continue }   // text encoder, VAE, other components
            try append(Tensor(name: name, dtype: tensor.dtype, shape: tensor.shape,
                              begin: tensor.begin, end: tensor.end), to: &out, names: &names)
        }
        guard !out.isEmpty else {
            throw Failure.notMoss("\(file) does not contain a MOSS-Image image model. Choose a full .safetensors checkpoint, not a LoRA.")
        }
        return out.sorted { $0.begin < $1.begin }
    }

    private static func append(_ tensor: Tensor, to out: inout [Tensor], names: inout Set<String>) throws {
        guard names.insert(tensor.name).inserted else {
            throw Failure.incompatible("Duplicate tensor \(tensor.name) after conversion.")
        }
        out.append(tensor)
    }

    private static func isTransformer(_ name: String) -> Bool {
        ["video_embedder.", "text_embedder.", "time_embedding.", "shared_block_modulation.", "layers.",
         "final_norm_video.", "final_linear_video.", "video_head_modulation."].contains { name.hasPrefix($0) }
    }

    /// Read the architecture from the mapped tensors and check the shapes the MLX model will load strictly.
    private static func layout(of tensors: [Tensor], file: String) throws -> Layout {
        let byName = Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0) })
        func get(_ name: String) throws -> Tensor {
            guard let t = byName[name] else {
                throw Failure.notMoss("\(file) is missing \(name): it does not look like a MOSS-Image model.")
            }
            return t
        }
        func shape(_ name: String, _ expected: [Int?]) throws -> Tensor {
            let t = try get(name)
            guard t.shape.count == expected.count, zip(t.shape, expected).allSatisfy({ $1 == nil || $0 == $1 }) else {
                throw Failure.incompatible("\(file): \(name) has shape \(t.shape), expected \(expected.map { $0.map(String.init) ?? "?" }).")
            }
            return t
        }

        let embed = try shape("video_embedder.weight", [nil, nil])
        guard embed.shape.count == 2 else { throw Failure.incompatible("\(file): video_embedder.weight must be 2-D.") }
        let dim = embed.shape[0], latent = embed.shape[1]
        guard dim > 0, dim % 2 == 0 else { throw Failure.incompatible("\(file): unsupported model width \(dim).") }
        let final = try shape("final_linear_video.weight", [latent, dim])
        _ = final
        let textProj = try shape("text_embedder.proj.weight", [dim, nil])
        let textDim = textProj.shape[1]
        let freq = try shape("time_embedding.0.weight", [dim, nil]).shape[1]
        _ = try shape("time_embedding.1.weight", [dim, dim])
        _ = try shape("shared_block_modulation.weight", [6 * dim, dim])
        _ = try shape("video_head_modulation.weight", [2 * dim, dim])
        _ = try shape("final_norm_video.weight", [dim])

        let qNorm = try shape("layers.0.q_norm.weight", [nil])
        let headDim = qNorm.shape[0]
        guard headDim > 0, dim % headDim == 0 else { throw Failure.incompatible("\(file): q_norm width \(headDim) does not divide \(dim).") }
        let heads = dim / headDim
        let ffn = try shape("layers.0.proj.ffn_down.weight", [dim, nil]).shape[1]
        let upGate = try shape("layers.0.proj.ffn_up_gate.weight", [2 * ffn, dim])
        _ = upGate
        _ = try shape("layers.0.proj.o.weight", [dim, dim])
        _ = try shape("layers.0.proj.q.weight", [dim, dim])
        _ = try shape("layers.0.proj.k.weight", [dim, dim])
        _ = try shape("layers.0.proj.v.weight", [dim, dim])
        _ = try shape("layers.0.proj.ffn_down.weight", [dim, ffn])
        _ = try shape("layers.0.norm1.weight", [dim])
        _ = try shape("layers.0.norm2.weight", [dim])
        _ = try shape("layers.0.q_norm.weight", [headDim])
        _ = try shape("layers.0.k_norm.weight", [headDim])

        // The MLX blocks are bias-free; a checkpoint with block biases is a different architecture and would only
        // fail the strict load after the copy.
        if tensors.contains(where: { $0.name.hasPrefix("layers.") && $0.name.hasSuffix(".bias") }) {
            throw Failure.incompatible("\(file): its transformer blocks have bias tensors, which MOSS-Image does not use.")
        }

        // Every block must be present: a strict load would otherwise fail after the 10 GB copy.
        let indices = Set(tensors.compactMap { t -> Int? in
            let parts = t.name.split(separator: ".")
            guard parts.count > 1, parts[0] == "layers" else { return nil }
            return Int(parts[1])
        })
        guard let last = indices.max(), last + 1 == indices.count else {
            throw Failure.incompatible("\(file): its transformer blocks are not numbered 0…N.")
        }
        let layers = last + 1
        let required = ["norm1.weight", "norm2.weight", "q_norm.weight", "k_norm.weight",
                        "proj.q.weight", "proj.k.weight", "proj.v.weight", "proj.o.weight",
                        "proj.ffn_up_gate.weight", "proj.ffn_down.weight"]
        for i in 0..<layers {
            for key in required where byName["layers.\(i).\(key)"] == nil {
                throw Failure.incompatible("\(file): transformer block \(i) is missing \(key).")
            }
        }
        // The text projection and the time/embedding heads are part of the checkpoint too; a strict load would
        // otherwise fail only after the whole copy.
        let textBlock = ["norm1.weight", "norm2.weight", "q_norm.weight", "k_norm.weight", "qkv.weight", "qkv.bias",
                         "proj.weight", "proj.bias", "ffn_gate.weight", "ffn_gate.bias", "ffn_up.weight", "ffn_up.bias",
                         "ffn_down.weight", "ffn_down.bias"]
        for block in 0..<2 {
            for key in textBlock where byName["text_embedder.blocks.\(block).\(key)"] == nil {
                throw Failure.incompatible("\(file): text projection block \(block) is missing \(key).")
            }
        }
        for key in ["video_embedder.bias", "text_embedder.proj.bias", "time_embedding.0.bias", "time_embedding.1.bias",
                    "shared_block_modulation.bias", "video_head_modulation.bias"] where byName[key] == nil {
            throw Failure.incompatible("\(file): it is missing \(key).")
        }
        return Layout(dim: dim, ffn: ffn, heads: heads, layers: layers, textDim: textDim, freq: freq, latent: latent)
    }

    private static func writeConfig(_ layout: Layout, to url: URL) throws {
        let config: [String: Any] = [
            "_class_name": "MOSSImageTransformer",
            "dim": layout.dim, "ffn_dim": layout.ffn, "num_heads": layout.heads, "num_layers": layout.layers,
            "text_dim": layout.textDim, "freq_dim": layout.freq, "latent_channels": layout.latent,
            "rope_base": 10000.0,
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: writing

    /// Write the mapped tensors as one safetensors file, copying `chunk` bytes at a time. Offsets stay contiguous;
    /// the data section is byte-identical to the source ranges, so no tensor is ever loaded into memory.
    private static func write(_ tensors: [Tensor], from source: URL, to destination: URL,
                              progress: @escaping (Double) -> Void) throws {
        let chunk = 8 << 20
        var header: [String: Any] = [:]
        var offset = 0
        for t in tensors {
            header[t.name] = ["dtype": t.dtype, "shape": t.shape, "data_offsets": [offset, offset + t.bytes]]
            offset += t.bytes
        }
        var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while json.count % 8 != 0 { json.append(0x20) }   // the format pads the header to 8 bytes
        var head = Data()
        var n = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &n) { head.append(contentsOf: $0) }
        head.append(json)

        let tmp = destination.appendingPathExtension("part")
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw Failure.unreadable("Could not create \(tmp.path).")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: tmp)
        do {
            try output.write(contentsOf: head)
            let total = max(offset, 1)
            var copied = 0, reported = 0
            for t in tensors {
                try input.seek(toOffset: UInt64(t.begin))
                var remaining = t.bytes
                while remaining > 0 {
                    guard let data = try input.read(upToCount: min(remaining, chunk)), !data.isEmpty else {
                        throw Failure.unreadable("Unexpected end of \(source.lastPathComponent).")
                    }
                    try output.write(contentsOf: data)
                    remaining -= data.count
                    copied += data.count
                    if copied - reported >= 64 << 20 || copied == total {
                        reported = copied
                        progress(Double(copied) / Double(total))
                    }
                }
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? fm.removeItem(at: tmp)   // the handle closes when it leaves scope
            throw error
        }
        try? fm.removeItem(at: destination)   // a stale or incomplete earlier copy at the same path
        try fm.moveItem(at: tmp, to: destination)
        progress(1)
    }

    // MARK: names

    /// Keep the checkpoint's name recognisable and safe as a directory name.
    private static func slug(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        var out = String(name.map { allowed.contains($0) ? $0 : "-" }.prefix(48))
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
        return out.isEmpty ? "model" : out
    }
}
