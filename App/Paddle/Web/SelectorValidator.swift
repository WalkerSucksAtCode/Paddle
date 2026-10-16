import os
import WebKit

/// WebKit's parser, before selectors go into a content rule list. WebKit silently drops a whole
/// `css-display-none` rule when one selector is invalid, and `document.querySelector` throws on exactly
/// the selectors the compiler rejects (probe p2: 43/43 rejects, 300/300 accepts).
///
/// One windowless web view, made on first use, never navigated. Lives only while a changed list
/// compiles (`WebEnvironment.loadContentBlockers`); its WebContent process exits with it (CLI probe:
/// pid gone 0.3 s after drop). Any failure accepts every selector (the unvalidated conversion).
@MainActor
final class SelectorValidator {
    private let log = Logger(subsystem: "com.walker.Paddle", category: "web")
    private var webView: WKWebView?

    /// One Bool per selector: does WebKit's parser accept it? The whole batch goes in one script, so a list
    /// costs two round trips (every chunk, then the single selectors of the failing chunks).
    func validate(_ selectors: [String]) async -> [Bool] {
        guard !selectors.isEmpty else { return [] }
        let accept = Array(repeating: true, count: selectors.count)
        guard let data = try? JSONSerialization.data(withJSONObject: selectors) else { return accept }
        let script = """
        (function (a) { return a.map(s => { try { document.querySelector(s); return true } catch (e) { return false } }) })
        (\(String(decoding: data, as: UTF8.self)))
        """
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: .zero, configuration: configuration)
        }
        do {
            guard let answers = try await webView?.evaluateJavaScript(script) as? [Bool], answers.count == selectors.count else {
                log.error("selector check returned the wrong shape; accepting \(selectors.count) selectors unchecked")
                return accept
            }
            return answers
        } catch {
            log.error("selector check failed: \(String(describing: error), privacy: .public)")
            return accept
        }
    }
}
