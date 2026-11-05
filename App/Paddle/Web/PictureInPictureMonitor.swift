import Foundation
import PaddleCore
import WebKit

/// Receives `PictureInPictureScript` state so the sleep sweep keeps a PiP tab unfrozen.
final class PictureInPictureMonitor: NSObject, WKScriptMessageHandler {
    static let shared = PictureInPictureMonitor()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == PictureInPictureScript.handlerName,
              let body = message.body as? [String: Any],
              let active = body["active"] as? Bool,
              let webView = message.webView,
              let tab = AppModel.shared.allTabs.first(where: { $0.webView === webView }) else { return }
        tab.isInPictureInPicture = active
    }
}
