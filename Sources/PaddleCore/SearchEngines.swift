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
}
