import Foundation

/// Startup without an unblocked gap: windows open at once, but a tab's first page load waits until the content
/// blockers are installed, or `timeout` has passed, whichever comes first. Lists still compiling after the timeout
/// install as they finish; pages that loaded before that reload once (`UnblockedReload`).
///
/// The timeout starts with `start()` or the first `wait()`, so a gate nobody starts still opens for its waiters.
@MainActor
public final class BlockerGate {
    public enum State: Equatable, Sendable {
        /// Not open: page loads wait.
        case waiting
        /// Opened by the timeout before every list was installed. Page loads go ahead; `markReady()` follows.
        case timedOut
        /// Every list is installed (or blocking is off).
        case ready
    }

    public private(set) var state: State = .waiting
    public let timeout: Duration
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var timer: Task<Void, Never>?

    public init(timeout: Duration = .seconds(3)) {
        self.timeout = timeout
    }

    /// Page loads may start: ready, or the timeout passed.
    public var isOpen: Bool { state != .waiting }
    /// Every list is installed; a page that commits now is blocked.
    public var isReady: Bool { state == .ready }

    /// Starts the timeout. Calling it again does nothing.
    public func start() {
        guard state == .waiting, timer == nil else { return }
        let timeout = timeout
        timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.timeOut()
        }
    }

    /// Returns once the gate is open (at once if it already is).
    public func wait() async {
        guard state == .waiting else { return }
        start()
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Every list is installed. Returns true when the timeout had already opened the gate, so pages may have
    /// loaded unblocked meanwhile.
    @discardableResult
    public func markReady() -> Bool {
        let late = state == .timedOut
        guard state != .ready else { return false }
        state = .ready
        timer?.cancel()
        timer = nil
        resumeWaiters()
        return late
    }

    private func timeOut() {
        timer = nil
        guard state == .waiting else { return }
        state = .timedOut
        resumeWaiters()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// Whether a tab whose page committed before the block lists were installed reloads once they are. Only once,
/// and never where a reload would cost the user something: a form post (reloading re-sends it), playing media
/// or a live camera/microphone, or text typed into the page.
public enum UnblockedReload {
    public enum Decision: Equatable, Sendable {
        case reload
        case skip(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case notUnblocked = "loaded with blockers"
        case post = "form post"
        case busy = "media or capture active"
        case typed = "text typed into the page"
    }

    /// `loadedUnblocked` is cleared by the caller once decided, so a second call for the same page sees false.
    public static func decide(loadedUnblocked: Bool, isPost: Bool, isBusy: Bool, userTyped: Bool) -> Decision {
        guard loadedUnblocked else { return .skip(.notUnblocked) }
        if isPost { return .skip(.post) }
        if isBusy { return .skip(.busy) }
        if userTyped { return .skip(.typed) }
        return .reload
    }

    /// Run in the page (an isolated world) to tell whether the user typed into it: a text field or text area whose
    /// value differs from the page's default, a changed checkbox or radio button, or focus in an editable region.
    /// A field filled by the page's own script also counts, which only means a reload is skipped.
    public static let typedProbeScript = """
    (() => {
      const active = document.activeElement;
      if (active && active.isContentEditable) return true;
      for (const field of document.querySelectorAll("input, textarea")) {
        if (field.type === "hidden") continue;
        // Sanitized to a default by the browser, so `value` differs from `defaultValue` without any typing.
        if (["range", "color", "file", "button", "submit", "reset", "image"].includes(field.type)) continue;
        if (field.type === "checkbox" || field.type === "radio") {
          if (field.checked !== field.defaultChecked) return true;
        } else if (field.value !== field.defaultValue) {
          return true;
        }
      }
      return false;
    })()
    """
}

/// EasyList and EasyPrivacy ship inside the app, so a first launch (nothing in `filters/`) blocks before any
/// download. A snapshot is copied into `filters/` only where that list's file is missing, dated by the list's own
/// `! Version:` line, so the normal update (`FilterUpdatePolicy`) replaces it once it is `filterUpdateDays` old.
public enum BundledFilterSnapshots {
    /// The snapshot file (in the app's `FilterSnapshots` resource folder) for a configured list, or nil when the
    /// list isn't one of the defaults. Same name as its file in `filters/`.
    public static func fileName(forList list: String) -> String? {
        guard PaddleConfig.defaultFilterLists.contains(list) else { return nil }
        return FilterUpdatePolicy.fileName(forList: list)
    }

    /// The `! Version: 202610121715` stamp (UTC) in the header, or nil when there is none in the first 40 lines.
    public static func versionDate(_ text: Substring) -> Date? {
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true).prefix(40) {
            guard line.hasPrefix("! Version:") else { continue }
            let stamp = line.dropFirst("! Version:".count).trimmingCharacters(in: .whitespaces)
            guard stamp.count == 12, stamp.allSatisfy(\.isASCII), stamp.allSatisfy(\.isNumber) else { return nil }
            var parts = DateComponents()
            let digits = Array(stamp)
            func number(_ range: Range<Int>) -> Int { Int(String(digits[range]))! }
            parts.year = number(0..<4)
            parts.month = number(4..<6)
            parts.day = number(6..<8)
            parts.hour = number(8..<10)
            parts.minute = number(10..<12)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard parts.isValidDate(in: calendar) else { return nil }
            return calendar.date(from: parts)
        }
        return nil
    }
}
