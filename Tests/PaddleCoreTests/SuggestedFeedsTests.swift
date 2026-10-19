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

    @Test func everySuggestedNotifierIsAPlainNormalizedHost() {
        #expect(Set(SuggestedNotifiers.all.map(\.host)).count == SuggestedNotifiers.all.count)
        for site in SuggestedNotifiers.all {
            #expect(PaddleConfig.isPlainHost(site.host), "\(site.name)")
            #expect(PaddleConfig.normalizedHost(site.host) == site.host, "\(site.name)")
            #expect(site.host.contains("."), "\(site.name)")
        }
    }

    @Test func allowingASuggestedNotifierAnswersItsExactOrigin() {
        var config = PaddleConfig()
        config.sites["mail.google.com"] = SiteSettings(notifications: .allow)
        #expect(config.sitePolicy(forHost: "mail.google.com").notifications == .allow)
        #expect(config.notificationPermissions["https://mail.google.com"] == true)
    }
}
