import AppKit
import PaddleCore
import SwiftUI

/// The address-bar dropdown for one window: first the row Return would open, then matching open tabs and
/// history, then the search engine's suggestions, which arrive a moment later.
@Observable
final class AddressSuggestions {
    private(set) var rows: [Suggestion] = []
    var highlighted = 0

    @ObservationIgnored private var text = ""
    /// What Return acts on: the typed text, or the text after an inline completion.
    @ObservationIgnored private var fieldText = ""
    @ObservationIgnored private var pages: [SuggestionSource] = []
    @ObservationIgnored private var phrases: [String] = []
    @ObservationIgnored private var phrasesQuery = ""
    @ObservationIgnored private var fetch: Task<Void, Never>?

    /// Suggestion requests send and keep no cookies and cache nothing.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + WebEnvironment.safariApplicationName

    var isVisible: Bool { !rows.isEmpty }
    /// What the user typed, without any inline completion.
    var typedText: String { text }
    var highlightedRow: Suggestion? { rows.indices.contains(highlighted) ? rows[highlighted] : nil }

    /// Recomputes rows for what is in the field and asks the search engine for phrases.
    func update(for text: String, in browser: BrowserModel) {
        let previous = self.text
        self.text = text
        fieldText = text
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            dismiss()
            return
        }
        // Phrases for "padd" still help while "paddl" is on its way; unrelated ones don't.
        if !query.lowercased().hasPrefix(phrasesQuery.lowercased()) { phrases = [] }
        pages = Self.candidatePages(for: query, excluding: browser.selectedTab, in: browser)
        // New text starts at the top row; only arriving search phrases keep a moved highlight.
        highlighted = 0
        rebuild()
        if Self.mayAskSearchEngine(query, previous: previous) {
            fetchPhrases(for: query)
        } else {
            fetch?.cancel()
            phrases = []
            rebuild()
        }
    }

    /// Only what would be searched anyway, typed a key or two at a time, goes to the search engine: never an
    /// address, a path, anything with credentials, or a paste (which might be a password or token).
    private static func mayAskSearchEngine(_ query: String, previous: String) -> Bool {
        guard primaryRow(for: query).kind == .search,
              !query.contains("://"), !query.contains("@"),
              !query.hasPrefix("/"), !query.hasPrefix("~") else { return false }
        let typed = query.count <= 2
            || (query.hasPrefix(previous) && query.count - previous.count <= 2)
            || previous.hasPrefix(query)
        return typed
    }

    /// Safari-style completion of a typed host prefix ("git" -> "github.com/"), from open tabs and history.
    func inlineCompletion(for text: String) -> String? {
        SuggestionRanker.inlineCompletion(for: text, pages: pages)
    }

    /// The field now holds a completed address; the top row follows it, matches still follow what was typed.
    func completionApplied(_ completed: String) {
        fieldText = completed
        rebuild()
    }

    /// Moves the arrow-key highlight and announces the row, since VoiceOver stays in the address field.
    func moveHighlight(by delta: Int) {
        guard !rows.isEmpty else { return }
        let previous = highlighted
        highlighted = min(max(highlighted + delta, 0), rows.count - 1)
        if highlighted != previous, let row = highlightedRow {
            AccessibilityNotification.Announcement("\(row.spokenDescription), \(highlighted + 1) of \(rows.count)").post()
        }
    }

    func dismiss() {
        rows = []
        highlighted = 0
        fetch?.cancel()
        fetch = nil
    }

    private func rebuild() {
        let previous = highlightedRow?.id
        let primary = Self.primaryRow(for: fieldText)
        // At most 6 pages, so search phrases always keep their rows.
        let ranked = SuggestionRanker.suggestions(for: text, pages: pages, searchPhrases: phrases, limit: 14, maxSearch: 4)
            // A history row for the very page the top row opens is redundant; an open tab of it is not.
            .filter { row in
                if row.id == primary.id { return false }
                if case .openTab = row.kind { return true }
                return row.url == nil || row.url != primary.url
            }
        let pageRows = ranked.filter { $0.kind != .search }.prefix(6)
        rows = [primary] + pageRows + ranked.filter { $0.kind == .search }
        // Search phrases arrive while the user may be arrowing through the list; keep their place.
        highlighted = rows.firstIndex { $0.id == previous } ?? 0
    }

    private func fetchPhrases(for query: String) {
        fetch?.cancel()
        let template = AppModel.shared.config.searchSuggestTemplate
        guard !template.isEmpty, let url = SearchSuggestions.requestURL(template: template, query: query) else {
            phrases = []
            return
        }
        fetch = Task { [weak self] in
            // Typing fast sends one request per pause, not one per key.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            // DuckDuckGo answers an empty body to agents that aren't browsers.
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await Self.session.data(for: request), !Task.isCancelled, let self, self.isVisible else { return }
            self.phrases = SearchSuggestions.parse(data)
            self.phrasesQuery = query
            self.rebuild()
        }
    }

    /// Open tabs, bookmarks and history. History is only read here, private windows included. A private window's
    /// tabs are offered only in that window.
    private static func candidatePages(for query: String, excluding current: Tab?, in browser: BrowserModel) -> [SuggestionSource] {
        let app = AppModel.shared
        var pages: [SuggestionSource] = app.allTabs.compactMap { tab in
            guard tab !== current, !tab.isPrivate || tab.browser === browser,
                  let url = tab.url, HistoryStore.isRecordable(url) else { return nil }
            return SuggestionSource(kind: .openTab(tab.id), title: tab.displayTitle, url: url.absoluteString)
        }
        pages += app.bookmarks.tree.search(query).prefix(20).compactMap { bookmark in
            bookmark.url.map { SuggestionSource(kind: .bookmark, title: bookmark.title, url: $0) }
        }
        let now = Date()
        if let entries = try? app.history?.search(query, limit: 30, now: now) {
            pages += entries.map {
                SuggestionSource(
                    kind: .history, title: $0.title, url: $0.url,
                    score: Frecency.score(visitCount: $0.visitCount, typedCount: $0.typedCount, lastVisit: $0.lastVisit, now: now)
                )
            }
        }
        return pages
    }

    /// What pressing Return does with the text: go to it when it looks like an address, otherwise search.
    private static func primaryRow(for text: String) -> Suggestion {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = AppModel.shared.config.searchTemplate
        let resolver = AddressResolver(searchTemplate: template)
        if let url = resolver.resolve(query), url != resolver.searchURL(for: query) {
            return Suggestion(kind: .url, title: SuggestionRanker.displayURL(url.absoluteString), detail: "", url: url.absoluteString, query: nil)
        }
        let engine = URL(string: template.replacingOccurrences(of: "%s", with: ""))?.host().map(SuggestionRanker.displayURL) ?? "the web"
        return Suggestion(kind: .search, title: query, detail: "Search \(engine)", url: nil, query: query)
    }
}

