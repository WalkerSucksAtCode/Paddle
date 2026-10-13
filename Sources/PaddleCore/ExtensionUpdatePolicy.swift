import Foundation

/// When store-installed extensions are checked for updates (`extensionUpdates` in config.json). Each extension is judged
/// on its own record's `lastCheck`, once a day, and never while `extensionUpdates` is off (`FilterUpdatePolicy` does the
/// same for filter lists).
public enum ExtensionUpdatePolicy {
    /// Seconds between two store checks of one extension.
    public static let interval: TimeInterval = 86_400

    /// Whether an extension last asked its store at `lastCheck` (nil: never) should be asked again now.
    /// A date more than a day in the future means the clock was wrong when it was written, so the check is due.
    public static func shouldCheck(lastCheck: Date?, now: Date, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        if age < -interval { return true }
        return age >= interval
    }
}
