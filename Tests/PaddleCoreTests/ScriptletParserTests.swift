@testable import PaddleCore
import Testing

struct ScriptletParserTests {
    private func line(_ text: String, trusted: Bool = false) -> ScriptletLine? {
        if case .line(let line) = ScriptletParser.parse(text, trusted: trusted) { return line }
        return nil
    }

    @Test func notAScriptletLine() {
        #expect(ScriptletParser.parse("example.com##.ad") == nil)
        #expect(ScriptletParser.parse("||ads.example^") == nil)
    }

    @Test func aliasesMapToCanonicalNames() {
        #expect(line("example.com##+js(set, a.b, true)")?.name == .setConstant)
        #expect(line("example.com##+js(set-constant.js, a.b, true)")?.name == .setConstant)
        #expect(line("example.com##+js(aopr, x)")?.name == .abortOnPropertyRead)
        #expect(line("example.com##+js(acis, x)")?.name == .abortCurrentScript)
        #expect(line("example.com##+js(nostif, ads)")?.name == .noSetTimeoutIf)
        #expect(line("example.com##+js(nowoif)")?.name == .noWindowOpenIf)
        #expect(line("example.com##+js(rmnt, script, ads)")?.name == .removeNodeText)
        #expect(line("example.com##+js(nano-sib)")?.name == .nanoSetIntervalBooster)
        for name in ScriptletName.allCases {
            #expect(line("example.com##+js(\(name.rawValue))")?.name == name)
        }
    }

    @Test func argumentSplitting() {
        #expect(ScriptletParser.splitArguments("set, a.b ,  true") == ["set", "a.b", "true"])
        #expect(ScriptletParser.splitArguments(#"acs, a, b\, c"#) == ["acs", "a", "b, c"])
        #expect(ScriptletParser.splitArguments("acs, 'a, b', \"c, d\", `e, f`") == ["acs", "a, b", "c, d", "e, f"])
        #expect(ScriptletParser.splitArguments(#"acs, 'it\'s', x"#) == ["acs", "it's", "x"])
        #expect(ScriptletParser.splitArguments("acs, ' spaced '") == ["acs", " spaced "])
        #expect(ScriptletParser.splitArguments("set, a.b, ''") == ["set", "a.b", ""])
        #expect(ScriptletParser.splitArguments("acs, don't") == ["acs", "don't"])
        #expect(ScriptletParser.splitArguments("acs, 'open") == nil)
        #expect(ScriptletParser.splitArguments("acs, 'a' b") == nil)
        #expect(line("example.com##+js(rmnt, script, /ads?\\(\\)/)")?.arguments == ["script", "/ads?\\(\\)/"])
    }

    @Test func domains() throws {
        let parsed = try #require(line("a.com, ~b.a.com,shop.*,~test.*,BÜCHER.de##+js(set, x, 1)"))
        #expect(parsed.includeDomains == ["a.com", "xn--bcher-kva.de"])
        #expect(parsed.excludeDomains == ["b.a.com"])
        #expect(parsed.includeEntities == ["shop"])
        #expect(parsed.excludeEntities == ["test"])
        #expect(!parsed.isGeneric)
        #expect(line("##+js(nowebrtc)")?.isGeneric == true)
        #expect(ScriptletParser.parse("/^ads\\./##+js(set, x, 1)") == .malformed("bad domain list"))
        #expect(ScriptletParser.parse("a.com,,b.com##+js(set, x, 1)") == .malformed("bad domain list"))
    }

    @Test func refusals() {
        #expect(ScriptletParser.parse("example.com##+js(something-else, x)") == .refusedUnknown("something-else"))
        #expect(ScriptletParser.parse("example.com##+js(trusted-set, x, 1)") == .refusedTrusted("trusted-set"))
        // A trusted list may use only the trusted scriptlets Paddle implements (none yet).
        #expect(ScriptletParser.parse("example.com##+js(trusted-set, x, 1)", trusted: true) == .refusedTrusted("trusted-set"))
        #expect(ScriptletParser.parse("example.com##+js(set, x") == .malformed("no closing parenthesis"))
        #expect(ScriptletParser.parse("example.com##+js()") == .malformed("no scriptlet name"))
    }

    @Test func exceptions() throws {
        let specific = try #require(line("a.com#@#+js(set, x, 1)"))
        #expect(specific.isException && specific.name == .setConstant)
        let all = try #require(line("a.com#@#+js()"))
        #expect(all.isException && all.name == nil)
    }

