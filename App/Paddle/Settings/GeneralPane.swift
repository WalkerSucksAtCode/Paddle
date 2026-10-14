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

    /// The front normal window's page, when it is a web page worth opening again.
    private var currentPage: URL? {
        guard let url = AppModel.shared.frontNormalWindow?.model.selectedTab?.url,
              let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return url
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
