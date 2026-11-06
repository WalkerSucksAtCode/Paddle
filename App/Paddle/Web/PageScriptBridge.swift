import Foundation
import os
import PaddleCore
import WebKit

/// Runs a content script's `<script src="extension-scheme://…">` in the page world.
///
/// The page's CSP (YouTube's `script-src` allowlist) blocks every extension scheme, so the element never loads.
/// The content prelude queues the URL on the document; the page-world bridge posts it here. Only a `.js` file the
/// manifest lists in `web_accessible_resources` is read from disk and evaluated. The page cannot supply the source.
final class PageScriptBridge: NSObject, WKScriptMessageHandler {
    static let shared = PageScriptBridge()
    static let handlerName = "paddlePageScript"

    private let log = Logger(subsystem: "com.walker.Paddle", category: "extensions")
    /// Pending runs per tab web view (same scale as `BridgeLimits.maxPendingCalls`); extras are dropped.
    private static let maxQueuedJobsPerWebView = 16
    private var queue: [Job] = []
    private var running = false
    private weak var runningWebView: WKWebView?

    private struct Job {
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let source: String
        let note: String
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString),
              let webView = message.webView,
              let path = ExtensionWebAccess.scriptPath(of: url),
              let ext = Self.owner(of: url),
              ExtensionWebAccess.isReachable(path: path, manifest: ext.webExtension.manifest, pageURL: message.frameInfo.request.url) else {
            log.error("refused a page-script request")
            return
        }
        if pendingCount(for: webView) >= Self.maxQueuedJobsPerWebView {
            log.error("page-script queue full for web view (\(Self.maxQueuedJobsPerWebView, privacy: .public) pending)")
            return
        }
        guard let code = Self.read(path, in: ext.entry.root) else {
            log.error("refused a page-script request")
            return
        }
        let source = Self.program(code: code, url: urlString, dataset: Self.dataset(body["dataset"], base: ext.baseURL))
        queue.append(Job(webView: webView, frame: message.frameInfo, source: source, note: "\(ext.name) \(path)"))
        drain()
    }

    private func pendingCount(for webView: WKWebView) -> Int {
        var count = queue.reduce(into: 0) { partial, job in
            if job.webView === webView { partial += 1 }
        }
        if running, runningWebView === webView { count += 1 }
        return count
    }

    private func drain() {
        guard !running, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        guard let webView = job.webView else {
            drain()
            return
        }
        running = true
        runningWebView = webView
        let note = job.note
        // A queued job's page may have been frozen since; scripts raise on a suspended page.
        Tab.owning(webView)?.unfreeze()
        webView.evaluateJavaScript(job.source, in: job.frame, in: .page) { result in
            if case .failure(let error) = result {
                self.log.error("page script failed (\(note, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            } else {
                self.log.info("page script ran (\(note, privacy: .public))")
            }
            self.running = false
            self.runningWebView = nil
            self.drain()
        }
    }

    private static func owner(of url: URL) -> LoadedExtension? {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        guard let scheme, let host else { return nil }
        return AppModel.shared.extensionHosts.flatMap(\.loaded).first { ext in
            ext.baseURL.scheme?.lowercased() == scheme && ext.urlHost.lowercased() == host
        }
    }

    /// Dataset the content script put on the element. An absolute URL has to be this extension's own origin,
    /// so a page that posts the handler itself cannot point the script at another site.
    private static func dataset(_ raw: Any?, base: URL) -> [String: String] {
        guard let raw = raw as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
                  let text = value as? String, !text.isEmpty, text.count <= 2_000 else { continue }
            if let target = URL(string: text), let scheme = target.scheme?.lowercased() {
                guard scheme == base.scheme?.lowercased(), target.host?.lowercased() == base.host?.lowercased() else { continue }
            }
            out[key] = text
        }
        return out
    }

    private static func read(_ path: String, in root: URL) -> String? {
        let base = root.standardizedFileURL
        let file = base.appending(path: path).standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard file.path.hasPrefix(prefix) else { return nil }
        guard let data = try? Data(contentsOf: file), !data.isEmpty, data.count <= 3_000_000,
              var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        return text
    }

    /// The file's source as a classic script, with `document.currentScript` pointing at an element that carries
    /// `dataset` for the duration of the run. Evaluated by WebKit in the page world, so the page CSP does not apply.
    private static func program(code: String, url: String, dataset: [String: String]) -> String {
        """
        try {
          var __paddleCurrent = document.createElement('script');
          try { __paddleCurrent.src = \(json(url)); } catch (e) {}
          var __paddleData = \(json(dataset));
          for (var __paddleKey in __paddleData) {
            if (Object.prototype.hasOwnProperty.call(__paddleData, __paddleKey)) {
              try { __paddleCurrent.dataset[__paddleKey] = String(__paddleData[__paddleKey]); } catch (e) {}
            }
          }
          var __paddleProto = Document.prototype;
          var __paddlePrev = Object.getOwnPropertyDescriptor(__paddleProto, 'currentScript');
          var __paddleHooked = false;
          try {
            Object.defineProperty(__paddleProto, 'currentScript', { configurable: true, get: function () { return __paddleCurrent; } });
            __paddleHooked = true;
          } catch (e) {}
          try {
            \(code)
          } finally {
            if (__paddleHooked) {
              try {
                if (__paddlePrev) Object.defineProperty(__paddleProto, 'currentScript', __paddlePrev);
                else delete __paddleProto.currentScript;
              } catch (e) {}
            }
          }
        } catch (e) { console.error(e); }
        """
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), var text = String(data: data, encoding: .utf8) else { return "null" }
        text = text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        text = text.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return text
    }
}
