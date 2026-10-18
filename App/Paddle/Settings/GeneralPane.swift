import AppKit
import Combine
import PaddleCore
import SwiftUI

/// Settings > General: the pages new windows and tabs open with, the search engine and its suggestions, the
/// default browser and the bookmarks bar.
struct GeneralPane: View {
    let model: SettingsModel

    var body: some View {
        SettingsForm {
            Section("Startup & Windows") {
                Picker("When Paddle opens", selection: Binding(
                    get: { model.file.onLaunch },
                    set: { value in Task { await model.saveKey(.onLaunch, .string(value.rawValue)) } }
                )) {
                    Text("Restore last session").tag(LaunchBehavior.restore)
                    Text("Open a new window").tag(LaunchBehavior.newWindow)
                }
                .help("onLaunch in config.json. A new window replaces the saved session, pinned tabs included, once Paddle has started.")
                Picker("Links from other apps open in", selection: Binding(
                    get: { model.file.externalLinks },
                    set: { value in Task { await model.saveKey(.externalLinks, .string(value.rawValue)) } }
                )) {
                    Text("A new tab").tag(ExternalLinkTarget.newTab)
                    Text("A new window").tag(ExternalLinkTarget.newWindow)
                    Text("The current tab").tag(ExternalLinkTarget.currentTab)
                }
                .help("externalLinks in config.json. Links from Mail, Messages and other apps; never in a private window.")
                ConfigToggle("Ask before quitting", .askBeforeQuitting, \.askBeforeQuitting, model: model,
                             help: "⌘Q asks first while a window is open.")
                ConfigToggle("Ask before closing a window with several tabs", .askBeforeClosingWindow, \.askBeforeClosingWindow, model: model,
                             help: "Closing a window that has more than one tab asks first.")
            }
            .disabled(model.controlsDisabled)
            Section("Tabs") {
                Picker("New tabs open", selection: Binding(
                    get: { model.file.newTabPosition },
                    set: { value in Task { await model.saveKey(.newTabPosition, .string(value.rawValue)) } }
                )) {
                    Text("At the end").tag(NewTabPosition.end)
                    Text("Next to the current tab").tag(NewTabPosition.afterCurrent)
                }
                .help("newTabPosition in config.json. Where File > New Tab (⌘T) puts the tab. Links always open next to the tab they came from.")
                Picker("After closing a tab, show", selection: Binding(
                    get: { model.file.afterClosingTab },
                    set: { value in Task { await model.saveKey(.afterClosingTab, .string(value.rawValue)) } }
                )) {
                    Text("The tab to the right").tag(TabCloseSelection.right)
                    Text("The tab to the left").tag(TabCloseSelection.left)
                    Text("The last tab used").tag(TabCloseSelection.lastUsed)
                }
                .help("afterClosingTab in config.json. A pop-up you haven't left still goes back to the tab that opened it.")
                ConfigToggle("⌘-click opens links in the background", .openLinksInBackground, \.openLinksInBackground, model: model,
                             help: "On, ⌘-click and middle-click open a tab behind this one and ⌘⇧-click brings it to the front; off, the other way round.")
            }
            Section("Pages") {
                PageRows(model: model, key: .homepage, title: "New windows open with")
                PageRows(model: model, key: .newTabPage, title: "New tabs open with")
            }
            .disabled(model.controlsDisabled)
            Section("Search") {
                SearchRows(model: model)
            }
            .disabled(model.controlsDisabled)
            Section("Browser") {
                DefaultBrowserRow()
                Toggle("Show bookmarks bar", isOn: Binding(
                    get: { AppModel.shared.showBookmarksBar },
                    set: { AppModel.shared.showBookmarksBar = $0 }
                ))
                .help("View > Show Bookmarks Bar. Saved with the app's preferences, not in config.json. The bar shows once it has a bookmark.")
                Toggle("Show full website address", isOn: Binding(
                    get: { model.file.showFullAddress },
                    set: { value in Task { await model.saveKey(.showFullAddress, .bool(value)) } }
                ))
                .help("showFullAddress in config.json. Off, the address field shows only the site until you click it.")
                .disabled(model.controlsDisabled)
            }
            Section("New Tab") {
                NewTabExtensionRow(model: model)
                ConfigToggle("Show frequently visited sites", .newTabFrequentSites, \.newTabFrequentSites, model: model,
                             help: "A Frequently visited row on the New Tab page, from history; never in private windows.")
                ConfigToggle("Show website notifications", .newTabNotifications, \.newTabNotifications, model: model,
                             help: "The notifications sites sent since Paddle opened, newest first. Kept in memory only; never private windows'. Right-click one on New Tab to hide its site.")
                ForEach(model.file.newTabHiddenNotifications, id: \.self) { host in
                    LabeledContent {
                        Button("Show") {
                            let rest = model.file.newTabHiddenNotifications.filter { $0 != host }
                            Task { await model.saveKey(.newTabHiddenNotifications, .array(rest.map { .string($0) })) }
                        }
                        .disabled(model.controlsDisabled)
                    } label: {
                        Text(host)
                        Text("Hidden from New Tab's notifications").font(.caption).foregroundStyle(.secondary)
                    }
                    .help("newTabHiddenNotifications in config.json. Its banners still show; Settings > Sites decides those.")
                }
                FeedRows(model: model)
            }
            Section("Trackpad & Keyboard") {
                ConfigToggle("Swipe between pages", .swipeNavigation, \.swipeNavigation, model: model,
                             help: "Two-finger swipe goes back and forward.")
                ConfigToggle("Pinch to zoom", .pinchZoom, \.pinchZoom, model: model,
                             help: "Pinch zooms the page in and out; ⌘+ and ⌘− work either way.")
                ConfigToggle("Tab key highlights each item on a page", .tabKeyHighlightsLinks, \.tabKeyHighlightsLinks, model: model,
                             help: "Tab moves through links as well as fields and buttons. Pages opened afterwards pick it up.")
            }
            Section("Downloads") {
                LabeledContent("Save files to") {
                    HStack {
                        Text(DownloadStore.folderDisplayName(model.file.downloadFolder))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.prompt = "Choose"
                            panel.directoryURL = DownloadStore.folder
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            Task { await model.saveKey(.downloadFolder, .string(DownloadStore.configValue(for: url))) }
                        }
                    }
                }
                .help("downloadFolder in config.json. Empty: ~/Downloads.")
                .disabled(model.controlsDisabled)
                Toggle("Always ask where to save each file", isOn: Binding(
                    get: { model.file.askWhereToDownload },
                    set: { value in Task { await model.saveKey(.askWhereToDownload, .bool(value)) } }
                ))
                .help("askWhereToDownload in config.json. Prompts for a destination before downloading instead of saving straight to ~/Downloads.")
                .disabled(model.controlsDisabled)
            }
        }
    }
}

