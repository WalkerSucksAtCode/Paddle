import Foundation

/// One candidate page the address bar can suggest: an open tab, a bookmark or a history entry.
public struct SuggestionSource: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case openTab(UUID), bookmark, history }

    public var kind: Kind
    public var title: String
    public var url: String
    /// Caller-supplied base score: history frecency, 0 for tabs and bookmarks.
    public var score: Double

    public init(kind: Kind, title: String, url: String, score: Double = 0) {
        self.kind = kind
        self.title = title
        self.url = url
        self.score = score
    }
}

/// One row of the address-bar dropdown.
public struct Suggestion: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case openTab(UUID), bookmark, history, search, url }

    public var kind: Kind
    /// What the row shows first: the page title, the search phrase, or the URL for `.url` rows.
    public var title: String
    /// Second line: the display URL for pages, "Search" for search rows, "" for `.url` rows.
    public var detail: String
    /// Set for pages and `.url` rows.
    public var url: String?
    /// Set for search rows.
    public var query: String?
    /// Stable across keystrokes: a kind prefix plus the URL or query.
    public var id: String

    public init(kind: Kind, title: String, detail: String, url: String? = nil, query: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.url = url
        self.query = query
        let prefix: String
        switch kind {
        case .openTab: prefix = "tab"
        case .bookmark: prefix = "bookmark"
        case .history: prefix = "history"
        case .search: prefix = "search"
        case .url: prefix = "url"
        }
        self.id = prefix + ":" + (url ?? query ?? "")
    }
}

/// Ranks and completes address-bar suggestions from plain values. No history store, no WebKit.
public enum SuggestionRanker {
    /// Rows for the dropdown: at most `limit`, page matches first, then up to `maxSearch` search phrases.
    ///
    /// Every whitespace-separated word of `text` must match (case-insensitive) the title or the display URL,
    /// otherwise the page is left out. Pages are deduped by normalized URL and keep their best kind
    /// (open tab > bookmark > history). They are listed open tabs first, then bookmarks, then history; within
    /// a kind the order is:
    /// 1. host starts with the first word ("git" matches github.com),
    /// 2. a word of the title starts with the first word,
    /// 3. any other substring match,
    /// with ties broken by `score` descending, then shorter URL, then input order.
    /// Search phrases equal to the typed text (case-insensitive) or repeated are dropped.
    /// The page rows and search rows together are cut to `limit`, so a long page list can crowd search out.
    public static func suggestions(for text: String, pages: [SuggestionSource], searchPhrases: [String], limit: Int = 8, maxSearch: Int = 4) -> [Suggestion] {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard let first = words.first, limit > 0 else { return [] }

        // Best candidate per normalized URL.
        var best: [String: Candidate] = [:]
        for (index, page) in pages.enumerated() {
            let display = displayURL(page.url).lowercased()
            let title = page.title.lowercased()
            guard words.allSatisfy({ title.contains($0) || display.contains($0) }) else { continue }
            let candidate = Candidate(
                source: page,
                index: index,
                kindRank: kindRank(page.kind),
                quality: quality(of: first, title: title, display: display)
            )
            let key = normalized(page.url)
            if let existing = best[key], !candidate.beats(existing) { continue }
            best[key] = candidate
        }

        let rows = best.values.sorted { $0.sortsBefore($1) }.map { candidate -> Suggestion in
            let source = candidate.source
            let kind: Suggestion.Kind
            switch source.kind {
            case .openTab(let id): kind = .openTab(id)
            case .bookmark: kind = .bookmark
            case .history: kind = .history
            }
            let detail = displayURL(source.url)
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Suggestion(kind: kind, title: title.isEmpty ? detail : title, detail: detail, url: source.url)
        }

        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = [typed]
        var searches: [Suggestion] = []
        for phrase in searchPhrases {
            guard searches.count < maxSearch else { break }
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            searches.append(Suggestion(kind: .search, title: trimmed, detail: "Search", query: trimmed))
        }

        return Array((rows + searches).prefix(limit))
    }

