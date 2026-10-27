import SwiftUI
import AppKit

/// Installs the app's own engine into `root` (EngineHome's Application Support folder) from the payload a release
/// build carries in Contents/Resources/engine (scripts/engine-payload.sh): a Python runtime and a venv with the
/// hash-pinned packages plus the moss-image-mlx wheel, both through the bundled uv, then the 8-step DMD adapter into
/// loras/. The venv is built in engine.partial/ and renamed to engine/ last, so a cancelled or failed run never counts
/// as installed, and a reinstall keeps the old engine until the new one is complete. uv runs without config files and
/// keeps its cache and Pythons in `root`, so nothing lands in ~/.cache or ~/.local; the venv is relocatable (its
/// scripts find their python relative to themselves), which is what lets the rename work.
@MainActor
final class EngineSetup: ObservableObject {
    enum Step: Int, CaseIterable { case python, packages, adapter }
    enum State: Equatable { case ready, running(Step), failed(Step, String), done }

    @Published var state = State.ready
    @Published var transfer: Transfer?   // the adapter download
    @Published var log = ""
    let root, payload: String
    let reinstall: Bool   // an engine is there already; it stays until the new one is complete
    private var process: Process?
    private var cancelled = false
    private var bars: [String: Transfer] = [:]

    init(root: String, payload: String) {
        self.root = root; self.payload = payload; reinstall = FileManager.default.isExecutableFile(atPath: root + "/engine/bin/moss-mlx")
    }

    static let dmd = "MOSS-Image-SFT-8-steps-dmd.safetensors"   // setup.sh's name for it, on in the default library
    static let download = "1.5 GB"   // Python, the packages and the adapter, roughly

    /// The payload in this app's bundle; nil in a build without one (plain build.sh).
    static var bundled: String? {
        let dir = Bundle.main.resourcePath.map { $0 + "/engine" }
        return dir.flatMap { FileManager.default.isExecutableFile(atPath: $0 + "/uv") ? $0 : nil }
    }

    /// First run: no engine where EngineHome looks, and this app can install one.
    static var needed: Bool { bundled != nil && !FileManager.default.isExecutableFile(atPath: EngineHome.current.cli) }

    var engine: String { root + "/engine" }

    func install() async {
        let fm = FileManager.default, partial = root + "/engine.partial", py = partial + "/bin/python"
        let lora = root + "/loras/" + Self.dmd
        cancelled = false; log = ""; transfer = nil; bars = [:]
        var step = Step.python
        do {
            try? fm.removeItem(atPath: partial)
            try fm.createDirectory(atPath: root + "/loras", withIntermediateDirectories: true)
            state = .running(step)
            try await uv(["python", "install", "--no-bin", "3.12"])
            try await uv(["venv", "--relocatable", "--python", "3.12", partial])
            step = .packages; state = .running(step)
            try await uv(["pip", "install", "--python", py, "--require-hashes", "-r", payload + "/requirements.lock"])
            let wheel = try fm.contentsOfDirectory(atPath: payload).first { $0.hasSuffix(".whl") } ?? "moss_image_mlx.whl"
            try await uv(["pip", "install", "--python", py, "--no-deps", payload + "/" + wheel])
            step = .adapter; state = .running(step)
            if !fm.fileExists(atPath: lora) {
                transfer = Transfer()
                try await run(py, ["-c", Generator.hubCopy, "lodestones/MOSS-Image-SFT-8-steps-dmd", "lora.safetensors", lora + ".part"])
                try fm.moveItem(atPath: lora + ".part", toPath: lora)
            }
            let old = root + "/engine.old"
            try? fm.removeItem(atPath: old)
            if fm.fileExists(atPath: engine) { try fm.moveItem(atPath: engine, toPath: old) }
            try fm.moveItem(atPath: partial, toPath: engine)
            try? fm.removeItem(atPath: old); try? fm.removeItem(atPath: root + "/cache")   // ponytail: a reinstall downloads again
            transfer = nil; state = .done
            NotificationCenter.default.post(name: .engineInstalled, object: nil)
        } catch {
            try? fm.removeItem(atPath: partial); try? fm.removeItem(atPath: lora + ".part")
            transfer = nil
            if !(error is Failure) { log += "\(error.localizedDescription)\n" }
            state = cancelled ? .ready : .failed(step, Self.offline(log) ? "No internet connection. Setup downloads about \(Self.download); connect to the internet and try again."
                                                                          : "Setup stopped with this message:")
        }
    }

    func cancel() { cancelled = true; process?.terminate() }

