import os
import WebKit

/// Checks CSS selectors with WebKit's own parser before they go into a content rule list. WebKit silently drops a
/// `css-display-none` rule when one member of its selector list is invalid, taking the valid chunk-mates with
/// it, and `document.querySelector` throws on exactly the selectors the rule compiler rejects (probe p2 of the
/// weak-spot research: 43 of 43 rejects agree, 300 of 300 accepts agree).
///
/// One windowless web view, made on first use and never navigated: `querySelector` runs against its initial
/// empty document. Used only while a changed list compiles (`WebEnvironment.loadContentBlockers`), then
/// released; its WebContent process exits with it (a CLI probe saw the pid gone 0.3 s after the view was
/// dropped). Any failure accepts every selector, which is the unvalidated conversion.
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
