import WebKit

/// Opens Web Inspector on a web view through WebKit's private `_inspector` (personal build). Every step is checked
/// with `responds(to:)`, so if the API goes away nothing happens and `isAvailable` says so.
enum WebInspector {
    private static let inspectorKey = "_inspector"
    private static let showSelector = NSSelectorFromString("show")

    static func isAvailable(for webView: WKWebView) -> Bool {
        inspector(of: webView) != nil
    }

    /// True when the inspector was asked to show.
    @discardableResult
    static func show(_ webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView) else { return false }
        inspector.perform(showSelector)
        return true
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        guard webView.responds(to: NSSelectorFromString(inspectorKey)),
              let inspector = webView.value(forKey: inspectorKey) as? NSObject,
              inspector.responds(to: showSelector) else { return nil }
        return inspector
    }
}
