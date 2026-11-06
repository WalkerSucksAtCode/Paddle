import Foundation

/// Who a web view belongs to, for attributing its WebContent process.
public enum ViewOwner: Hashable, Sendable {
    case tab(UUID)
    /// An extension's background page or popup (not a tab).
    case extensionView
}

/// One WebContent process as WebKit reports it: its footprint and the web views it hosts.
/// `View` is whatever identifies a web view to the caller (an object identity in the app, a plain value in tests).
public struct WebContentProcess<View: Hashable & Sendable>: Sendable {
    public var pid: Int32
    public var footprint: UInt64
    public var views: [View]
    public var runsServiceWorkers: Bool
    public var runsSharedWorkers: Bool

    public init(pid: Int32, footprint: UInt64, views: [View], runsServiceWorkers: Bool = false, runsSharedWorkers: Bool = false) {
        self.pid = pid
        self.footprint = footprint
        self.views = views
        self.runsServiceWorkers = runsServiceWorkers
        self.runsSharedWorkers = runsSharedWorkers
    }
}

/// Paddle's memory split into the rows the Activity popover shows. Every WebContent process lands in exactly one
/// row, so the rows add up to `total` together with the shared processes and the app itself.
public struct ProcessBreakdown: Equatable, Sendable {
    /// Processes hosting at least one tab's web view.
    public var tabs: UInt64 = 0
    /// Processes hosting only extension views (background pages, popups).
    public var extensions: UInt64 = 0
    /// Processes with no web view that run service or shared workers.
    public var serviceWorkers: UInt64 = 0
    /// GPU and Networking processes.
    public var shared: UInt64 = 0
    /// The UI process itself.
    public var app: UInt64 = 0
    /// WebContent processes with no attributable view and no workers: back-forward cache, prewarmed, exiting.
    /// `CachedWebProcess.reapable` is the large view-less subset the sweep drops; the prewarm spare stays.
    public var other: UInt64 = 0
    /// Processes macOS holds Paddle responsible for that WebKit didn't report: AutoFill, audio and other helpers
    /// (and, when WebKit's process list is unavailable, every WebContent process no tab claimed).
    public var helpers: UInt64 = 0
    /// Sum over the WebContent processes hosting each tab's view.
    public var perTab: [UUID: UInt64] = [:]
    /// Tabs whose process also hosts another tab, so `perTab` is a shared total.
    public var sharedTabs: Set<UUID> = []

    public var total: UInt64 { tabs + extensions + serviceWorkers + shared + app + other + helpers }

    public init() {}

    /// - Parameters:
    ///   - processes: every WebContent process; a repeated pid is counted once.
    ///   - owners: which tab or extension each known web view belongs to. Views absent from the map are unattributed.
    ///   - gpu: the GPU process footprint, if WebKit reported one.
    ///   - networking: footprints of the networking processes.
    ///   - app: the UI process footprint.
    ///   - helpers: footprints of every process Paddle is responsible for, by pid (the app itself left out).
    ///     Pids already counted, as WebContent processes or in `reported` (GPU, Networking), are skipped.
    ///   - reported: pids of the shared processes `gpu` and `networking` came from.
    public static func aggregate<View>(
        processes: [WebContentProcess<View>],
        owners: [View: ViewOwner],
        gpu: UInt64? = nil,
        networking: [UInt64] = [],
        app: UInt64? = nil,
        helpers: [Int32: UInt64] = [:],
        reported: Set<Int32> = []
    ) -> ProcessBreakdown {
        var result = ProcessBreakdown()
        var seen: Set<Int32> = []
        for process in processes where seen.insert(process.pid).inserted {
            var tabIDs: Set<UUID> = []
            var hasExtensionView = false
            for view in process.views {
                switch owners[view] {
                case .tab(let id): tabIDs.insert(id)
                case .extensionView: hasExtensionView = true
                case nil: break
                }
            }
            if !tabIDs.isEmpty {
                result.tabs += process.footprint
                for id in tabIDs { result.perTab[id, default: 0] += process.footprint }
                if tabIDs.count > 1 { result.sharedTabs.formUnion(tabIDs) }
            } else if hasExtensionView {
                result.extensions += process.footprint
            } else if process.runsServiceWorkers || process.runsSharedWorkers {
                result.serviceWorkers += process.footprint
            } else {
                result.other += process.footprint
            }
        }
        result.shared = (gpu ?? 0) + networking.reduce(0, +)
        result.app = app ?? 0
        for (pid, footprint) in helpers where !seen.contains(pid) && !reported.contains(pid) {
            result.helpers += footprint
        }
        return result
    }

    /// Every figure rounded to the nearest `unit` (whole MB by default), so a sampler can skip assigning a
    /// breakdown that only moved by a few pages and leave the views showing it alone.
    public func rounded(toMultipleOf unit: UInt64 = 1_048_576) -> ProcessBreakdown {
        func round(_ bytes: UInt64) -> UInt64 { (bytes + unit / 2) / unit * unit }
        var result = self
        result.tabs = round(tabs)
        result.extensions = round(extensions)
        result.serviceWorkers = round(serviceWorkers)
        result.shared = round(shared)
        result.app = round(app)
        result.other = round(other)
        result.helpers = round(helpers)
        result.perTab = perTab.mapValues(round)
        return result
    }
}

/// Which view-less WebContent processes are leftovers rather than the idle prewarm spare.
/// A breakdown's `other` row also includes processes whose views nobody claimed; those still have views, so they stay.
public enum CachedWebProcess {
    /// `_warmInitialProcess` leaves one idle WebContent process of about 7 MB. View-less processes at or below
    /// this stay: that spare, and site-isolation or card frames (often 20–40 MB). A leftover the size of a
    /// previous document (hundreds of MB) is above it, and the sweep may drop it.
    public static let spareCeiling: UInt64 = 128 * 1_048_576

    /// Processes the memory sweep may drop: no web view, no service or shared worker, footprint above `spareCeiling`.
    public static func reapable<View>(
        _ processes: [WebContentProcess<View>],
        spareCeiling: UInt64 = CachedWebProcess.spareCeiling
    ) -> [WebContentProcess<View>] {
        processes.filter { process in
            process.views.isEmpty
                && !process.runsServiceWorkers
                && !process.runsSharedWorkers
                && process.footprint > spareCeiling
        }
    }
}
