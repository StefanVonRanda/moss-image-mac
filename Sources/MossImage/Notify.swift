import AppKit
import UserNotifications

/// A batch that ends while the app is in the background posts a notification with the newest image; clicking it
/// brings the app forward on that image. Without permission, or outside an app bundle, the Dock icon bounces instead.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private weak var gen: Generator?

    /// Title and body for a finished batch: how many images arrived, or that it failed, and the prompt's first line.
    /// Nil when there is nothing to report (cancelled before any image).
    nonisolated static func content(count: Int, failed: Bool, prompt: String) -> (title: String, body: String)? {
        guard failed || count > 0 else { return nil }
        let line = prompt.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return (failed ? "Render failed" : count == 1 ? "Image ready" : "\(count) images ready", line)
    }

    /// `count` images arrived in the run that just ended; the newest is `gen.jobs.first`.
    func batchFinished(_ gen: Generator, count: Int, failed: Bool) {
        let newest = count > 0 ? gen.jobs.first : nil
        guard let (title, body) = Self.content(count: count, failed: failed, prompt: newest?.prompt ?? gen.prompt) else { return }
        // UNUserNotificationCenter.current() traps in a process without a bundle identifier (swift run, the checks)
        guard Bundle.main.bundleIdentifier != nil else { NSApp.requestUserAttention(.informationalRequest); return }
        self.gen = gen
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            // asks once; later calls return the stored answer without a prompt
            guard (try? await center.requestAuthorization(options: [.alert])) == true else {
                NSApp.requestUserAttention(.informationalRequest); return
            }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body
            if let newest {
                c.userInfo = ["path": newest.url.path]
                // an attachment's file is moved into the notification store: hand it a copy
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                if (try? FileManager.default.copyItem(at: newest.url, to: copy)) != nil,
                   let a = try? UNNotificationAttachment(identifier: "image", url: copy) { c.attachments = [a] }
            }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    /// Clicked: the app comes forward showing that image, as if its thumbnail had been clicked.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        await MainActor.run {
            NSApp.activate()
            guard let gen, let path, let job = gen.jobs.first(where: { $0.url.path == path }) else { return }
            gen.selected = job
            if gen.tab == "i2i" { gen.initImage = path }
        }
    }
}
