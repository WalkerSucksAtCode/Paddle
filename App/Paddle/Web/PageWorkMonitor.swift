import Foundation
import PaddleCore
import WebKit

/// Receives `PageWorkScript`'s reports and keeps them on the tab that owns the web view, so the sleep sweep can leave a
/// tab running while it uploads or guards unsaved changes. A page can only make its own tab look busy, which playing
/// sound already allows.
final class PageWorkMonitor: NSObject, WKScriptMessageHandler {
    static let shared = PageWorkMonitor()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == PageWorkScript.handlerName,
              let body = message.body as? [String: Any],
              let id = body["id"] as? String, id.count <= 64,
              let webView = message.webView,
              let tab = AppModel.shared.allTabs.first(where: { $0.webView === webView }) else { return }
        let work = Tab.PageWork(uploading: body["uploading"] as? Bool ?? false, guardsUnload: body["guardsUnload"] as? Bool ?? false)
        // Capped: a long-lived page posting distinct ids can't grow the browser-side dictionary without end.
        // A page needs a handful; past the cap the tab simply isn't marked busy by the extras.
        if work.isIdle {
            tab.pageWork[id] = nil
        } else if tab.pageWork.count < 64 {
            tab.pageWork[id] = work
        }
    }
}
