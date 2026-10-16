import AppKit
import os
import QuartzCore

/// Times each tab switch stage by stage and logs one line per switch (category "switch"): mouse-down, mouse-up, the
/// tab's click handler, `activate`, the content view showing the page, and Core Animation committing that frame.
/// Read it with `log show --predicate 'subsystem == "com.walker.Paddle" AND category == "switch"' --info`.
@MainActor
enum SwitchTrace {
    private static let log = Logger(subsystem: "com.walker.Paddle", category: "switch")
    /// The last left mouse-down's event time (seconds since boot, as `NSEvent.timestamp`), from `TabDragController`.
    static var mouseDown: TimeInterval?
    private static var current: Trace?

    private struct Trace {
        var tab: UUID
        var down: TimeInterval?
        var up: TimeInterval?
        var tap: TimeInterval?
        var activated: TimeInterval?
        var state = ""
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A tab's click handler ran (on mouse-up).
    static func tapped(_ tab: Tab) {
        let up = NSApp.currentEvent.map(\.timestamp)
        current = Trace(tab: tab.id, down: mouseDown, up: up, tap: now)
    }

    /// `activate` finished for `tab`; `state` says whether its page was live, frozen or had to be created.
    static func activated(_ tab: Tab, state: String) {
        if current?.tab != tab.id { current = Trace(tab: tab.id) }
        current?.activated = now
        current?.state = state
    }

    /// The content view made `tab`'s page the visible one. Logs the line once that frame is committed.
    static func shown(_ tab: Tab) {
        guard var trace = current, trace.tab == tab.id else { return }
        current = nil
        let shown = now
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                let committed = now
                func ms(_ a: TimeInterval?, _ b: TimeInterval?) -> String {
                    guard let a, let b else { return "-" }
                    return String(format: "%.0f", (b - a) * 1000)
                }
                trace.state = trace.state.isEmpty ? "?" : trace.state
                log.info("switch \(trace.tab.uuidString.prefix(8), privacy: .public) [\(trace.state, privacy: .public)]: down→up \(ms(trace.down, trace.up), privacy: .public) ms, up→tap \(ms(trace.up, trace.tap), privacy: .public) ms, tap→activated \(ms(trace.tap, trace.activated), privacy: .public) ms, activated→shown \(ms(trace.activated, shown), privacy: .public) ms, shown→committed \(ms(shown, committed), privacy: .public) ms, total from up \(ms(trace.up ?? trace.activated, committed), privacy: .public) ms")
            }
        }
    }
}
