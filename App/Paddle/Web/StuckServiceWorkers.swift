import Foundation
import os
import PaddleCore
import WebKit

/// Stops WebKit's service workers when one holds a page's main request (`ServiceWorkerWatchdog` says when), so WebKit
/// sends the request to the network. Private `-[WKProcessPool _terminateServiceWorkers]`; without it nothing happens.
@MainActor
final class StuckServiceWorkers {
    static let shared = StuckServiceWorkers()
    private var watchdog = ServiceWorkerWatchdog()
    private let log = Logger(subsystem: "com.walker.Paddle", category: "web")

    /// Called once a main-frame navigation to `host` in `webView` has waited `ServiceWorkerWatchdog.patience`.
    /// `stillWaiting` is asked again after the registration lookup, which is asynchronous.
    func release(host: String, in webView: WKWebView, stillWaiting: () -> Bool) async {
        let records = await webView.configuration.websiteDataStore
            .dataRecords(ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations])
        guard stillWaiting(),
              watchdog.shouldStop(host: host, registeredSites: Set(records.map(\.displayName))) else { return }
        // KVC, not `processPool`: that property is deprecated. Tabs share `WebEnvironment.processPool`, so this stops every
        // site's workers; each starts again on its site's next request.
        guard let pool = webView.configuration.value(forKey: "processPool") as? NSObject,
              PrivateAPI.callVoid("_terminateServiceWorkers", on: pool) else {
            log.info("a service worker is holding \(host) but WebKit can't stop workers")
            return
        }
        log.info("a service worker held \(host) for \(Int(ServiceWorkerWatchdog.patience), privacy: .public) s: stopped service workers")
    }
}
