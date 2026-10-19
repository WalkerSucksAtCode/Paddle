import Foundation
import PaddleCore
import Testing

struct NewTabSectionTests {
    @Test func defaultOrderIsPinnedFrequentNotificationsNews() {
        #expect(PaddleConfig().newTabSectionOrder == [.pinned, .frequent, .notifications, .news])
    }

    @Test func orderKeepsTheListAndAppendsWhatItLeavesOut() {
        #expect(NewTabSection.order(["frequent", "pinned"]) == [.frequent, .pinned, .notifications, .news])
        #expect(NewTabSection.order(["news", "News", "bogus", " frequent "]) == [.news, .frequent, .pinned, .notifications])
        #expect(NewTabSection.order([]) == NewTabSection.allCases)
    }

    @Test func configFileSetsTheOrder() throws {
        let json = #"{"newTabSections": ["frequent", "pinned", "news"]}"#
        let config = try JSONDecoder().decode(PaddleConfig.self, from: Data(json.utf8))
        #expect(config.newTabSectionOrder == [.frequent, .pinned, .news, .notifications])
    }
}
