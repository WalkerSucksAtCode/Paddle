import Foundation
@testable import PaddleCore
import Testing

struct NewTabSitesTests {
    @Test func addRefusesNonWebDuplicatesAndOverflow() {
        var list = NewTabSites()
        let r1 = list.add(title: "Example", url: "https://Example.com/")
        #expect(r1)
        let r2 = list.add(title: "Again", url: "https://example.com")
        #expect(!r2)
        let r3 = list.add(title: "File", url: "file:///etc/hosts")
        #expect(!r3)
        let r4 = list.add(title: "Junk", url: "not a url")
        #expect(!r4)
        let r5 = list.add(title: "", url: "http://example.com/a")
        #expect(r5)
        #expect(list.sites[1].title == "example.com")
        for i in 0..<NewTabSites.maxSites { _ = list.add(title: "S\(i)", url: "https://s\(i).test") }
        #expect(list.sites.count == NewTabSites.maxSites)
        let r6 = list.add(title: "Over", url: "https://over.test")
        #expect(!r6)
    }

    @Test func removeMoveAndUpdate() {
        var list = NewTabSites()
        for name in ["a", "b", "c"] { _ = list.add(title: name, url: "https://\(name).test") }
        let ids = list.sites.map(\.id)
        list.move(from: 0, to: 2)
        #expect(list.sites.map(\.title) == ["b", "c", "a"])
        list.move(from: 5, to: 0)
        #expect(list.sites.count == 3)
        let r7 = list.update(id: ids[1], title: "B2", url: "https://b2.test/")
        #expect(r7)
        let r8 = list.update(id: ids[1], title: "B3", url: "https://c.test")
        #expect(!r8)
        let r9 = list.update(id: ids[1], title: "B3", url: "ftp://b.test")
        #expect(!r9)
        let r10 = list.update(id: ids[1], title: "Same", url: "https://B2.test")
        #expect(r10)
        #expect(list.sites.first { $0.id == ids[1] }?.title == "Same")
        list.remove(id: ids[2])
        #expect(list.sites.map(\.title) == ["Same", "a"])
    }

    @Test func hideFrequentNormalizesAndDedupes() {
        var list = NewTabSites()
        list.hideFrequent(host: "WWW.Example.com")
        list.hideFrequent(host: "example.com")
        list.hideFrequent(host: "")
        #expect(list.hiddenFrequent == ["example.com"])
    }

    @Test func lenientDecoderSkipsBadEntries() throws {
        let json = """
        {"sites": [{"title": "Ok", "url": "https://ok.test"}, {"title": "No url"}, 5,
                   {"url": "ftp://x.test"}, {"url": "https://ok.test/"}, {"url": "https://t.test", "extra": 1}],
         "hiddenFrequent": ["A.test", 3, "a.test"], "future": true}
        """
        let list = try NewTabSites.decode(Data(json.utf8))
        #expect(list.sites.map(\.url) == ["https://ok.test", "https://t.test"])
        #expect(list.sites[1].title == "https://t.test")
        #expect(list.hiddenFrequent == ["a.test"])
        #expect(try NewTabSites.decode(Data("{}".utf8)) == NewTabSites())
    }

    @Test func roundTrips() throws {
        var list = NewTabSites()
        _ = list.add(title: "A", url: "https://a.test")
        list.hideFrequent(host: "b.test")
        #expect(try NewTabSites.decode(list.encoded()) == list)
    }
}
