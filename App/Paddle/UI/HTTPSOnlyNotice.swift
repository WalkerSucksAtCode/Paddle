import SwiftUI
import PaddleCore

/// Shown in place of a page HTTPS-only mode wouldn't load over http://. Paddle's own view, so no page can press its
/// buttons.
struct HTTPSOnlyNotice: View {
    let tab: Tab
    let url: URL

    private var host: String { url.host(percentEncoded: false) ?? url.absoluteString }
    private var key: String {
        let normalized = PaddleConfig.normalizedHost(host)
        return normalized.hasPrefix("www.") ? String(normalized.dropFirst(4)) : normalized
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.slash")
                .chromeFont(size: 44)
                .foregroundStyle(.secondary)
            Text("\(host) doesn't offer a secure connection")
                .chromeFont(size: 17, weight: .semibold)
                .multilineTextAlignment(.center)
            Text("Paddle's HTTPS-only mode didn't load it over http://, where what you send and see can be read or changed on the way.")
                .chromeFont(size: 13)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Go Back", action: goBack)
                    .keyboardShortcut(.defaultAction)
                VStack(spacing: 2) {
                    Button("Continue to HTTP", action: continueOnce)
                    Text("until Paddle quits").chromeFont(size: 10).foregroundStyle(.secondary)
                }
                if !tab.isPrivate {
                    Button("Always Allow HTTP for \(host)") { Task { await alwaysAllow() } }
                }
            }
            .chromeFont(size: 13)
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Back to the page the tab was on (the refused load never replaced it), or the start page when there was none.
    private func goBack() {
        tab.httpsUpgrade = nil
        tab.httpsOnlyBlocked = nil
        tab.url = tab.webView?.url
    }

    private func continueOnce() {
        if tab.isPrivate {
            AppModel.shared.privateHTTPExceptions.insert(key)
        } else {
            AppModel.shared.httpExceptions[tab.profileID, default: []].insert(key)
        }
        tab.load(url)
    }

    private func alwaysAllow() async {
        let app = AppModel.shared
        let result = await app.writeSiteSetting(.httpsOnly, .bool(false), forKey: app.config.siteKey(forHost: host))
        if case .written = result {} else { app.httpExceptions[tab.profileID, default: []].insert(key) }
        tab.load(url)
    }
}
