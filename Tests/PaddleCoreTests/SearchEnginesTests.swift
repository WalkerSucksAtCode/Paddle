@testable import PaddleCore
import Testing

struct SearchEnginesTests {
    @Test func presetsAreDistinctWebTemplatesWithPlaceholders() {
        let presets = SearchEngine.presets
        #expect(presets.map(\.preset) == [.duckDuckGo, .google, .bing, .brave, .kagi, .ecosia])
        #expect(Set(presets.map(\.searchTemplate)).count == presets.count)
        for engine in presets {
            #expect(engine.searchTemplate.hasPrefix("https://") && engine.searchTemplate.contains("%s"), "\(engine.name)")
            #expect(SearchSuggestions.requestURL(template: engine.suggestTemplate, query: "a b") != nil, "\(engine.name)")
        }
        #expect(SearchEngine.engine(for: .custom) == nil)
    }

    @Test func defaultConfigIsDuckDuckGo() {
        let config = PaddleConfig()
        #expect(SearchEngine.preset(searchTemplate: config.searchTemplate, suggestTemplate: config.searchSuggestTemplate) == .duckDuckGo)
        let ddg = SearchEngine.engine(for: .duckDuckGo)
        #expect(ddg?.searchTemplate == config.searchTemplate)
        #expect(ddg?.suggestTemplate == config.searchSuggestTemplate)
    }

    @Test func matchesPresetWithSuggestionsOff() {
        let google = SearchEngine.engine(for: .google)!
        #expect(SearchEngine.preset(searchTemplate: google.searchTemplate, suggestTemplate: "") == .google)
        #expect(SearchEngine.preset(searchTemplate: " \(google.searchTemplate)\n", suggestTemplate: google.suggestTemplate) == .google)
    }

    @Test func mixedOrUnknownTemplatesAreCustom() {
        let google = SearchEngine.engine(for: .google)!
        let bing = SearchEngine.engine(for: .bing)!
        #expect(SearchEngine.preset(searchTemplate: google.searchTemplate, suggestTemplate: bing.suggestTemplate) == .custom)
        #expect(SearchEngine.preset(searchTemplate: "https://example.com/?q=%s", suggestTemplate: "") == .custom)
    }
}
