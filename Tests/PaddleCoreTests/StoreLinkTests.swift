import Foundation
@testable import PaddleCore
import Testing

struct StoreLinkTests {
    private let id = "mnjggcdmjocbbbhaepdhchncahnbgone"

    @Test func chromeWebStoreLinks() {
        let expected = StoreLink.chromeWebStore(id: id)
        for link in [
            "https://chromewebstore.google.com/detail/sponsorblock-for-youtube/\(id)",
            "https://chromewebstore.google.com/detail/sponsorblock-for-youtube/\(id)/",
            "https://chromewebstore.google.com/detail/\(id)",
            "https://chromewebstore.google.com/detail/sponsorblock/\(id)?hl=en&pli=1#reviews",
            "https://CHROMEWEBSTORE.google.com/detail/x/\(id.uppercased())",
            "HTTPS://chromewebstore.google.com/detail/x/\(id)",
            "https://chrome.google.com/webstore/detail/sponsorblock/\(id)",
            "https://chrome.google.com/webstore/detail/\(id)?hl=de",
            "  \(id)\n",
            id.uppercased(),
        ] {
            #expect(StoreLink.parse(link) == expected, "\(link)")
        }
        #expect(StoreLink.parse(id)?.source == .chromeWebStore)
        #expect(StoreLink.parse(id)?.storeID == id)
    }

    @Test func badChromeLinksAreRefused() {
        for link in [
            "mnjggcdmjocbbbhaepdhchncahnbgonq",  // q is outside a–p
            "mnjggcdmjocbbbhaepdhchncahnbgon",  // 31 letters
            "mnjggcdmjocbbbhaepdhchncahnbgonea",  // 33 letters
            "0123456789abcdef0123456789abcdef",  // hex, not a–p
            "http://chromewebstore.google.com/detail/x/\(id)",
            "https://chromewebstore.google.com.evil.example/detail/x/\(id)",
            "https://evil.example/detail/x/\(id)",
            "https://chromewebstore.google.com:8443/detail/x/\(id)",
            "https://user@chromewebstore.google.com/detail/x/\(id)",
            "https://chromewebstore.google.com/detail/x/\(id)/reviews/more",
            "https://chromewebstore.google.com/detail/",
            "https://chromewebstore.google.com/category/extensions",
            "https://chromewebstore.google.com/\(id)",
            "https://chrome.google.com/detail/x/\(id)",
            "https://chrome.google.com/webstore/detail/x/\(id)x",
            "chromewebstore.google.com/detail/x/\(id)",
            "",
            "not a link",
        ] {
            #expect(StoreLink.parse(link) == nil, "\(link)")
        }
    }

    @Test func addonsMozillaOrgLinks() {
        for link in [
            "https://addons.mozilla.org/en-US/firefox/addon/sponsorblock/",
            "https://addons.mozilla.org/en-US/firefox/addon/sponsorblock",
            "https://addons.mozilla.org/firefox/addon/sponsorblock/",
            "https://addons.mozilla.org/de/firefox/addon/sponsorblock/?utm_source=x",
        ] {
            #expect(StoreLink.parse(link) == .mozillaAddons(slug: "sponsorblock"), "\(link)")
        }
        #expect(StoreLink.parse("https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/")?.source == .mozillaAddons)
        #expect(StoreLink.parse("https://addons.mozilla.org/firefox/addon/{4b547b2c-e114-4344-9b70-09b2fe0785f3}/")
            == .mozillaAddons(slug: "{4b547b2c-e114-4344-9b70-09b2fe0785f3}"))
        for link in [
            "https://addons.mozilla.org/en-US/android/addon/sponsorblock/",
            "https://addons.mozilla.org/android/addon/sponsorblock/",
            "http://addons.mozilla.org/en-US/firefox/addon/sponsorblock/",
            "https://addons.mozilla.org.evil.example/en-US/firefox/addon/sponsorblock/",
            "https://addons.mozilla.org/en-US/firefox/addon/",
            "https://addons.mozilla.org/en-US/firefox/addon/sponsorblock/reviews/",
            "https://addons.mozilla.org/en-US/firefox/extensions/",
            "https://addons.mozilla.org/en-US/firefox/addon/a%20b/",
            "https://addons.mozilla.org/en-US/firefox/addon/../",
            "https://addons.mozilla.org/en_US!/firefox/addon/sponsorblock/",
        ] {
            #expect(StoreLink.parse(link) == nil, "\(link)")
        }
    }

    @Test func detailPagesUseTheSameRules() throws {
        let page = try #require(URL(string: "https://chromewebstore.google.com/detail/sponsorblock/\(id)?hl=en"))
        #expect(StoreLink.isStoreDetailPage(page) == .chromeWebStore(id: id))
        #expect(StoreLink.isStoreDetailPage(try #require(URL(string: "https://chromewebstore.google.com/"))) == nil)
        #expect(StoreLink.isStoreDetailPage(try #require(URL(string: "https://example.com/detail/x/\(id)"))) == nil)
    }

    @Test func chromeDownloadURL() {
        let versions = BrowserVersions(chromeMajor: 156, chromeFullVersion: "156.0.8078.12", firefoxVersion: "157.0")
        #expect(StoreLink.chromeDownloadURL(id: id, versions: versions)?.absoluteString
            == "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=156.0.8078.12&acceptformat=crx3&x=id%3D\(id)%26uc")
        #expect(StoreLink.chromeDownloadURL(id: id.uppercased(), versions: versions)?.absoluteString.contains("id%3D\(id)%26uc") == true)
        #expect(StoreLink.chromeDownloadURL(id: "not-an-id", versions: versions) == nil)
        let odd = BrowserVersions(chromeMajor: 1, chromeFullVersion: "1.0&x=y", firefoxVersion: "1.0")
        #expect(StoreLink.chromeDownloadURL(id: id, versions: odd) == nil)
        #expect(StoreLink.chromeDownloadURL(id: id).map { StoreLink.isAllowedChromeDownloadRedirect($0) } == true)
    }

    @Test func downloadRedirectAllowlist() throws {
        for allowed in [
            "https://clients2.googleusercontent.com/crx/blobs/abc/extension.crx",
            "https://edgedl.me.gvt1.com/edgedl/release2/chrome_component/x.crx",
            "https://gvt1.com/x",
            "https://google.com/x",
            "https://clients2.google.com/service/update2/crx",
            "https://CLIENTS2.GOOGLEUSERCONTENT.COM/x",
            "https://dl.google.com:443/x",
        ] {
            #expect(StoreLink.isAllowedChromeDownloadRedirect(try #require(URL(string: allowed))), "\(allowed)")
        }
        for refused in [
            "http://clients2.googleusercontent.com/x",
            "https://google.com.evil.example/x",
            "https://evilgoogle.com/x",
            "https://notgvt1.com/x",
            "https://googleusercontent.com.evil.example/x",
            "https://evil.example/google.com",
            "https://user@clients2.google.com/x",
            "https://clients2.google.com:8443/x",
            "ftp://clients2.google.com/x",
            "file:///google.com/x",
        ] {
            #expect(!StoreLink.isAllowedChromeDownloadRedirect(try #require(URL(string: refused))), "\(refused)")
        }
    }
}
