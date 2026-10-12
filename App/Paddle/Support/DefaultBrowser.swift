import AppKit
import os

/// Paddle > Make Paddle the Default Browser…. macOS asks the user to confirm the change; Paddle only asks for it.
enum DefaultBrowser {
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "app")
    private static let probe = URL(string: "https://example.com")!

    /// Launch Services records the default browser by bundle identifier, so this is true for any copy of Paddle.
    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Only the installed copy may become the default, so a debug build run from DerivedData never claims links.
    static var isInstalled: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
    }

    /// CocoaError.userCancelled (NSUserCancelledError, 3072) or the Carbon userCanceledErr (-128).
    private static func isCancellation(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
            || (error.domain == NSOSStatusErrorDomain && error.code == -128)
    }

    static func make() {
        guard isInstalled else {
            let alert = NSAlert()
            alert.messageText = "Install Paddle in Applications first"
            alert.informativeText = "This copy runs from \(Bundle.main.bundleURL.deletingLastPathComponent().path). "
                + "Install Paddle in /Applications (scripts/release.sh --install), open it from there, "
                + "then choose Make Paddle the Default Browser again."
            alert.runModal()
            return
        }
        let app = Bundle.main.bundleURL
        Task {
            do {
                for scheme in ["http", "https"] {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
                }
                log.info("default browser set to \(app.path, privacy: .public)")
            } catch {
                let ns = error as NSError
                log.error("default browser change failed: \(ns.domain, privacy: .public) \(ns.code): \(ns.localizedDescription, privacy: .public)")
                // Declining macOS's confirmation is not an error worth an alert. The exact error for "Keep…" is not
                // confirmed, so accept both cancellation codes and never alert once Paddle did become the default.
                if isCancellation(ns) || isDefault { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Paddle couldn't become the default browser"
                alert.informativeText = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
                alert.runModal()
            }
        }
    }
}