    /// What went wrong, for the sheet: uv's `error:` line with its causes, else the log's last line (Python's exception).
    var errorText: String {
        let lines = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let e = lines.lastIndex(where: { $0.hasPrefix("error:") }) else { return lines.last ?? "" }
        return ([lines[e]] + lines[(e + 1)...].prefix { $0.hasPrefix("cause:") || $0.hasPrefix("Caused by:") }).joined(separator: "\n")
    }

    func copyLog() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log, forType: .string) }

    /// Errors that mean the Mac could not reach the servers, from uv (Rust) and huggingface_hub (Python).
    nonisolated static func offline(_ log: String) -> Bool {
        ["dns error", "failed to lookup address", "error sending request", "Connection refused", "Network is unreachable",
         "NameResolutionError", "ConnectError", "Max retries exceeded", "internet connection appears to be offline"].contains { log.contains($0) }
    }

    private struct Failure: Error {}

    private func uv(_ arguments: [String]) async throws {
        try await run(payload + "/uv", arguments, env: ["UV_NO_CONFIG": "1", "UV_CACHE_DIR": root + "/cache", "UV_PYTHON_INSTALL_DIR": root + "/python",
                                                        "UV_MANAGED_PYTHON": "1", "NO_COLOR": "1"])
    }

    /// Runs one command, its output into `log` (and the download bars); throws when it fails or Cancel stopped it.
    private func run(_ executable: String, _ arguments: [String], env: [String: String] = [:]) async throws {
        guard !cancelled else { throw Failure() }
        log += "$ " + ([executable] + arguments).joined(separator: " ") + "\n"
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.environment = Generator.progressEnv.merging(env) { $1 }
        p.standardOutput = pipe; p.standardError = pipe
        // Output and the end both go through the main queue, so every line is in `log` before this returns.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard data.isEmpty else {
                    let text = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(text) } }
                    return
                }
                h.readabilityHandler = nil
                p.waitUntilExit()
                DispatchQueue.main.async { c.resume() }
            }
            do { try p.run(); process = p } catch { pipe.fileHandleForReading.readabilityHandler = nil; c.resume(throwing: error) }
        }
        process = nil
        guard p.terminationStatus == 0, !cancelled else { throw Failure() }
    }

    private func consume(_ text: String) {
        log += text
        if transfer != nil, Transfer.feed(text, into: &bars) { transfer = Transfer.sum(bars) }
    }

    // MARK: checks before installing

    /// One line of the checks before installing. `ok` false with `blocks` stops the install; without, it is a warning.
    struct Check: Equatable {
        let title, detail: String
        let ok: Bool
        var blocks = true
    }

    static func preflight(root: String, appleSilicon: Bool = isAppleSilicon, macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                          memory: UInt64 = ProcessInfo.processInfo.physicalMemory, free: Int64? = nil) -> [Check] {
        let gb = Int((Double(memory) / 1_073_741_824).rounded()), freeGB = Int((free ?? freeSpace(root)) / 1_000_000_000)
        return [
            Check(title: "Apple Silicon", detail: appleSilicon ? "This Mac has an M-series chip." : "MOSS Image needs a Mac with an M1 chip or later.", ok: appleSilicon),
            Check(title: "macOS 14 or later", detail: "This Mac runs macOS \(macOS.majorVersion).\(macOS.minorVersion).", ok: macOS.majorVersion >= 14),
            gb >= 24 ? Check(title: "Memory", detail: "\(gb) GB: both models fit. 8-bit gives the best pictures.", ok: true)
            : gb >= 16 ? Check(title: "Memory", detail: "\(gb) GB: the Compact model fits. The 8-bit model wants 24 GB.", ok: true)
            : Check(title: "Memory", detail: "\(gb) GB, under the 16 GB MOSS Image is made for. Use the Compact model; pictures may take much longer or fail.", ok: false, blocks: false),
            Check(title: "Free space", detail: freeGB >= 16 ? "\(freeGB) GB free." : "\(freeGB) GB free; the engine and the image model need 16 GB. Free up some space, then check again.",
                  ok: freeGB >= 16),
        ]
    }

    nonisolated static var isAppleSilicon: Bool {
        var arm = Int32(0), size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
    }

    /// Bytes free for `path`'s volume, from its nearest folder that exists.
    nonisolated static func freeSpace(_ path: String) -> Int64 {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

extension Notification.Name {
    /// EngineSetup finished: the main window's Generator picks up the new LoRA library.
    static let engineInstalled = Notification.Name("MossEngineInstalled")
}

extension EngineHome {
    /// moss-image-mlx's version from the venv's package metadata; nil when there is none.
    var version: String? {
        let venv = ((cli as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent, fm = FileManager.default
        for lib in (try? fm.contentsOfDirectory(atPath: venv + "/lib")) ?? [] {
            let site = venv + "/lib/" + lib + "/site-packages"
            if let d = ((try? fm.contentsOfDirectory(atPath: site)) ?? []).first(where: { $0.hasPrefix("moss_image_mlx-") && $0.hasSuffix(".dist-info") }) {
                return String(d.dropFirst("moss_image_mlx-".count).dropLast(".dist-info".count))
            }
        }
        return nil
    }
}

/// The first-run sheet (and Settings' Reinstall): the checks, then the three steps with progress, then what comes next.
struct SetupView: View {
    @ObservedObject var setup: EngineSetup
    var modelSize = Generator.tierSizes["compact"] ?? "12 GB"
    var checks: [EngineSetup.Check]? = nil   // nil: this Mac's
    @State private var recheck = 0   // Check Again: a new body runs the checks again
    @Environment(\.dismiss) private var dismiss

    private var reinstall: Bool { setup.reinstall }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reinstall ? "Reinstall the Image Engine" : "Set Up MOSS Image").font(.title2.weight(.semibold))
            switch setup.state {
            case .ready:
                Text(reinstall ? "Downloads and installs the engine again, about \(EngineSetup.download). The current engine keeps working until the new one is ready."
                               : "MOSS Image makes pictures on this Mac. First it installs its image engine, a download of about \(EngineSetup.download). This takes a few minutes.")
                    .fixedSize(horizontal: false, vertical: true)
                let checks = checks ?? EngineSetup.preflight(root: setup.root), blocked = checks.contains { !$0.ok && $0.blocks }
                VStack(alignment: .leading, spacing: 10) { ForEach(checks, id: \.title) { checkRow($0) } }.id(recheck)
                buttons {
                    if blocked { Button("Check Again") { recheck += 1 } }
                    Button(reinstall ? "Cancel" : "Not Now") { dismiss() }
                    Button(reinstall ? "Reinstall" : "Install") { Task { await setup.install() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(blocked)
                }
            case .running, .failed:
                VStack(alignment: .leading, spacing: 10) { ForEach(EngineSetup.Step.allCases, id: \.self) { stepRow($0) } }
                if case .failed(_, let message) = setup.state {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        Text(setup.errorText).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                    }
                    HStack {
                        Button("Copy Log", action: setup.copyLog)
                        Spacer()
                        Button(reinstall ? "Cancel" : "Not Now") { setup.state = .ready; dismiss() }
                        Button("Try Again") { Task { await setup.install() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                } else {
                    buttons { Button("Cancel", action: setup.cancel).keyboardShortcut(.cancelAction) }
                }
            case .done:
                Label { Text("The image engine is installed.") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Text("Your first picture also downloads the image model, \(modelSize). That happens once and can take a while.")
                    .fixedSize(horizontal: false, vertical: true)
                buttons { Button(reinstall ? "Done" : "Start") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(running)
    }

    private var running: Bool { if case .running = setup.state { true } else { false } }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { Spacer(); content() }.padding(.top, 4)
    }

    private func checkRow(_ c: EngineSetup.Check) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title)
                Text(c.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: c.ok ? "checkmark.circle.fill" : c.blocks ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(c.ok ? .green : c.blocks ? .red : .orange)
        }
    }

    private static let titles: [EngineSetup.Step: String] = [.python: "Python runtime", .packages: "Image engine and its libraries",
                                                              .adapter: "Adapter for quick drafts, 1.2 GB"]

    private func stepRow(_ s: EngineSetup.Step) -> some View {
        let current: EngineSetup.Step? = switch setup.state { case .running(let c), .failed(let c, _): c; default: nil }
        let failed = if case .failed = setup.state { true } else { false }
        let done = current.map { s.rawValue < $0.rawValue } ?? false, active = s == current
        return Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.titles[s]!).foregroundStyle(done || active ? .primary : .secondary)
                if active, !failed, let t = setup.transfer {
                    ProgressView(value: t.total > 0 ? t.done / t.total : 0)
                    Text(t.summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } icon: {
            if active && !failed { ProgressView().controlSize(.small) }
            else {
                Image(systemName: done ? "checkmark.circle.fill" : active ? "xmark.circle.fill" : "circle")
                    .foregroundStyle(done ? .green : active ? .red : .secondary)
            }
        }
    }
}
