import Foundation
@testable import PaddleCore
import Testing

struct ExtensionPermissionsTests {
    private let when = Date(timeIntervalSince1970: 1_790_000_000) // whole second

    private func snapshot(name: String = "Paddle Probe", version: String = "1.0",
                          permissions: [String: PermissionDecision] = ["storage": .allow, "nativeMessaging": .deny],
                          hosts: [String: PermissionDecision] = ["http://127.0.0.1/*": .allow]) -> ExtensionSnapshot {
        ExtensionSnapshot(name: name, version: version, decided: when, permissions: permissions, hosts: hosts)
    }

    @Test func roundTripsWithISODatesAndFolderKeys() throws {
        var decisions = ExtensionDecisions()
        decisions.set(folder: "paddle-probe", snapshot())
        decisions.set(folder: "ubolite", snapshot(name: "uBO Lite"))
        let data = try decisions.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""paddle-probe""#))
        #expect(text.contains("http://127.0.0.1/*"), "slashes stay unescaped")
        #expect(text.contains(#""decided" : "20"#), "ISO 8601 string")
        #expect(try ExtensionDecisions.decode(data) == decisions)
    }

    @Test func decodesAHandWrittenFileAndIgnoresUnknownKeys() throws {
        let json = #"""
        {"paddle-probe": {"name": "Paddle Probe", "version": "1.0", "decided": "2026-10-11T18:00:00Z", "extra": 1,
          "permissions": {"tabs": "allow", "nativeMessaging": "deny"}, "hosts": {"http://127.0.0.1/*": "allow"}}}
        """#
        let decisions = try ExtensionDecisions.decode(Data(json.utf8))
        let s = try #require(decisions.byFolder["paddle-probe"])
        #expect(s.permissions == ["tabs": .allow, "nativeMessaging": .deny])
        #expect(s.hosts == ["http://127.0.0.1/*": .allow])
        #expect(s.decided == Date(timeIntervalSince1970: 1_791_741_600))
    }

    @Test func missingPermissionAndHostTablesAreEmpty() throws {
        let json = #"{"x": {"name": "X", "version": "1", "decided": "2026-10-11T18:00:00Z"}}"#
        let s = try #require(try ExtensionDecisions.decode(Data(json.utf8)).byFolder["x"])
        #expect(s.permissions.isEmpty && s.hosts.isEmpty)
    }

    @Test func corruptDataThrows() {
        for bad in ["", "not json", "[]", #"{"x": {"name": "X"}}"#,
                    #"{"x": {"name": "X", "version": "1", "decided": "yesterday"}}"#,
                    #"{"x": {"name": "X", "version": "1", "decided": "2026-10-11T18:00:00Z", "permissions": {"tabs": "maybe"}}}"#] {
            #expect(throws: (any Error).self, "\(bad)") { try ExtensionDecisions.decode(Data(bad.utf8)) }
        }
    }

    @Test func newExtensionIsAllUndecided() {
        let decisions = ExtensionDecisions()
        let result = decisions.undecided(folder: "f", name: "N", permissions: ["tabs", "storage"], hosts: ["https://a.com/*"])
        #expect(result.permissions == ["tabs", "storage"])
        #expect(result.hosts == ["https://a.com/*"])
    }

    @Test func afterSetNothingIsUndecided() {
        var decisions = ExtensionDecisions()
        decisions.set(folder: "f", snapshot(name: "N", permissions: ["tabs": .allow, "storage": .deny], hosts: ["https://a.com/*": .deny]))
        let result = decisions.undecided(folder: "f", name: "N", permissions: ["tabs", "storage"], hosts: ["https://a.com/*"])
        #expect(result.permissions.isEmpty && result.hosts.isEmpty)
    }

    @Test func newVersionAsksOnlyAboutWhatIsNew() {
        var decisions = ExtensionDecisions()
        decisions.set(folder: "f", snapshot(name: "N", version: "1", permissions: ["tabs": .allow], hosts: ["https://a.com/*": .allow]))
        let result = decisions.undecided(folder: "f", name: "N", permissions: ["tabs", "cookies"], hosts: ["https://a.com/*", "https://b.com/*"])
        #expect(result.permissions == ["cookies"])
        #expect(result.hosts == ["https://b.com/*"])
    }

    @Test func differentNameInTheSameFolderResetsEverything() {
        var decisions = ExtensionDecisions()
        decisions.set(folder: "f", snapshot(name: "Old", permissions: ["tabs": .allow], hosts: ["https://a.com/*": .allow]))
        let result = decisions.undecided(folder: "f", name: "Different", permissions: ["tabs"], hosts: ["https://a.com/*"])
        #expect(result.permissions == ["tabs"])
        #expect(result.hosts == ["https://a.com/*"])
    }

    @Test func differentIdentityInTheSameFolderAndNameInheritsNothing() {
        var decisions = ExtensionDecisions()
        var old = snapshot(name: "N", permissions: ["tabs": .allow], hosts: ["https://a.com/*": .allow])
        old.identity = "gecko:a@b"
        decisions.set(folder: "f", old)
        #expect(!decisions.needsPrompt(folder: "f", name: "N", identity: "gecko:a@b", permissions: ["tabs"], hosts: ["https://a.com/*"]))
        #expect(decisions.needsPrompt(folder: "f", name: "N", identity: "gecko:other@b", permissions: ["tabs"], hosts: ["https://a.com/*"]))
        #expect(decisions.needsPrompt(folder: "f", name: "N", identity: nil, permissions: ["tabs"], hosts: ["https://a.com/*"]))
        let open = decisions.undecided(folder: "f", name: "N", identity: "chrome:x", permissions: ["tabs"], hosts: ["https://a.com/*"])
        #expect(open.permissions == ["tabs"] && open.hosts == ["https://a.com/*"])
    }

    @Test func recordWithoutIdentityKeepsApplyingAndAdoptsIt() throws {
        var decisions = ExtensionDecisions()
        decisions.set(folder: "f", snapshot(name: "N", permissions: ["tabs": .allow], hosts: [:]))
        // No re-prompt before or after the identity is filled in.
        #expect(!decisions.needsPrompt(folder: "f", name: "N", identity: "gecko:a@b", permissions: ["tabs"], hosts: []))
        let otherName = decisions.adopt(folder: "f", name: "Other", identity: "gecko:a@b")
        let noIdentity = decisions.adopt(folder: "f", name: "N", identity: nil)
        #expect(!otherName && !noIdentity)
        let adopted = decisions.adopt(folder: "f", name: "N", identity: "gecko:a@b")
        #expect(adopted)
        #expect(decisions.byFolder["f"]?.identity == "gecko:a@b")
        let replaced = decisions.adopt(folder: "f", name: "N", identity: "gecko:z@b")
        #expect(!replaced, "an identity is never replaced")
        #expect(!decisions.needsPrompt(folder: "f", name: "N", identity: "gecko:a@b", permissions: ["tabs"], hosts: []))
        // Old files without the key decode, and the identity round-trips.
        let json = #"{"x": {"name": "X", "version": "1", "decided": "2026-10-11T18:00:00Z"}}"#
        #expect(try ExtensionDecisions.decode(Data(json.utf8)).byFolder["x"]?.identity == nil)
        #expect(try ExtensionDecisions.decode(decisions.encoded()) == decisions)
    }

    @Test func pruneDropsRemovedFolders() {
        var decisions = ExtensionDecisions()
        decisions.set(folder: "keep", snapshot())
        decisions.set(folder: "gone", snapshot())
        let first = decisions.prune(keeping: ["keep", "other"])
        #expect(first)
        #expect(Set(decisions.byFolder.keys) == ["keep"])
        let second = decisions.prune(keeping: ["keep"])
        #expect(!second)
        #expect(decisions.needsPrompt(folder: "gone", name: "Paddle Probe", permissions: [], hosts: []))
    }

    @Test func permissionIdentityPrefersGeckoThenKeyThenStoreID() {
        let key = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcH"
        let gecko: [String: Any] = ["browser_specific_settings": ["gecko": ["id": "Ext@Example.org"]], "key": key]
        #expect(ExtensionIdentity.permissionIdentity(manifest: gecko, verifiedStoreID: "abc") == "gecko:ext@example.org")
        #expect(ExtensionIdentity.permissionIdentity(manifest: [:], verifiedStoreID: "ABC") == "store:abc")
        #expect(ExtensionIdentity.permissionIdentity(manifest: [:], verifiedStoreID: nil) == nil)
        let chrome = ExtensionIdentity.permissionIdentity(manifest: ["key": key], verifiedStoreID: "abc")
        #expect(chrome == ExtensionIdentity.chromeID(manifestKey: key).map { "chrome:" + $0 })
    }

    @Test func storeIDMustAgreeWithTheManifest() {
        let key = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcH"
        let keyID = ExtensionIdentity.chromeID(manifestKey: key)
        #expect(ExtensionIdentity.verifiedStoreID(keyID, store: .chromeWebStore, manifest: ["key": key]) == keyID)
        #expect(ExtensionIdentity.verifiedStoreID("other", store: .chromeWebStore, manifest: ["key": key]) == nil)
        #expect(ExtensionIdentity.verifiedStoreID("other", store: .chromeWebStore, manifest: [:]) == "other")
        let gecko: [String: Any] = ["applications": ["gecko": ["id": "a@b.org"]]]
        #expect(ExtensionIdentity.verifiedStoreID("a@b.org", store: .mozillaAddons, manifest: gecko) == "a@b.org")
        #expect(ExtensionIdentity.verifiedStoreID("c@d.org", store: .mozillaAddons, manifest: gecko) == nil)
        #expect(ExtensionIdentity.verifiedStoreID("some-slug", store: .mozillaAddons, manifest: gecko) == "some-slug")
        #expect(ExtensionIdentity.verifiedStoreID(nil, store: .chromeWebStore, manifest: [:]) == nil)
    }

    @Test func storageMovesOnlyFromOwnIDsAndNeverFromOthers() {
        let hex = "16c4e4dbfe721f2a74a46a0fd6ecbcb6"
        let chrome = ExtensionIdentity.chromeID(hex: hex)!
        let store = String(repeating: "a", count: 32)
        // Persona change: the folder's own private ids stay candidates.
        #expect(ExtensionIdentity.storageMoveCandidates(saltedID: hex, ownStoreID: nil, current: chrome, heldByOthers: []) == [hex])
        // Its own store id counts; a crafted manifest key (no record) adds nothing.
        #expect(ExtensionIdentity.storageMoveCandidates(saltedID: hex, ownStoreID: store, current: chrome, heldByOthers: []) == [hex, store])
        // Held by another folder's record or a loaded extension: refused.
        #expect(ExtensionIdentity.storageMoveCandidates(saltedID: hex, ownStoreID: store, current: chrome, heldByOthers: [store]) == [hex])
    }

    @Test func olderVersionIsADowngrade() {
        #expect(ExtensionVersion.isDowngrade(from: "1.10", to: "1.9", store: .chromeWebStore))
        #expect(!ExtensionVersion.isDowngrade(from: "1.9", to: "1.10", store: .chromeWebStore))
        #expect(!ExtensionVersion.isDowngrade(from: "1.0", to: "1", store: .chromeWebStore))
        #expect(ExtensionVersion.isDowngrade(from: "2.0", to: "2.0b1", store: .mozillaAddons))
        #expect(!ExtensionVersion.isDowngrade(from: nil, to: "1", store: .mozillaAddons))
        #expect(!ExtensionVersion.isDowngrade(from: "1", to: nil, store: .chromeWebStore))
        #expect(!ExtensionVersion.isDowngrade(from: "junk", to: "1", store: .chromeWebStore))
    }

    @Test func forgetMakesEverythingUndecidedAgain() {
        var decisions = ExtensionDecisions()
        decisions.set(folder: "f", snapshot(name: "N", permissions: ["tabs": .allow], hosts: [:]))
        decisions.forget(folder: "f")
        #expect(decisions.byFolder.isEmpty)
        #expect(decisions.undecided(folder: "f", name: "N", permissions: ["tabs"], hosts: []).permissions == ["tabs"])
        decisions.forget(folder: "never-there")
    }

    @Test func fromKeepsNoExpiryAndDropsShortExpiry() {
        let noExpiry = Date(timeIntervalSinceReferenceDate: 64_092_211_200) // 4001-01-01
        let now = Date(timeIntervalSince1970: 1_790_000_000.75)
        let s = ExtensionSnapshot.from(
            name: "N", version: "1",
            granted: ["storage": noExpiry, "activeTab": now.addingTimeInterval(3600)],
            denied: ["nativeMessaging": noExpiry],
            grantedHosts: ["http://127.0.0.1/*": noExpiry, "https://tab-only.test/*": now.addingTimeInterval(3600)],
            deniedHosts: ["https://example.com/*": noExpiry], now: now)
        #expect(s.permissions == ["storage": .allow], "nativeMessaging is Paddle's to decide, never recorded")
        #expect(s.hosts == ["http://127.0.0.1/*": .allow, "https://example.com/*": .deny])
        #expect(s.name == "N" && s.version == "1")
        #expect(s.decided == Date(timeIntervalSince1970: 1_790_000_000), "whole seconds")
    }

    @Test func denialBeatsGrantForTheSameItem() {
        let noExpiry = Date(timeIntervalSinceReferenceDate: 64_092_211_200)
        let s = ExtensionSnapshot.from(name: "N", version: "1", granted: ["tabs": noExpiry], denied: ["tabs": noExpiry],
                                       grantedHosts: [:], deniedHosts: [:], now: when)
        #expect(s.permissions == ["tabs": .deny])
    }

    @Test func isFullyDeclined() {
        #expect(snapshot(permissions: ["tabs": .deny], hosts: ["https://a.com/*": .deny]).isFullyDeclined)
        #expect(!snapshot(permissions: ["tabs": .deny], hosts: ["https://a.com/*": .allow]).isFullyDeclined)
        #expect(!snapshot(permissions: ["tabs": .allow], hosts: [:]).isFullyDeclined)
    }

    @Test func runMarkerDecidesWhenPresent() {
        var allowedEmpty = snapshot(permissions: [:], hosts: [:])
        #expect(allowedEmpty.isFullyDeclined)  // an old record with nothing allowed
        allowedEmpty.run = .allow
        #expect(!allowedEmpty.isFullyDeclined)
        var refused = snapshot(permissions: ["tabs": .allow], hosts: [:])
        refused.run = .deny
        #expect(refused.isFullyDeclined)
    }

    @Test func runMarkerRoundTripsAndIsOptional() throws {
        var decisions = ExtensionDecisions()
        decisions.set(folder: "f", ExtensionSnapshot(name: "N", version: "1", decided: when, run: .allow))
        let back = try ExtensionDecisions.decode(decisions.encoded())
        #expect(back.byFolder["f"]?.run == .allow)
        let old = try ExtensionDecisions.decode(Data(#"{"f":{"name":"N","version":"1","decided":"2026-10-11T18:00:00Z"}}"#.utf8))
        #expect(old.byFolder["f"]?.run == nil)
    }

    @Test func needsPromptForNeverAskedEvenWhenAskingForNothing() {
        var decisions = ExtensionDecisions()
        #expect(decisions.needsPrompt(folder: "f", name: "N", permissions: [], hosts: []))
        var s = ExtensionSnapshot(name: "N", version: "1", decided: when)
        s.apply(.allow, requested: ([], []), undecided: ([], []))
        decisions.set(folder: "f", s)
        #expect(!decisions.needsPrompt(folder: "f", name: "N", permissions: [], hosts: []))
        #expect(decisions.needsPrompt(folder: "f", name: "Other", permissions: [], hosts: []))
        #expect(decisions.needsPrompt(folder: "f", name: "N", permissions: ["tabs"], hosts: []))
        #expect(s.run == .allow && !s.isFullyDeclined)
    }

    @Test func allowOnAskForNothingRunsAndDenyDoesNot() {
        var s = ExtensionSnapshot(name: "N", version: "1", decided: when)
        s.apply(.deny, requested: ([], []), undecided: ([], []))
        #expect(s.isFullyDeclined)
    }

    @Test func upgradeDontAllowDeniesEverythingAlreadyAllowed() {
        var s = snapshot(permissions: ["storage": .allow], hosts: ["<all_urls>": .allow])
        s.apply(.deny, requested: (["storage", "cookies"], ["<all_urls>"]), undecided: (["cookies"], []))
        #expect(s.permissions == ["storage": .deny, "cookies": .deny])
        #expect(s.hosts == ["<all_urls>": .deny])
        #expect(s.isFullyDeclined)
    }

    @Test func upgradeOnlyWhenClickedTakesBackOldHostsToo() {
        var s = snapshot(permissions: ["storage": .allow], hosts: ["<all_urls>": .allow])
        s.apply(.onlyWhenClicked, requested: (["storage", "cookies"], ["<all_urls>"]), undecided: (["cookies"], []))
        #expect(s.permissions == ["storage": .allow, "cookies": .allow])
        #expect(s.hosts == ["<all_urls>": .click])
        #expect(!s.isFullyDeclined)
    }

    @Test func onlyWhenClickedHostsAreDecidedAndRoundTrip() throws {
        var s = ExtensionSnapshot(name: "N", version: "1", decided: when)
        s.apply(.onlyWhenClicked, requested: (["activeTab"], ["<all_urls>"]), undecided: (["activeTab"], ["<all_urls>"]))
        #expect(s.hosts == ["<all_urls>": .click] && s.run == .allow)
        var decisions = ExtensionDecisions()
        decisions.set(folder: "f", s)
        #expect(!decisions.needsPrompt(folder: "f", name: "N", permissions: ["activeTab"], hosts: ["<all_urls>"]))
        let data = try decisions.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"click\""))
        #expect(try ExtensionDecisions.decode(data) == decisions)
    }

    @Test func fromKeepsClickHostsWebKitHasNoStateFor() {
        let later = when.addingTimeInterval(100 * 365 * 86_400)
        let soon = when.addingTimeInterval(60)
        let s = ExtensionSnapshot.from(
            name: "N", version: "1", granted: ["activeTab": later], denied: [:],
            grantedHosts: ["*://*.bank.example/*": soon, "https://b.com/*": later], deniedHosts: ["https://c.com/*": later],
            clickHosts: ["<all_urls>", "https://b.com/*", "https://c.com/*"], now: when
        )
        #expect(s.hosts == ["<all_urls>": .click, "https://b.com/*": .allow, "https://c.com/*": .deny])
    }

    @Test func upgradeAllowKeepsEarlierAnswersAndNeverRecordsNativeMessaging() {
        var s = snapshot(permissions: ["storage": .allow, "tabs": .deny, "nativeMessaging": .deny], hosts: [:])
        s.apply(.allow, requested: (["storage", "tabs", "nativeMessaging"], ["https://a.com/*"]),
                undecided: (["nativeMessaging"], ["https://a.com/*"]))
        #expect(s.permissions == ["storage": .allow, "tabs": .deny])
        #expect(s.hosts == ["https://a.com/*": .allow])
        #expect(s.run == .allow)
    }

    @Test func onlyWhenClickedWithOnlyHostsIsDeclined() {
        var s = ExtensionSnapshot(name: "N", version: "1", decided: when)
        s.apply(.onlyWhenClicked, requested: ([], ["https://a.com/*"]), undecided: ([], ["https://a.com/*"]))
        #expect(s.isFullyDeclined)
    }

    @Test func fromCarriesTheRunMarker() {
        let s = ExtensionSnapshot.from(name: "N", version: "1", run: .allow, granted: [:], denied: [:], grantedHosts: [:], deniedHosts: [:], now: when)
        #expect(s.run == .allow)
    }

    @Test func nativeMessagingIsNeverAskedAbout() {
        let decisions = ExtensionDecisions(byFolder: ["f": snapshot(name: "N", permissions: ["storage": .allow], hosts: [:])])
        #expect(!decisions.needsPrompt(folder: "f", name: "N", permissions: ["storage", "nativeMessaging"], hosts: []))
        #expect(ExtensionDecisions().undecided(folder: "f", name: "N", permissions: ["nativeMessaging", "tabs"], hosts: []).permissions == ["tabs"])
    }
}
