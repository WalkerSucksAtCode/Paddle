import Foundation
import PaddleCore
import Testing

struct SuggestedFeedsTests {
    @Test func everySuggestionIsAUniqueHTTPSAddress() {
        #expect(!SuggestedFeeds.all.isEmpty)
        #expect(SuggestedFeeds.urls.count == SuggestedFeeds.all.count)
        #expect(Set(SuggestedFeeds.all.map(\.name)).count == SuggestedFeeds.all.count)
        for feed in SuggestedFeeds.all {
            let url = URL(string: feed.url)
            #expect(url?.scheme == "https", "\(feed.name)")
            #expect(url?.host()?.contains(".") == true, "\(feed.name)")
            #expect(!feed.topic.isEmpty, "\(feed.name)")
        }
    }
}
