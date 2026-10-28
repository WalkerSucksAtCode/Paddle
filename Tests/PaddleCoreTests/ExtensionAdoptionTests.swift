import Foundation
@testable import PaddleCore
import Testing

struct ExtensionAdoptionTests {
    private func manifest(_ json: String) -> Data { Data(json.utf8) }

    @Test func readsTheGeckoID() {
        #expect(ExtensionAdoption.geckoID(manifest: manifest(#"{"browser_specific_settings":{"gecko":{"id":"a@b"}}}"#)) == "a@b")
        #expect(ExtensionAdoption.geckoID(manifest: manifest(#"{"applications":{"gecko":{"id":"{x-y}"}}}"#)) == "{x-y}")
        #expect(ExtensionAdoption.geckoID(manifest: manifest(#"{"browser_specific_settings":{"gecko":{}},"applications":{"gecko":{"id":"c@d"}}}"#)) == "c@d")
        #expect(ExtensionAdoption.geckoID(manifest: manifest(#"{"name":"x"}"#)) == nil)
        #expect(ExtensionAdoption.geckoID(manifest: manifest(#"{"browser_specific_settings":{"gecko":{"id":5}}}"#)) == nil)
        #expect(ExtensionAdoption.geckoID(manifest: manifest("not json")) == nil)
    }

    @Test func candidateRules() {
        let m = manifest(#"{"browser_specific_settings":{"gecko":{"id":"a@b"}}}"#)
        var sources = ExtensionSources()
        #expect(ExtensionAdoption.candidateGeckoID(folder: "pass", manifest: m, sources: sources) == "a@b")
        #expect(ExtensionAdoption.candidateGeckoID(folder: ".staged-pass", manifest: m, sources: sources) == nil)
        #expect(ExtensionAdoption.candidateGeckoID(folder: "a/b", manifest: m, sources: sources) == nil)
        #expect(ExtensionAdoption.candidateGeckoID(folder: "", manifest: m, sources: sources) == nil)
        #expect(ExtensionAdoption.candidateGeckoID(folder: "pass", manifest: manifest("{}"), sources: sources) == nil)
        sources.declineAdoption(folder: "pass")
        #expect(ExtensionAdoption.candidateGeckoID(folder: "pass", manifest: m, sources: sources) == nil)
        sources.clearDeclinedAdoption(folder: "pass")
        sources.records["pass"] = .init(store: .chromeWebStore, id: "x")
        #expect(ExtensionAdoption.candidateGeckoID(folder: "pass", manifest: m, sources: sources) == nil)
    }

    @Test func lookupMustNameTheSameID() {
        #expect(ExtensionAdoption.acceptsLookup(guid: "a@b", geckoID: "a@b"))
        #expect(!ExtensionAdoption.acceptsLookup(guid: "A@b", geckoID: "a@b"))
        #expect(!ExtensionAdoption.acceptsLookup(guid: "a@b ", geckoID: "a@b"))
        #expect(!ExtensionAdoption.acceptsLookup(guid: "", geckoID: ""))
    }

    @Test func onlyAdoptedRecordsAlertOnFirstUpdate() {
        #expect(ExtensionAdoption.needsAlertOnFirstUpdate(record: .init(store: .mozillaAddons, id: "a", adopted: true)))
        #expect(!ExtensionAdoption.needsAlertOnFirstUpdate(record: .init(store: .mozillaAddons, id: "a")))
        #expect(!ExtensionAdoption.needsAlertOnFirstUpdate(record: .init(store: .mozillaAddons, id: "a", adopted: false)))
    }
}