/// `newTabFeeds`: the feeds New Tab's News section lists, one row each with its problem if the last fetch failed, and a
/// field that takes a feed address or a site's (its `<link rel="alternate">` feed is found).
private struct FeedRows: View {
    let model: SettingsModel
    @State private var draft = ""
    @State private var adding = false
    @State private var problem: String?
    private var store: FeedStore { .shared }

    var body: some View {
        let feeds = model.file.newTabFeeds
        ForEach(feeds, id: \.self) { feed in
            LabeledContent {
                Button("Remove", role: .destructive) {
                    Task { await model.saveKey(.newTabFeeds, .array(feeds.filter { $0 != feed }.map { .string($0) })) }
                }
                .disabled(model.controlsDisabled)
            } label: {
                Text(URL(string: feed)?.host() ?? feed).lineLimit(1)
                if let problem = store.problems[feed] {
                    Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(feed).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        LabeledContent("Add a feed") {
            HStack {
                TextField("Feed", text: $draft, prompt: Text("Site or feed address"))
                    .labelsHidden()
                    .onSubmit(add)
                    .accessibilityLabel("Feed or site address")
                if adding {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking")
                } else {
                    Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .help("newTabFeeds in config.json. A site's address works when the site links its RSS or Atom feed.")
        .disabled(model.controlsDisabled)
        if let problem { ConfigIssueList(issues: [ConfigIssue(key: .newTabFeeds, severity: .error, message: problem)]) }
        if !feeds.isEmpty {
            LabeledContent("Stories") {
                Button(store.refreshing ? "Updating…" : "Update Now") { Task { await store.refresh(feeds: feeds) } }
                    .disabled(store.refreshing)
                    .help("Feeds update when a New Tab shows and the stories are over 30 minutes old. Fetched without cookies.")
            }
        }
    }

    private func add() {
        let typed = draft
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty, !adding else { return }
        adding = true
        problem = nil
        Task {
            defer { adding = false }
            switch await FeedStore.resolve(typed) {
            case .failure(let error): problem = error.message
            case .success(let url):
                let feeds = model.file.newTabFeeds
                guard !feeds.contains(url.absoluteString) else { problem = "That feed is already listed."; return }
                await model.saveKey(.newTabFeeds, .array((feeds + [url.absoluteString]).map { .string($0) }))
                draft = ""
            }
        }
    }
}

/// `newTabExtension`: Paddle's New Tab or the page of a running extension that brings one. Shown only while such an
/// extension runs (or one is chosen).
private struct NewTabExtensionRow: View {
    let model: SettingsModel

    private var candidates: [LoadedExtension] {
        guard let host = AppModel.shared.existingExtensions(for: model.profileID) else { return [] }
        return host.loaded.filter { $0.webExtension.hasOverrideNewTabPage && $0.context.overrideNewTabPageURL != nil }
    }

    var body: some View {
        let chosen = model.file.newTabExtension
        if !candidates.isEmpty || !chosen.isEmpty {
            Picker("New Tab page", selection: Binding(
                get: { chosen },
                set: { value in Task { await model.saveKey(.newTabExtension, .string(value)) } }
            )) {
                Text("Paddle's New Tab").tag("")
                ForEach(candidates) { ext in
                    Text(ext.displayName).tag(ext.name)
                }
                if !chosen.isEmpty, !candidates.contains(where: { $0.name == chosen }) {
                    Text("\(chosen) (not running)").tag(chosen)
                }
            }
            .help("newTabExtension in config.json: an extension's own New Tab page, by its folder name. It wins over New tabs open with; while that extension isn't running, Paddle's New Tab shows.")
            .disabled(model.controlsDisabled)
        }
    }
}

/// `homepage` or `newTabPage`: Empty Page (`about:blank`, the default) or an address typed here or taken from the
/// front window. What is typed is turned into a URL the way the address bar does ("example.com" becomes
/// https://example.com); anything ConfigValidator calls an error is not saved.
private struct PageRows: View {
    let model: SettingsModel
    let key: PaddleConfig.CodingKeys
    let title: String

    @State private var choosingPage = false
    @State private var draft = ""
    @State private var issues: [ConfigIssue] = []
    @FocusState private var focused: Bool

    private static let emptyPage = "about:blank"

    private var saved: String { key == .homepage ? model.file.homepage : model.file.newTabPage }
    private var showsPage: Bool { choosingPage || saved != Self.emptyPage }

    var body: some View {
        Picker(title, selection: Binding(get: { showsPage }, set: choose)) {
            Text("Empty Page").tag(false)
            Text("A Page").tag(true)
        }
        .help("\(key.rawValue) in config.json")
        .onAppear(perform: syncDraft)
        .onChange(of: saved) { syncDraft() }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        if showsPage {
            LabeledContent("Address") {
                HStack {
                    TextField("Address", text: $draft, prompt: Text("https://example.com"))
                        .labelsHidden()
                        .focused($focused)
                        .onSubmit(commit)
                        .accessibilityLabel("\(title): address")
                    Button("Use Current Page", action: useCurrentPage)
                        .disabled(currentPage == nil)
                        .help("Sets \(key.rawValue) to the page in the front browser window (not a private one).")
                }
            }
            .help("\(key.rawValue) in config.json")
            ConfigIssueList(issues: issues)
        }
    }

    private func syncDraft() {
        draft = saved == Self.emptyPage ? "" : saved
        if saved != Self.emptyPage { choosingPage = false }
    }

    private func choose(_ page: Bool) {
        issues = []
        if page {
            choosingPage = true
            return
        }
        choosingPage = false
        draft = ""
        Task { await model.saveKey(key, .string(Self.emptyPage)) }
    }

    /// The front normal window's page, when it is a web page worth opening again (`BrowserModel.currentPageTab`).
    private var currentPage: URL? {
        AppModel.shared.frontNormalWindow?.model.currentPageTab(schemes: ["http", "https", "file"])?.url
    }

    private func useCurrentPage() {
        guard let url = currentPage else { return }
        draft = url.absoluteString
        commit()
    }

    private func commit() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied field means "no page yet", not about:blank: the picker is how to choose Empty Page.
        guard !typed.isEmpty else {
            issues = []
            return
        }
        let value = Self.normalized(typed, searchTemplate: model.file.searchTemplate)
        let found = model.issues(for: key) { config in
            if key == .homepage { config.homepage = value } else { config.newTabPage = value }
        }
        issues = found
        guard value != saved, !found.contains(where: { $0.severity == .error }) else { return }
        draft = value
        Task { await model.saveKey(key, .string(value)) }
    }

    /// "example.com" → "https://example.com", as the address bar resolves it. Text the address bar would search for
    /// is left as typed, so the validator explains why it isn't a page.
    private static func normalized(_ text: String, searchTemplate: String) -> String {
        let resolver = AddressResolver(searchTemplate: searchTemplate)
        guard let url = resolver.resolve(text), url != resolver.searchURL(for: text) else { return text }
        return url.absoluteString
    }
}

/// `searchTemplate` and `searchSuggestTemplate`. A preset writes both (DuckDuckGo with suggestions on is the
/// default, so it removes both keys); Custom edits each URL, checked by ConfigValidator before it is saved.
private struct SearchRows: View {
    let model: SettingsModel

    private enum Field { case search, suggest }

    @State private var choosingCustom = false
    @State private var searchDraft = ""
    @State private var suggestDraft = ""
    @State private var searchIssues: [ConfigIssue] = []
    @State private var suggestIssues: [ConfigIssue] = []
    @FocusState private var focus: Field?

    private var preset: SearchEngine.Preset {
        if choosingCustom { return .custom }
        return SearchEngine.preset(searchTemplate: model.file.searchTemplate, suggestTemplate: model.file.searchSuggestTemplate)
    }

    private var suggestionsOn: Bool { !model.file.searchSuggestTemplate.isEmpty }

    var body: some View {
        Picker("Search engine", selection: Binding(get: { preset }, set: choose)) {
            ForEach(SearchEngine.presets) { engine in
                Text(engine.name).tag(engine.preset)
            }
            Divider()
            Text("Custom").tag(SearchEngine.Preset.custom)
        }
        .help("searchTemplate and searchSuggestTemplate in config.json")
        .onAppear {
            searchDraft = model.file.searchTemplate
            suggestDraft = model.file.searchSuggestTemplate
        }
        .onChange(of: model.file.searchTemplate) { _, value in
            searchDraft = value
            choosingCustom = false
        }
        .onChange(of: model.file.searchSuggestTemplate) { _, value in
            suggestDraft = value
            choosingCustom = false
        }
        .onChange(of: focus) { old, _ in
            switch old {
            case .search: commitSearch()
            case .suggest: commitSuggest()
            case nil: break
            }
        }

        if preset == .custom {
            LabeledContent("Search URL") {
                TextField("Search URL", text: $searchDraft, prompt: Text("https://example.com/search?q=%s"))
                    .labelsHidden()
                    .focused($focus, equals: .search)
                    .onSubmit(commitSearch)
                    .accessibilityLabel("Search URL")
            }
            .help("searchTemplate in config.json")
            ConfigIssueList(issues: searchIssues)
            LabeledContent("Suggestions URL") {
                TextField("Suggestions URL", text: $suggestDraft, prompt: Text("Empty: no suggestions"))
                    .labelsHidden()
                    .focused($focus, equals: .suggest)
                    .onSubmit(commitSuggest)
                    .accessibilityLabel("Suggestions URL")
            }
            .help("searchSuggestTemplate in config.json")
            ConfigIssueList(issues: suggestIssues)
            SettingsCaption("Put %s where the search words go. The suggestions URL must return OpenSearch or DuckDuckGo JSON; leave it empty to send nothing while you type.")
        } else {
            Toggle("Show search suggestions", isOn: Binding(get: { suggestionsOn }, set: setSuggestions))
                .help("searchSuggestTemplate in config.json (\"\" turns suggestions off)")
            SettingsCaption("Only search words typed key by key are sent to the search engine, never addresses, paths or pastes.")
        }
    }

    private func choose(_ preset: SearchEngine.Preset) {
        searchIssues = []
        suggestIssues = []
        guard let engine = SearchEngine.engine(for: preset) else {
            choosingCustom = true
            searchDraft = model.file.searchTemplate
            suggestDraft = model.file.searchSuggestTemplate
            return
        }
        choosingCustom = false
        // Turning suggestions off is its own choice; switching engines keeps it.
        let suggest = suggestionsOn ? engine.suggestTemplate : ""
        Task {
            await model.save([
                ConfigChange(PaddleConfig.CodingKeys.searchTemplate.rawValue, .string(engine.searchTemplate)),
                ConfigChange(PaddleConfig.CodingKeys.searchSuggestTemplate.rawValue, .string(suggest)),
            ])
        }
    }

    private func setSuggestions(_ on: Bool) {
        let engine = SearchEngine.engine(for: preset)
        let value = on ? (engine?.suggestTemplate ?? "") : ""
        Task { await model.saveKey(.searchSuggestTemplate, .string(value)) }
    }

    private func commitSearch() {
        let value = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        searchIssues = model.issues(for: .searchTemplate) { $0.searchTemplate = value }
        guard value != model.file.searchTemplate, !searchIssues.contains(where: { $0.severity == .error }) else { return }
        Task { await model.saveKey(.searchTemplate, .string(value)) }
    }

    private func commitSuggest() {
        let value = suggestDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestIssues = model.issues(for: .searchSuggestTemplate) { $0.searchSuggestTemplate = value }
        guard value != model.file.searchSuggestTemplate, !suggestIssues.contains(where: { $0.severity == .error }) else { return }
        Task { await model.saveKey(.searchSuggestTemplate, .string(value)) }
    }
}

/// Whether Paddle is the default browser, and the button that asks macOS to make it so. Re-checked whenever a
/// window becomes key, which is when macOS's confirmation has been answered.
private struct DefaultBrowserRow: View {
    @State private var isDefault = DefaultBrowser.isDefault

    var body: some View {
        LabeledContent("Default browser") {
            HStack {
                Label(
                    isDefault ? "Paddle is the default browser" : "Another browser is the default",
                    systemImage: isDefault ? "checkmark.circle.fill" : "circle"
                )
                if !isDefault {
                    Button("Make Default…") { DefaultBrowser.make() }
                        .disabled(!DefaultBrowser.isInstalled)
                        .help("Paddle > Make Paddle the Default Browser…")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isDefault = DefaultBrowser.isDefault
        }
        if !isDefault, !DefaultBrowser.isInstalled {
            SettingsCaption("Only a copy installed in /Applications can become the default browser.")
        }
    }
}
