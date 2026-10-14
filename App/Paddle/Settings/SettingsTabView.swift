import AppKit
import SwiftUI

/// Settings in a browser tab (`paddle://settings/<pane>`): a search field and a sidebar of panes over the selected
/// pane. The tab's address is the pane, so the address field and the session follow the sidebar.
struct SettingsTabView: View {
    let tab: Tab
    /// Made when the tab shows, not in `init`: SwiftUI rebuilds this struct on each pass of its parent, and each
    /// `SettingsModel()` reads config.json.
    @State private var model: SettingsModel?
    /// Watches config.json while the tab shows; cancelled when it hides.
    @State private var watcher: ConfigWatcher?
    @State private var search = ""

    /// The pane the tab shows (a settings tab always has one).
    private var selected: SettingsPane { tab.settingsPane ?? .general }
    private var matches: [SettingsPane] { SettingsPane.matching(search) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider()
            if let model {
                SettingsPaneView(pane: selected, model: model)
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            watcher?.cancel()
            watcher = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // A backstop for any edit the watcher missed; the stamp check makes it free when nothing changed.
            if (note.object as? NSWindow) === tab.window { model?.refresh() }
        }
        .onChange(of: search) { _, _ in
            // The sidebar lists only matches, so a search that leaves the shown pane out shows the first match.
            if let first = matches.first, !matches.contains(selected) { choose(first) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(10)
            List(selection: Binding(get: { tab.settingsPane }, set: { if let pane = $0 { choose(pane) } })) {
                ForEach(matches, id: \.self) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Settings panes")
            if matches.isEmpty {
                Text("No settings match")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $search)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search settings")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
    }

    /// Shows `pane` in this tab; its address, the session and the remembered pane follow.
    private func choose(_ pane: SettingsPane) {
        tab.browser?.showPane(pane, in: tab)
    }

    /// Makes the model on first show and starts watching config.json. Showing again re-reads the file too, since
    /// the tab may have been away while it changed.
    private func start() {
        let current = model ?? SettingsModel()
        model = current
        current.refresh()
        watcher = ConfigWatcher { current.refresh() }
    }
}
