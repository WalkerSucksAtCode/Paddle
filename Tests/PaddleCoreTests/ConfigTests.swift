import Foundation
@testable import PaddleCore
import Testing

struct ConfigTests {
    @Test func partialConfigKeepsDefaults() throws {
        let config = try PaddleConfig.decode(Data(#"{"maxAwakeTabs": 4, "searchTemplate": "https://kagi.com/search?q=%s"}"#.utf8))
        #expect(config.maxAwakeTabs == 4)
        #expect(config.searchTemplate == "https://kagi.com/search?q=%s")
        #expect(config.tabSleepAfterMinutes == PaddleConfig().tabSleepAfterMinutes)
        #expect(config.filterLists == PaddleConfig.defaultFilterLists)
    }

    @Test func roundTrips() throws {
        var config = PaddleConfig()
        config.shortcuts = ["newTab": "cmd+t"]
        config.siteUserAgents = ["example.com": "UA"]
        #expect(try PaddleConfig.decode(config.encoded()) == config)
    }

    @Test func errorNamesTheWrongKey() {
        #expect(throws: DecodingError.self) { try PaddleConfig.decode(Data(#"{"maxAwakeTabs": "four"}"#.utf8)) }
        do {
            _ = try PaddleConfig.decode(Data(#"{"maxAwakeTabs": "four"}"#.utf8))
        } catch {
            #expect(PaddleConfig.describe(error).hasPrefix("maxAwakeTabs:"))
        }
    }

    @Test func syntaxErrorSaysWhere() {
        do {
            _ = try PaddleConfig.decode(Data("{\n  \"maxAwakeTabs\": 4\n  \"homepage\": \"x\"\n}".utf8))
            Issue.record("missing comma should not parse")
        } catch {
            let text = PaddleConfig.describe(error)
            #expect(text.contains("line"), "\(text)")
        }
    }

    @Test func siteUserAgentMatchesLongestHostSuffix() {
        let config = PaddleConfig(siteUserAgents: ["example.com": "A", "app.example.com": "B"])
        #expect(config.userAgent(forHost: "www.example.com") == "A")
        #expect(config.userAgent(forHost: "app.example.com") == "B")
        #expect(config.userAgent(forHost: "x.app.example.com") == "B")
        #expect(config.userAgent(forHost: "notexample.com") == nil)
    }
}
