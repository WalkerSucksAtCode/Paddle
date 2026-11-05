import Foundation
@testable import PaddleCore
import Testing

struct ExtensionUpdateOutcomeTests {
    @Test func legacyLinesRoundTrip() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let up = ExtensionUpdateOutcome.fromLegacyStatusLine("up to date", installed: "1.0", at: at)
        #expect(up.kind == .upToDate && up.legacyStatusLine(installedVersion: "1.0") == "up to date")
        let updated = ExtensionUpdateOutcome.fromLegacyStatusLine("updated to 2.1.0", installed: "1.0", at: at)
        #expect(updated.kind == .updated && updated.storeVersion == "2.1.0")
        let waiting = ExtensionUpdateOutcome.fromLegacyStatusLine("update 3.0 waiting for permission", installed: "1.0", at: at)
        #expect(waiting.kind == .waitingPermission && waiting.storeVersion == "3.0")
        let failed = ExtensionUpdateOutcome.fromLegacyStatusLine("not updated: network error", installed: "1.0", at: at)
        #expect(failed.kind == .failed && failed.detail == "network error")
    }

    @Test func settingsSummaryDistinguishesUpToDateAndFailed() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        var adopted = ExtensionSources.Record(store: .mozillaAddons, id: "x@y", version: "1.2", adopted: true, lastOutcome: nil)
        adopted.verified = nil
        let up = ExtensionUpdateOutcome(kind: .upToDate, at: at, fromVersion: "1.2")
        #expect(up.settingsSummary(record: adopted).contains("no newer version"))
        let failed = ExtensionUpdateOutcome(kind: .failed, at: at, fromVersion: "1.2", detail: "network error")
        #expect(failed.settingsSummary(record: adopted).contains("Not updated"))
        let waiting = ExtensionUpdateOutcome(kind: .waitingPermission, at: at, fromVersion: "1.2", storeVersion: "1.3")
        #expect(waiting.settingsSummary(record: adopted).contains("1.3"))
    }

    @Test func batchSummaryCountsAndNote() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let outcomes: [String: ExtensionUpdateOutcome] = [
            "a": .init(kind: .updated, at: at, fromVersion: "1", storeVersion: "2"),
            "b": .init(kind: .upToDate, at: at, fromVersion: "1"),
            "c": .init(kind: .failed, at: at, detail: "timeout"),
        ]
        let batch = ExtensionUpdateBatchSummary.build(at: at, folderCount: 3, outcomes: outcomes)
        #expect(batch.updated == ["a"] && batch.upToDate == ["b"] && batch.failed == ["c"])
        let note = batch.settingsNote
        #expect(note.contains("1 updated") && note.contains("1 up to date") && note.contains("1 failed"))
        #expect(note.contains("Updated: a"))
    }

    @Test func lastOutcomePersistsOnRecord() throws {
        var sources = ExtensionSources()
        let outcome = ExtensionUpdateOutcome(kind: .updated, at: Date(timeIntervalSince1970: 1_791_000_000), fromVersion: "1.0", storeVersion: "2.0")
        sources.records["x"] = ExtensionSources.Record(
            store: .mozillaAddons, id: "a@b", version: "2.0", lastOutcome: outcome
        )
        let text = String(decoding: try sources.encoded(), as: UTF8.self)
        #expect(text.contains("lastOutcome"))
        let back = try ExtensionSources.decode(try sources.encoded())
        #expect(back.records["x"]?.lastOutcome == outcome)
    }
}
