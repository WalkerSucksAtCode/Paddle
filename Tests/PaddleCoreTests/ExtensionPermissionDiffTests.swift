import Foundation
@testable import PaddleCore
import Testing

struct ExtensionPermissionDiffTests {
    let when = Date(timeIntervalSince1970: 1_791_000_000)

    func manifest(_ json: String) -> Data { Data(json.utf8) }

    @Test func requiredReadsPermissionsAndHostPermissionsOnly() throws {
        let data = manifest(#"""
        {"manifest_version":3,"permissions":["storage","tabs"],"host_permissions":["https://example.com/*"],
         "optional_permissions":["history"],"optional_host_permissions":["https://optional.test/*"]}
        """#)
        let required = try ExtensionPermissionDiff.required(manifest: data)
        #expect(required.permissions == ["storage", "tabs"])
        #expect(required.hosts == ["https://example.com/*"])
    }

    @Test func manifestV2PatternsInPermissionsAreHosts() throws {
        let data = manifest(#"{"manifest_version":2,"permissions":["tabs","<all_urls>","https://a.test/*"]}"#)
        let required = try ExtensionPermissionDiff.required(manifest: data)
        #expect(required.permissions == ["tabs"])
        #expect(required.hosts == ["<all_urls>", "https://a.test/*"])
    }

    @Test func aManifestThatIsNotAnObjectIsRefused() {
        #expect(throws: ExtensionManifest.ParseError.notAnObject) { try ExtensionPermissionDiff.required(manifest: Data("[]".utf8)) }
    }

    @Test func addedIsWhatTheNewVersionRequiresAndTheOldDidNot() throws {
        let old = manifest(#"{"permissions":["storage"],"host_permissions":["https://example.com/*"]}"#)
        let new = manifest(#"{"permissions":["storage","tabs"],"host_permissions":["https://example.com/*","https://new.test/*"]}"#)
        let added = try ExtensionPermissionDiff.added(from: old, to: new)
        #expect(added.permissions == ["tabs"])
        #expect(added.hosts == ["https://new.test/*"])
    }

    @Test func anOptionalPermissionThatBecomesRequiredIsAdded() throws {
        let old = manifest(#"{"permissions":["storage"],"optional_permissions":["history"],"optional_host_permissions":["https://opt.test/*"]}"#)
        let new = manifest(#"{"permissions":["storage","history"],"host_permissions":["https://opt.test/*"]}"#)
        let added = try ExtensionPermissionDiff.added(from: old, to: new)
        #expect(added.permissions == ["history"])
        #expect(added.hosts == ["https://opt.test/*"])
    }

    @Test func aNewOptionalRequestAddsNothing() throws {
        let old = manifest(#"{"permissions":["storage"]}"#)
        let new = manifest(#"{"permissions":["storage"],"optional_permissions":["tabs"],"optional_host_permissions":["https://x.test/*"]}"#)
        let added = try ExtensionPermissionDiff.added(from: old, to: new)
        #expect(added.permissions.isEmpty)
        #expect(added.hosts.isEmpty)
    }

    @Test func dropsAndUnchangedManifestsAddNothing() throws {
        let old = manifest(#"{"permissions":["storage","tabs"],"host_permissions":["https://example.com/*"]}"#)
        let fewer = manifest(#"{"permissions":["storage"]}"#)
        let same = try ExtensionPermissionDiff.added(from: old, to: old)
        #expect(same.permissions.isEmpty && same.hosts.isEmpty)
        let dropped = try ExtensionPermissionDiff.added(from: old, to: fewer)
        #expect(dropped.permissions.isEmpty && dropped.hosts.isEmpty)
    }

    // MARK: - What a newer version asks the user

    /// An extension the user allowed `storage` and `https://example.com/*`, refused `tabs`, and left "Only When I Click"
    /// on `https://click.test/*`.
    func decisions() -> ExtensionDecisions {
        let snapshot = ExtensionSnapshot(
            name: "Sample", version: "1.0", decided: when,
            permissions: ["storage": .allow, "tabs": .deny],
            hosts: ["https://example.com/*": .allow, "https://click.test/*": .click],
            run: .allow
        )
        return ExtensionDecisions(byFolder: ["sample": snapshot])
    }

    @Test func aVersionAskingForNothingNewIsNotAsked() {
        let requested: ExtensionPermissionDiff.Requests = (["storage"], ["https://example.com/*"])
        let asks = ExtensionPermissionDiff.asks(
            requested: requested, added: ([], []), decisions: decisions(), folder: "sample", name: "Sample"
        )
        #expect(asks.permissions.isEmpty && asks.hosts.isEmpty)
    }

    @Test func anUndecidedRequestIsAskedAbout() {
        let requested: ExtensionPermissionDiff.Requests = (["storage", "downloads"], ["https://example.com/*"])
        let asks = ExtensionPermissionDiff.asks(
            requested: requested, added: (["downloads"], []), decisions: decisions(), folder: "sample", name: "Sample"
        )
        #expect(asks.permissions == ["downloads"])
        #expect(asks.hosts.isEmpty)
    }

    @Test func aRefusedRequestIsAskedAgainOnlyWhenTheVersionAddsIt() {
        let requested: ExtensionPermissionDiff.Requests = (["storage", "tabs"], [])
        // Added by this version: asked again.
        let added = ExtensionPermissionDiff.asks(
            requested: requested, added: (["tabs"], []), decisions: decisions(), folder: "sample", name: "Sample"
        )
        #expect(added.permissions == ["tabs"])
        // Requested by an earlier version and refused: the refusal stands, and nothing is asked.
        let unchanged = ExtensionPermissionDiff.asks(
            requested: requested, added: ([], []), decisions: decisions(), folder: "sample", name: "Sample"
        )
        #expect(unchanged.permissions.isEmpty)
    }

    @Test func onlyWhenIClickHostsAndAllowedHostsAreNotAskedAgain() {
        let requested: ExtensionPermissionDiff.Requests = ([], ["https://click.test/*", "https://example.com/*"])
        let asks = ExtensionPermissionDiff.asks(
            requested: requested, added: ([], ["https://click.test/*", "https://example.com/*"]),
            decisions: decisions(), folder: "sample", name: "Sample"
        )
        #expect(asks.hosts.isEmpty)
    }

    @Test func aNewHostIsAskedAbout() {
        let requested: ExtensionPermissionDiff.Requests = ([], ["https://new.test/*"])
        let asks = ExtensionPermissionDiff.asks(
            requested: requested, added: ([], ["https://new.test/*"]), decisions: decisions(), folder: "sample", name: "Sample"
        )
        #expect(asks.hosts == ["https://new.test/*"])
    }

    @Test func nativeMessagingIsNeverAsked() {
        let requested: ExtensionPermissionDiff.Requests = (["nativeMessaging"], [])
        let asks = ExtensionPermissionDiff.asks(
            requested: requested, added: (["nativeMessaging"], []), decisions: decisions(), folder: "sample", name: "Sample"
        )
        #expect(asks.permissions.isEmpty)
    }

    @Test func aDifferentNameMeansNothingWasGranted() {
        let requested: ExtensionPermissionDiff.Requests = (["storage"], ["https://example.com/*"])
        let asks = ExtensionPermissionDiff.asks(
            requested: requested, added: ([], []), decisions: decisions(), folder: "sample", name: "Another"
        )
        #expect(asks.permissions == ["storage"])
        #expect(asks.hosts == ["https://example.com/*"])
    }

    @Test func aFolderWithNoAnswersAsksForEverything() {
        let requested: ExtensionPermissionDiff.Requests = (["storage"], ["https://example.com/*"])
        let asks = ExtensionPermissionDiff.asks(
            requested: requested, added: ([], []), decisions: ExtensionDecisions(), folder: "sample", name: "Sample"
        )
        #expect(asks.permissions == ["storage"])
        #expect(asks.hosts == ["https://example.com/*"])
    }
}
