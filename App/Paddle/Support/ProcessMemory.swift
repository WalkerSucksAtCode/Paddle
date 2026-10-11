import Darwin
import Foundation
import WebKit

/// Per-tab memory: finds a web view's WebContent process and reads its physical footprint,
/// the same number Activity Monitor shows as "Memory".
enum ProcessMemory {
    /// `_webProcessIdentifier` is private WebKit API; this degrades to nil if it ever disappears.
    static func pid(of webView: WKWebView) -> pid_t? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let number = webView.value(forKey: "_webProcessIdentifier") as? NSNumber
        else { return nil }
        let pid = number.int32Value
        return pid > 0 ? pid : nil
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

    static func format(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}
