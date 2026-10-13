import Foundation

/// The search engines the Settings picker offers. Each pairs a search URL with a suggestion endpoint that returns
/// the OpenSearch `["q", [...]]` shape `SearchSuggestions.parse` reads (every endpoint was checked by hand).
public struct SearchEngine: Sendable, Equatable, Identifiable {
    public enum Preset: String, Sendable, CaseIterable {
        case duckDuckGo, google, bing, brave, kagi, ecosia
        /// Templates that match no preset: the user typed their own.
        case custom
    }

    public var preset: Preset
    public var name: String
    /// Search URL with `%s` for the query, as `searchTemplate`.
    public var searchTemplate: String
    /// Suggestion endpoint with `%s` for the typed text, as `searchSuggestTemplate`.
    public var suggestTemplate: String

    public var id: Preset { preset }

    /// The built-in engines in picker order; DuckDuckGo first because it is the default. Custom is not an engine.
    public static let presets: [SearchEngine] = [
        SearchEngine(
            preset: .duckDuckGo, name: "DuckDuckGo",
            searchTemplate: "https://duckduckgo.com/?q=%s",
            suggestTemplate: "https://duckduckgo.com/ac/?q=%s&type=list"
        ),
        SearchEngine(
            preset: .google, name: "Google",
            searchTemplate: "https://www.google.com/search?q=%s",
            suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
        ),
        SearchEngine(
            preset: .bing, name: "Bing",
            searchTemplate: "https://www.bing.com/search?q=%s",
            suggestTemplate: "https://api.bing.com/osjson.aspx?query=%s"
        ),
        SearchEngine(
            preset: .brave, name: "Brave",
            searchTemplate: "https://search.brave.com/search?q=%s",
            suggestTemplate: "https://search.brave.com/api/suggest?q=%s"
        ),
        SearchEngine(
            preset: .kagi, name: "Kagi",
            searchTemplate: "https://kagi.com/search?q=%s",
            suggestTemplate: "https://kagi.com/api/autosuggest?q=%s"
        ),
        SearchEngine(
            preset: .ecosia, name: "Ecosia",
            searchTemplate: "https://www.ecosia.org/search?q=%s",
            suggestTemplate: "https://ac.ecosia.org/autocomplete?q=%s&type=list"
        ),
    ]

    /// The engine for a preset; nil for `.custom`.
    public static func engine(for preset: Preset) -> SearchEngine? {
        presets.first { $0.preset == preset }
    }

    /// Which preset a config's templates are: the search URL must match, and the suggestion endpoint must be the
    /// preset's own or empty (suggestions turned off). Anything else is `.custom`.
    public static func preset(searchTemplate: String, suggestTemplate: String) -> Preset {
        let search = searchTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggest = suggestTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first { $0.searchTemplate == search && (suggest.isEmpty || $0.suggestTemplate == suggest) }?
            .preset ?? .custom
    }

    // MARK: - Recognizing another browser's engine

    /// Words an engine's name or identifier may carry besides the name itself: "com.google.www", "Brave Search".
    private static let nameNoise: Set<String> = ["com", "www", "org", "net", "search", "engine", "safari", "apple", "mozilla"]

    private static let nameAliases: [String: Preset] = [
        "duckduckgo": .duckDuckGo, "ddg": .duckDuckGo, "google": .google, "bing": .bing,
        "brave": .brave, "kagi": .kagi, "ecosia": .ecosia,
    ]

    /// The preset an engine name or identifier ("DuckDuckGo", "com.google.www", "google@search.mozilla.org") names.
    /// Everything besides the name must be noise: "Google Scholar" is not Google.
    public static func preset(named name: String) -> Preset? {
        let tokens = name.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !nameNoise.contains($0) }
        guard tokens.count == 1 else { return nil }
        return nameAliases[tokens[0]]
    }

    /// The preset a search URL (`{searchTerms}`, `%s` or `%S` for the query) belongs to, judged by host and path:
    /// `https://www.google.com/search?q=…` is Google, `https://scholar.google.com/scholar?q=…` is not.
    public static func preset(forSearchURL template: String) -> Preset? {
        let probe = template
            .replacingOccurrences(of: "{searchTerms}", with: "x")
            .replacingOccurrences(of: "%s", with: "x")
            .replacingOccurrences(of: "%S", with: "x")
        guard let parts = URLComponents(string: probe), parts.scheme == "https" || parts.scheme == "http",
              var host = parts.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = parts.path.isEmpty ? "/" : parts.path
        // google.com, google.de, google.co.uk, google.com.au; not google.evil.com.
        let labels = host.split(separator: ".")
        if labels.first == "google", path == "/search",
           labels.count == 2 || (labels.count == 3 && ["co", "com"].contains(labels[1])) { return .google }
        switch (host, path) {
        case ("duckduckgo.com", "/"): return .duckDuckGo
        case ("bing.com", "/search"): return .bing
        case ("search.brave.com", "/search"): return .brave
        case ("kagi.com", "/search"): return .kagi
        case ("ecosia.org", "/search"): return .ecosia
        default: return nil
        }
    }
}
