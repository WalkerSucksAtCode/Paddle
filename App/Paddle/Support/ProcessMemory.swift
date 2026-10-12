import Darwin
import Foundation
import PaddleCore
import WebKit

/// Memory of Paddle's processes: physical footprint, the same number Activity Monitor shows as "Memory".
enum ProcessMemory {
    /// Every WebContent process plus the shared GPU and Networking processes, as WebKit reports them.
    struct Snapshot {
        var webContent: [WebContentProcess<ObjectIdentifier>]
        /// The web view objects behind `webContent[*].views`, for the caller to work out owners.
        var webViews: [ObjectIdentifier: WKWebView]
        var gpu: UInt64?
        var networking: [UInt64]
        /// Pids of the GPU and Networking processes, so the helper scan doesn't count them again.
        var reported: Set<Int32>
    }

    /// `_webProcessIdentifier` is private WebKit API; this degrades to nil if it ever disappears.
    static func pid(of webView: WKWebView) -> pid_t? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let number = webView.value(forKey: "_webProcessIdentifier") as? NSNumber
        else { return nil }
        let pid = number.int32Value
        return pid > 0 ? pid : nil
    }

    /// Reads `+[WKProcessPool _webContentProcessInfo]`, `_gpuProcessInfo` and `_networkingProcessInfo` (private
    /// WebKit API, probed 2026-10: `_WKWebContentProcessInfo` has `pid`, `physicalFootprint`, `webViews`,
    /// `runningServiceWorkers`, `runningSharedWorkers`; the GPU call returns one `_WKProcessInfo`, the networking
    /// call an array). Nil when the WebContent call is missing, so callers fall back to `pid(of:)`.
    static func snapshot() -> Snapshot? {
        // By name, not `WKProcessPool.self`: the class is deprecated as a type, and a missing class degrades the same way.
        guard let pool = NSClassFromString("WKProcessPool") as? NSObject.Type else { return nil }
        let poolObject: AnyObject = pool
        func call(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard poolObject.responds(to: selector) else { return nil }
            return poolObject.perform(selector)?.takeUnretainedValue()
        }
        guard let infos = call("_webContentProcessInfo") as? [NSObject] else { return nil }

        var processes: [WebContentProcess<ObjectIdentifier>] = []
        var webViews: [ObjectIdentifier: WKWebView] = [:]
        for info in infos {
            guard let pid = int32(info, "pid"), pid > 0 else { continue }
            let views = (info.responds(to: NSSelectorFromString("webViews")) ? info.value(forKey: "webViews") as? [WKWebView] : nil) ?? []
            for view in views { webViews[ObjectIdentifier(view)] = view }
            processes.append(WebContentProcess(
                pid: pid,
                footprint: footprint(info) ?? footprint(of: pid) ?? 0,
                views: views.map(ObjectIdentifier.init),
                runsServiceWorkers: bool(info, "runningServiceWorkers"),
                runsSharedWorkers: bool(info, "runningSharedWorkers")
            ))
        }
        let gpuInfo = call("_gpuProcessInfo") as? NSObject
        let networkingInfos = (call("_networkingProcessInfo") as? [NSObject]) ?? []
        let reported = Set(([gpuInfo].compactMap { $0 } + networkingInfos).compactMap { int32($0, "pid") }.filter { $0 > 0 })
        return Snapshot(
            webContent: processes, webViews: webViews,
            gpu: gpuInfo.flatMap(footprint), networking: networkingInfos.compactMap(footprint), reported: reported
        )
    }

    // MARK: - Helpers outside WebKit's list

    /// `responsibility_get_pid_responsible_for_pid` (private libsystem call, probed 2026-10: it returns Paddle's
    /// pid for every WebKit process and helper Paddle launched, AutoFill and audio included). Looked up by name
    /// so a system without it just has no Helpers row.
    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: ResponsibleFor? = {
        // RTLD_DEFAULT: search every loaded image.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFor.self)
    }()

    /// The pids found by the last full scan and when it ran; listing every process costs about one call per pid
    /// on the system, so it runs at most every 30 s unless a readout is open.
    private static var helperPids: [pid_t] = []
    private static var lastHelperScan: Date?

    /// Footprints of every process Paddle is responsible for except Paddle itself, by pid; empty when the
    /// responsibility call is missing. `rescan` forces a fresh process list (an open readout wants new helpers
    /// at once); otherwise the cached pid list is re-measured and refreshed every 30 s.
    static func responsibleFootprints(rescan: Bool) -> [Int32: UInt64] {
        guard let responsibleFor else { return [:] }
        let me = getpid()
        if rescan || lastHelperScan.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            lastHelperScan = Date()
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { return [:] }
            // Room for processes started between the two calls.
            var pids = [pid_t](repeating: 0, count: Int(count) + 32)
            let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            helperPids = pids.prefix(Int(max(filled, 0))).filter { $0 > 0 && $0 != me && responsibleFor($0) == me }
        }
        var result: [Int32: UInt64] = [:]
        for pid in helperPids {
            if let bytes = footprint(of: pid) { result[pid] = bytes }
        }
        return result
    }

    /// `physicalFootprint` of a `_WKProcessInfo`; nil when the field is missing or the process has not reported yet.
    private static func footprint(_ info: NSObject) -> UInt64? {
        guard info.responds(to: NSSelectorFromString("physicalFootprint")),
              let bytes = (info.value(forKey: "physicalFootprint") as? NSNumber)?.uint64Value, bytes > 0
        else { return nil }
        return bytes
    }

    private static func int32(_ info: NSObject, _ key: String) -> Int32? {
        guard info.responds(to: NSSelectorFromString(key)) else { return nil }
        return (info.value(forKey: key) as? NSNumber)?.int32Value
    }

    private static func bool(_ info: NSObject, _ key: String) -> Bool {
        guard info.responds(to: NSSelectorFromString(key)) else { return false }
        return (info.value(forKey: key) as? NSNumber)?.boolValue ?? false
    }

    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// The UI process (Paddle itself).
    static func selfFootprint() -> UInt64? {
        footprint(of: getpid())
    }

    static func format(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}