/// The dropdown under the address field.
struct SuggestionList: View {
    let suggestions: AddressSuggestions
    let choose: (Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.rows.enumerated()), id: \.element.id) { index, row in
                SuggestionRow(row: row, highlighted: index == suggestions.highlighted)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // Passing the pointer over a row must not leave it chosen for Return.
                        if inside {
                            suggestions.highlighted = index
                        } else if suggestions.highlighted == index {
                            suggestions.highlighted = 0
                        }
                    }
                    .onTapGesture { choose(row) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.spokenDescription)
                    .accessibilityAddTraits(index == suggestions.highlighted ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { choose(row) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private struct SuggestionRow: View {
    let row: Suggestion
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let url = row.url.flatMap(URL.init(string:)), row.kind != .url {
                    FaviconView(url: url, fallback: icon, size: 14, fallbackStyle: highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 8)
            if case .openTab = row.kind {
                Text("Switch to Tab")
                    .font(.system(size: 11))
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: row.detail.isEmpty ? 28 : 36)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear)))
    }

    private var icon: String {
        switch row.kind {
        case .openTab: "square.on.square"
        case .bookmark: "star"
        case .history: "clock"
        case .search: "magnifyingglass"
        case .url: "globe"
        }
    }
}

extension Suggestion {
    /// What VoiceOver says for the row: its kind, then its text.
    var spokenDescription: String {
        let parts: [String] = switch kind {
        case .openTab: ["Switch to tab", title, detail]
        case .bookmark: ["Bookmark", title, detail]
        case .history: ["History", title, detail]
        case .search: [title, detail]
        case .url: ["Go to", title]
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