    @Test func exceptionsCancelAcrossLists() {
        let list = """
            ! comment
            a.com,b.com,c.org##+js(set, x, 1)
            ##+js(nowebrtc)
            d.com##+js(aopr, y)
            sub.e.com##+js(aopr, z)
            e.com##+js(aopr, z)
            """
        let exceptions = """
            b.com#@#+js(set, x, 1)
            q.com#@#+js(nowebrtc)
            d.com#@#+js()
            #@#+js(aopr, z)
            """
        let (rules, summaries) = ScriptletSet.rules(from: [(list, false), (exceptions, false)])
        #expect(summaries[0].accepted == 5 && summaries[1].exceptions == 4)
        #expect(rules.count == 2)
        let set = rules.first { $0.name == .setConstant }
        #expect(set?.includeDomains == ["a.com", "c.org"])
        let webrtc = rules.first { $0.name == .noWebRTC }
        // `d.com#@#+js()` stops every scriptlet on d.com, the generic one included.
        #expect(webrtc?.isGeneric == true && webrtc?.excludeDomains == ["q.com", "d.com"])
        // d.com lost its only site to `#@#+js()`; the generic `aopr, z` exception removed both z rules.
        #expect(!rules.contains { $0.name == .abortOnPropertyRead })
    }

    @Test func exceptionOnASubdomainExcludesIt() {
        let (rules, _) = ScriptletSet.rules(from: [("example.com##+js(set, x, 1)\nshop.example.com#@#+js(set, x, 1)", false)])
        #expect(rules == [ScriptletRule(
            name: .setConstant, arguments: ["x", "1"], includeDomains: ["example.com"], excludeDomains: ["shop.example.com"],
            includeEntities: [], excludeEntities: []
        )])
    }

    @Test func sameScriptletMergesIntoOneRule() {
        let text = """
            a.com##+js(set, x, 1)
            b.com##+js(set, x, 1)
            c.*##+js(set, x, 1)
            d.com##+js(set, x, 2)
            ##+js(nowebrtc)
            ##+js(nowebrtc)
            """
        let (rules, _) = ScriptletSet.rules(from: [(text, false)])
        #expect(rules.count == 3)
        #expect(rules[0].includeDomains == ["a.com", "b.com"] && rules[0].includeEntities == ["c"])
        #expect(rules[1].arguments == ["x", "2"])
        #expect(rules[2].name == .noWebRTC)
    }

    @Test func summaryNamesTheMostRefused() {
        let text = """
            a.com##+js(trusted-click-element, x)
            b.com##+js(trusted-click-element, y)
            c.com##+js(href-sanitizer, z)
            d.com##+js(set, x
            """
        let (_, summaries) = ScriptletSet.rules(from: [(text, false)])
        #expect(summaries[0].refusedTrusted == 2 && summaries[0].refusedUnknown == 1 && summaries[0].malformed == 1)
        #expect(summaries[0].topRefused == ["trusted-click-element", "href-sanitizer"])
    }

    @Test func converterLeavesScriptletLinesAlone() {
        let result = FilterListConverter.convert("a.com##+js(set, x, 1)\na.com#@#+js(set, x, 1)\n##.ad")
        #expect(!result.json.contains("+js"))
    }

    @Test func exceptionEdgeCases() {
        // A domain exception against an entity rule excludes that domain.
        let entity = ScriptletSet.rules(from: [("shop.*##+js(set, x, 1)\nshop.com#@#+js(set, x, 1)", false)]).rules
        #expect(entity.first?.includeEntities == ["shop"] && entity.first?.excludeDomains == ["shop.com"])
        // An entity exception removes the domains it covers.
        let domains = ScriptletSet.rules(from: [("shop.com,www.shop.co.uk,other.com##+js(set, x, 1)\nshop.*#@#+js(set, x, 1)", false)]).rules
        #expect(domains.first?.includeDomains == ["other.com"])
        #expect(ScriptletParser.parse("~a.com#@#+js()") == .malformed("exception with only negated domains"))
        let kept = ScriptletSet.rules(from: [("b.com##+js(set, x, 1)\n~a.com#@#+js(set, x, 1)", false)]).rules
        #expect(kept.count == 1)
    }

    @Test func entityMatchingAgreesWithTheDispatcher() {
        #expect(ScriptletSet.entityCovers(host: "shop.com", entity: "shop"))
        #expect(ScriptletSet.entityCovers(host: "www.shop.co.uk", entity: "shop"))
        #expect(!ScriptletSet.entityCovers(host: "shop.example.net.evil.io", entity: "shop"))
        #expect(!ScriptletSet.entityCovers(host: "myshop.com", entity: "shop"))
    }
}