    /// Safari-style inline completion. If `text` is a prefix of a candidate's host-and-path (scheme and a leading
    /// "www." ignored), returns the completed string in the candidate's lowercase form: "git" gives
    /// "github.com/". A match inside the host wins over a path match, then the shortest host, then the higher score.
    /// Returns nil when `text` is empty, contains whitespace, or matches nothing.
    /// If the typed text starts with "www." the result does too, so it still extends what was typed.
    public static func inlineCompletion(for text: String, pages: [SuggestionSource]) -> String? {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        var typed = text.lowercased()
        var wwwPrefix = ""
        if typed.hasPrefix("www.") {
            typed.removeFirst(4)
            wwwPrefix = "www."
        }
        guard !typed.isEmpty else { return nil }

        var bestMatch: (host: String, full: String, score: Double)?
        for page in pages {
            let (host, rest) = hostAndRest(page.url)
            let path = rest.hasPrefix("/") ? rest : ""
            let full = host + (path.isEmpty ? "/" : path)
            guard full.hasPrefix(typed) else { continue }
            // Typed text without a slash can only complete inside the host.
            if !typed.contains("/"), !host.hasPrefix(typed) { continue }
            let completion = typed.contains("/") ? full : host + "/"
            if let current = bestMatch {
                let better = host.count != current.host.count
                    ? host.count < current.host.count
                    : (page.score != current.score ? page.score > current.score : completion.count < current.full.count)
                if !better { continue }
            }
            bestMatch = (host, completion, page.score)
        }
        guard let match = bestMatch, match.full != typed else { return nil }
        return wwwPrefix + match.full
    }

    /// The URL as shown to people: no scheme, no leading "www.", and no trailing "/" on a bare host.
    public static func displayURL(_ url: String) -> String {
        let (host, rest) = hostAndRest(url, lowercaseHost: false)
        return rest == "/" ? host : host + rest
    }

    // MARK: Internals

    private struct Candidate {
        var source: SuggestionSource
        var index: Int
        var kindRank: Int
        var quality: Int

        /// Used when two pages share a URL: the better kind wins, then the higher score.
        func beats(_ other: Candidate) -> Bool {
            kindRank != other.kindRank ? kindRank < other.kindRank : source.score > other.source.score
        }

        func sortsBefore(_ other: Candidate) -> Bool {
            if kindRank != other.kindRank { return kindRank < other.kindRank }
            if quality != other.quality { return quality < other.quality }
            if source.score != other.source.score { return source.score > other.source.score }
            if source.url.count != other.source.url.count { return source.url.count < other.source.url.count }
            return index < other.index
        }
    }

    private static func kindRank(_ kind: SuggestionSource.Kind) -> Int {
        switch kind {
        case .openTab: 0
        case .bookmark: 1
        case .history: 2
        }
    }

    /// 0: host starts with the word. 1: a title word starts with it. 2: plain substring.
    private static func quality(of word: String, title: String, display: String) -> Int {
        let host = display.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if host.hasPrefix(word) { return 0 }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) }) { return 1 }
        return 2
    }

    /// Dedupe key: the lowercase display URL without any trailing slash.
    private static func normalized(_ url: String) -> String {
        var key = displayURL(url).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// Splits a URL into host (scheme and leading "www." removed) and the rest starting at the first "/", "?" or "#".
    /// With `lowercaseHost` (the default) both parts come back lowercased.
    private static func hostAndRest(_ url: String, lowercaseHost: Bool = true) -> (host: String, rest: String) {
        var s = Substring(url.trimmingCharacters(in: .whitespacesAndNewlines))
        if let range = s.range(of: "://") { s = s[range.upperBound...] }
        if s.lowercased().hasPrefix("www.") { s = s.dropFirst(4) }
        let split = s.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? s.endIndex
        let host = String(s[..<split])
        let rest = String(s[split...])
        return lowercaseHost ? (host.lowercased(), rest.lowercased()) : (host, rest)
    }
}

/// Helpers for the search engine's live-suggestion endpoint.
public enum SearchSuggestions {
    /// Replaces every `%s` in `template` with `query` percent-encoded as a query value (spaces become %20;
    /// `&`, `+`, `#` and non-ASCII are encoded). Nil when the template has no `%s` or the result is not a valid URL.
    public static func requestURL(template: String, query: String) -> URL? {
        guard template.contains("%s") else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// Phrases from a suggestion response, in order, without empty strings. Accepts the OpenSearch shape
    /// `["q", ["a", "b"], ...]` and the DuckDuckGo shape `[{"phrase": "a"}, ...]`. Anything else gives [].
    public static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], !json.isEmpty else { return [] }
        let raw: [String]
        if json.count >= 2, json[0] is String, let list = json[1] as? [Any] {
            raw = list.compactMap { $0 as? String }
        } else {
            raw = json.compactMap { ($0 as? [String: Any])?["phrase"] as? String }
        }
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
