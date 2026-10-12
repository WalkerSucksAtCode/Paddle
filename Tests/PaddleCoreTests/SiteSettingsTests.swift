import Foundation
@testable import PaddleCore
import Testing

struct SiteSettingsTests {
    @Test func decodesLockedShapeWithOptionalFields() throws {
        let json = #"""
        {"sites": {"example.com": {"zoom": 1.25, "javaScript": false, "autoplay": "muted", "contentBlocking": false, "location": "deny"},
                   "docs.example.com": {"zoom": 1}}}
        """#
        let config = try PaddleConfig.decode(Data(json.utf8))
        #expect(config.sites["example.com"] == SiteSettings(zoom: 1.25, javaScript: false, autoplay: .muted, contentBlocking: false, location: .deny))
        #expect(config.sites["docs.example.com"] == SiteSettings(zoom: 1))
        #expect(config.sites["docs.example.com"]?.isEmpty == false)
        #expect(SiteSettings().isEmpty)
        #expect(config.siteUserAgents.isEmpty)
    }

    @Test func missingKeyIsEmptyAndRoundTripsWithoutNilFields() throws {
        #expect(try PaddleConfig.decode(Data("{}".utf8)).sites.isEmpty)
        var config = PaddleConfig()
        config.sites = ["example.com": SiteSettings(javaScript: false)]
        let data = try config.encoded()
        #expect(try PaddleConfig.decode(data) == config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""javaScript" : false"#))
        #expect(!text.contains("zoom") && !text.contains("null"))
    }

    @Test func badEnumValueNamesItsPath() {
        do {
            _ = try PaddleConfig.decode(Data(#"{"sites": {"example.com": {"autoplay": "loud"}}}"#.utf8))
            Issue.record("should not decode")
        } catch {
            #expect(PaddleConfig.describe(error).hasPrefix("sites.example.com.autoplay:"))
        }
    }

    @Test func lookupMatchesExactHostAndParentDomains() {
        var config = PaddleConfig()
        config.sites = [
            "example.com": SiteSettings(zoom: 1.5, javaScript: false, location: .deny),
            "Docs.Example.com": SiteSettings(zoom: 2, autoplay: .block),
            "other.example": SiteSettings(contentBlocking: false),
        ]
        #expect(config.siteSettingsKeys(forHost: "DOCS.example.com") == ["example.com", "Docs.Example.com"])
        // The longest suffix wins each field; what it leaves unset comes from the parent.
        #expect(config.siteSettings(forHost: "docs.example.com") == SiteSettings(zoom: 2, javaScript: false, autoplay: .block, location: .deny))
        #expect(config.siteSettings(forHost: "www.example.com") == SiteSettings(zoom: 1.5, javaScript: false, location: .deny))
        #expect(config.siteSettings(forHost: "example.com") == config.sites["example.com"])
        // "notexample.com" is not a subdomain of "example.com".
        #expect(config.siteSettings(forHost: "notexample.com").isEmpty)
        #expect(config.siteSettings(forHost: "unknown.example").isEmpty)
    }

    /// `URL.host` gives punycode and may keep a trailing dot; keys are what the user typed.
    @Test func lookupNormalizesInternationalAndTrailingDotHosts() {
        var config = PaddleConfig()
        config.sites = ["bücher.de": SiteSettings(javaScript: false), "example.com.": SiteSettings(zoom: 2)]
        config.siteUserAgents = ["bücher.de": "UA"]
        #expect(PaddleConfig.normalizedHost("Bücher.DE.") == "xn--bcher-kva.de")
        #expect(PaddleConfig.normalizedHost("localhost:8080") == "localhost:8080")
        #expect(config.siteSettingsKeys(forHost: "xn--bcher-kva.de") == ["bücher.de"])
        #expect(config.siteSettingsKeys(forHost: "shop.xn--bcher-kva.de") == ["bücher.de"])
        #expect(config.siteSettingsKeys(forHost: "example.com.") == ["example.com."])
        #expect(config.siteSettingsKeys(forHost: "www.example.com") == ["example.com."])
        #expect(config.userAgent(forHost: "xn--bcher-kva.de") == "UA")
        #expect(config.userAgent(forHost: "bücher.de") == "UA")
    }

    /// README's config table and `PaddleConfig.CodingKeys` must list the same keys.
    @Test func readmeTableMatchesCodingKeys() throws {
        let readme = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        let section = try #require(text.components(separatedBy: "\n## config.json\n").dropFirst().first)
            .components(separatedBy: "\n## ").first ?? ""
        var documented: [String] = []
        for line in section.split(separator: "\n") where line.hasPrefix("| `") {
            let key = line.dropFirst(3).prefix { $0 != "`" }
            documented.append(String(key))
        }
        let coded = PaddleConfig.CodingKeys.allCases.map(\.rawValue)
        #expect(Set(documented).subtracting(coded).isEmpty, "README rows with no PaddleConfig key")
        #expect(Set(coded).subtracting(documented).isEmpty, "PaddleConfig keys missing from README")
        #expect(documented.count == Set(documented).count, "duplicate README rows")
    }

    @Test func userAgentPresetsRoundTripTheirStrings() {
        for preset in UserAgentPreset.allCases {
            #expect(UserAgentPreset(value: preset.value) == preset)
            #expect(preset.value.hasPrefix("Mozilla/5.0 (Macintosh;"))
        }
        #expect(UserAgentPreset(value: "Mozilla/5.0 custom") == nil)
    }
}
