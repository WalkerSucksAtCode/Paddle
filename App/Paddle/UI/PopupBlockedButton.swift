import PaddleCore
import SwiftUI

/// Shown while the selected tab's page has had a window refused (`Tab.blockedPopups`): a popover lists them with Open,
/// and Always Allow Pop-ups on the site writes `sites.<host>.popups: true`.
struct PopupBlockedButton: View {
    let tab: Tab
    @State private var showing = false

    var body: some View {
        if !tab.blockedPopups.isEmpty {
            Button { showing.toggle() } label: {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .chromeFont(size: 13, weight: .medium)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Pop-up blocked")
            .accessibilityLabel("Pop-up blocked")
            .popover(isPresented: $showing, arrowEdge: .bottom) { popover.systemText() }
        }
    }

    private var host: String? { tab.url?.host() }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tab.blockedPopups.count == 1 ? "Pop-up blocked" : "\(tab.blockedPopups.count) pop-ups blocked").font(.headline)
            Text("This page tried to open a window without a click.").chromeFont(size: 11).foregroundStyle(.secondary)
            ForEach(tab.blockedPopups, id: \.self) { url in
                HStack {
                    Text(url.absoluteString).lineLimit(1).truncationMode(.middle).chromeFont(size: 12)
                    Spacer()
                    Button("Open") { open(url) }
                }
            }
            // Private windows write nothing to config.json's `sites`.
            if let host, !tab.isPrivate {
                Divider()
                Button("Always Allow Pop-ups on \(host)") {
                    let urls = tab.blockedPopups
                    showing = false
                    Task {
                        let app = AppModel.shared
                        await app.writeSiteSetting(.popups, .bool(true), forKey: tab.config.siteKey(forHost: host), profile: tab.profileID)
                        urls.forEach(open)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func open(_ url: URL) {
        tab.blockedPopups.removeAll { $0 == url }
        if tab.blockedPopups.isEmpty { showing = false }
        _ = tab.browser?.newTab(url: url, after: tab)
    }
}
