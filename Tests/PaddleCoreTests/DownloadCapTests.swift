import Foundation
@testable import PaddleCore
import Testing

struct DownloadCapTests {
    @Test func stopsOnceOverTheLimit() {
        var cap = DownloadCap(limit: 10)
        let first = cap.add(6)
        let second = cap.add(4)
        let third = cap.add(1)
        #expect(first)
        #expect(second)
        #expect(!third)
    }

    @Test func announcedLength() {
        let cap = DownloadCap(limit: 100)
        #expect(!cap.announcedTooLarge(100))
        #expect(cap.announcedTooLarge(101))
        #expect(!cap.announcedTooLarge(-1))
    }

    @Test func capsAreTwoAndThreeMegabytes() {
        #expect(DownloadCap.feedBytes == 2_097_152)
        #expect(DownloadCap.feedImageBytes == 3_145_728)
    }

    @Test func feedImagesRefuseLocalAndPrivateHosts() {
        for bad in ["http://localhost/a.png", "https://127.0.0.1/a.png", "http://10.0.0.5/a.png", "http://192.168.1.1/a.png",
                    "http://172.16.0.1/a", "http://172.31.255.1/a", "http://169.254.169.254/a", "http://[::1]/a",
                    "http://[fd12::1]/a", "http://[fe80::1]/a", "http://[::ffff:10.0.0.1]/a", "http://printer/a.png",
                    "http://nas.local/a.png", "http://0x7f.1/a", "http://2130706433/a", "ftp://example.com/a.png", "http://100.64.0.1/a"] {
            #expect(!FeedImagePolicy.allows(URL(string: bad)!), "\(bad)")
        }
        for good in ["https://example.com/a.png", "http://172.32.0.1/a.png", "https://cdn.news.example.org/x.jpg", "http://8.8.8.8/a"] {
            #expect(FeedImagePolicy.allows(URL(string: good)!), "\(good)")
        }
    }
}
