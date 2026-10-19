import Foundation
@testable import PaddleCore
import Testing

struct ConfigFileTests {
    /// The shape of an old full `encoded()` dump: every key of that version, sorted, `"key" : value`, empty
    /// objects on three lines. Synthetic values, not anyone's file.
    static let oldFullDump = """
        {
          "contentBlocking" : true,
          "developerTools" : true,
          "filterLists" : [
            "https://easylist.to/easylist/easylist.txt",
            "https://easylist.to/easylist/easyprivacy.txt"
          ],
          "homepage" : "https://example.org/start",
          "maxAwakeTabs" : 6,
          "newTabPage" : "about:blank",
          "searchTemplate" : "https://duckduckgo.com/?q=%s",
          "shortcuts" : {

          },
          "showTabMemory" : true,
          "siteUserAgents" : {

          },
          "sleepPinnedTabs" : false,
          "tabSleepAfterMinutes" : 30,
          "userAgentSuffix" : ""
        }

        """

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func applied(_ changes: [ConfigChange], to disk: String, base: String? = nil) throws -> String {
        text(try ConfigFile.apply(changes: changes, base: data(base ?? disk), disk: data(disk)).get())
    }

    @Test func oldFullDumpToggleIsAOneLineDiff() throws {
        let fixture = Self.oldFullDump
        #expect(try JSONSpans.scan(data(fixture)).members.count == 13)
        let result = try applied([ConfigChange("showTabMemory", false)], to: fixture)
        let before = fixture.split(separator: "\n", omittingEmptySubsequences: false)
        let after = result.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(before.count == after.count)
        let changed = zip(before, after).filter { $0 != $1 }
        #expect(changed.count == 1)
        #expect(changed.first?.0 == "  \"showTabMemory\" : true,")
        #expect(changed.first?.1 == "  \"showTabMemory\" : false,")
        var expected = try PaddleConfig.decode(data(fixture))
        expected.showTabMemory = false
        #expect(try PaddleConfig.decode(data(result)) == expected)
    }

    @Test func untouchedDefaultKeysAreKeptAndBytesOutsideTheSpanAreUnchanged() throws {
        let disk = "{\n  \"showTabMemory\": true,\n  \"maxAwakeTabs\": 4,\n  \"unknownKey\": [1, {\"x\": null}]\n}\n"
        let result = try applied([ConfigChange("maxAwakeTabs", 7)], to: disk)
        #expect(result == "{\n  \"showTabMemory\": true,\n  \"maxAwakeTabs\": 7,\n  \"unknownKey\": [1, {\"x\": null}]\n}\n")
        #expect(try ConfigFile.unknownKeys(in: data(result)) == ["unknownKey"])
    }

    @Test func defaultValueRemovesTheKey() throws {
        #expect(try applied([ConfigChange("maxAwakeTabs", 8)], to: "{\n  \"maxAwakeTabs\": 4\n}\n") == "{}\n")
        #expect(try applied([ConfigChange("maxAwakeTabs", 8)], to: "{\n  \"homepage\": \"x\",\n  \"maxAwakeTabs\": 4\n}\n")
            == "{\n  \"homepage\": \"x\"\n}\n")
        #expect(try applied([ConfigChange("tabSleepAfterMinutes", 5.0)], to: "{\n  \"tabSleepAfterMinutes\": 30,\n  \"homepage\": \"x\"\n}\n")
            == "{\n  \"homepage\": \"x\"\n}\n")
        // Removing a key that isn't there, or setting a default into a file that lacks it, changes nothing.
        #expect(try applied([ConfigChange("maxAwakeTabs", nil), ConfigChange("historyDays", 365)], to: "{\"homepage\": \"x\"}") == "{\"homepage\": \"x\"}")
    }

    @Test func sameValueRewritesNothing() throws {
        let disk = "{\n  \"tabSleepAfterMinutes\": 15.0,\n  \"homepage\": \"x\"\n}\n"
        #expect(try applied([ConfigChange("tabSleepAfterMinutes", 15)], to: disk) == disk)
    }

    @Test func newKeyIsAppendedInTheFilesIndent() throws {
        #expect(try applied([ConfigChange("historyDays", 30)], to: "{\n    \"homepage\" : \"x\"\n}\n")
            == "{\n    \"homepage\" : \"x\",\n    \"historyDays\" : 30\n}\n")
        #expect(try applied([ConfigChange("filterLists", ["https://a.example/list.txt"])], to: "{\n  \"homepage\": \"x\"\n}\n")
            == "{\n  \"homepage\": \"x\",\n  \"filterLists\": [\n    \"https://a.example/list.txt\"\n  ]\n}\n")
    }

    @Test func conflictWritesNothing() {
        let base = "{\n  \"maxAwakeTabs\": 4\n}\n"
        let disk = "{\n  \"maxAwakeTabs\": 5\n}\n"
        let result = ConfigFile.apply(changes: [ConfigChange("maxAwakeTabs", 8), ConfigChange("homepage", "x")], base: data(base), disk: data(disk))
        #expect(result == .failure(.conflict([["maxAwakeTabs"]])))
        // A key the hand edit didn't touch is not a conflict, and the hand edit survives.
        let other = ConfigFile.apply(changes: [ConfigChange("homepage", "x")], base: data(base), disk: data(disk))
        #expect(other.map(text) == .success("{\n  \"maxAwakeTabs\": 5,\n  \"homepage\": \"x\"\n}\n"))
        // Nested paths compare the entry, not the whole object.
        let nestedBase = "{\"shortcuts\": {\"newTab\": \"cmd+t\"}}"
        let nestedDisk = "{\"shortcuts\": {\"newTab\": \"cmd+t\", \"back\": \"none\"}}"
        #expect(ConfigFile.apply(changes: [ConfigChange("shortcuts", "newTab", "cmd+n")], base: data(nestedBase), disk: data(nestedDisk)).map(text)
            == .success("{\"shortcuts\": {\"newTab\": \"cmd+n\", \"back\": \"none\"}}"))
        #expect(ConfigFile.apply(changes: [ConfigChange("shortcuts", "back", nil)], base: data(nestedBase), disk: data(nestedDisk))
            == .failure(.conflict([["shortcuts", "back"]])))
    }

    @Test func conflictComparesValuesNotBytes() {
        // 30 and 30.0 are the same number; true and 1 are not the same value.
        #expect(ConfigFile.apply(changes: [ConfigChange("tabSleepAfterMinutes", 7)], base: data("{\"tabSleepAfterMinutes\": 30.0}"), disk: data("{\"tabSleepAfterMinutes\" : 30}")).map(text)
            == .success("{\"tabSleepAfterMinutes\" : 7}"))
        #expect(ConfigFile.apply(changes: [ConfigChange("flag", false)], base: data("{\"flag\": 1}"), disk: data("{\"flag\": true}"))
            == .failure(.conflict([["flag"]])))
        #expect(ConfigFile.apply(changes: [ConfigChange("homepage", "x")], base: data("{ \"homepage\" :\"a\" }"), disk: data("{\"homepage\":\"a\"}")).map(text)
            == .success("{\"homepage\":\"x\"}"))
    }

    @Test func nestedShortcutsEditKeepsOrder() throws {
        let disk = "{\n  \"homepage\": \"x\",\n  \"shortcuts\": {\n    \"newTab\": \"cmd+t\",\n    \"closeTab\": \"none\"\n  },\n  \"maxAwakeTabs\": 4\n}\n"
        let result = try applied([ConfigChange("shortcuts", "nextTab", "cmd+option+right"), ConfigChange("shortcuts", "closeTab", "cmd+shift+w")], to: disk)
        #expect(result == "{\n  \"homepage\": \"x\",\n  \"shortcuts\": {\n    \"newTab\": \"cmd+t\",\n    \"closeTab\": \"cmd+shift+w\",\n    \"nextTab\": \"cmd+option+right\"\n  },\n  \"maxAwakeTabs\": 4\n}\n")
        #expect(try JSONSpans.scan(data(result)).nestedKeys(of: "shortcuts") == ["newTab", "closeTab", "nextTab"])
    }

    @Test func emptiedObjectIsRemoved() throws {
        let disk = "{\n  \"shortcuts\": {\n    \"newTab\": \"cmd+t\"\n  },\n  \"homepage\": \"x\"\n}\n"
        #expect(try applied([ConfigChange("shortcuts", "newTab", nil)], to: disk) == "{\n  \"homepage\": \"x\"\n}\n")
        #expect(try applied([ConfigChange("siteUserAgents", [:])], to: "{\"siteUserAgents\": {\"a.example\": \"UA\"}}") == "{}")
    }

    @Test func extensionOnIsTheDefaultEntry() throws {
        #expect(try applied([ConfigChange("extensions", "protonpass", false)], to: "{}\n")
            == "{\n  \"extensions\": {\n    \"protonpass\": false\n  }\n}\n")
        #expect(try applied([ConfigChange("extensions", "protonpass", true)], to: "{\n  \"extensions\": {\n    \"protonpass\": false\n  }\n}\n") == "{}\n")
        #expect(try applied([ConfigChange("extensions", "other", true)], to: "{\"extensions\": {\"protonpass\": false}}")
            == "{\"extensions\": {\"protonpass\": false}}")
    }

    @Test func emptyFileBecomesAnObject() throws {
        #expect(try applied([ConfigChange("maxAwakeTabs", 4)], to: "") == "{\n  \"maxAwakeTabs\": 4\n}\n")
        #expect(try applied([ConfigChange("maxAwakeTabs", 8)], to: "") == "")
        #expect(try applied([ConfigChange("maxAwakeTabs", 4)], to: "{}\n") == "{\n  \"maxAwakeTabs\": 4\n}\n")
    }

    @Test func bomSurvives() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let result = try ConfigFile.apply(changes: [ConfigChange("maxAwakeTabs", 4)], base: bom + data("{}"), disk: bom + data("{}")).get()
        #expect(result == bom + data("{\n  \"maxAwakeTabs\": 4\n}"))
        #expect(try PaddleConfig.decode(result).maxAwakeTabs == 4)
    }

    @Test func badFilesAndPathsAreRefused() {
        let array = ConfigFile.apply(changes: [ConfigChange("maxAwakeTabs", 4)], base: data("[]"), disk: data("[]"))
        #expect(array == .failure(.invalidFile("config.json must be a JSON object: { ... }")))
        if case .failure(.invalidFile(let why)) = ConfigFile.apply(changes: [], base: data("{}"), disk: data("{\"a\": }")) {
            #expect(!why.isEmpty)
        } else {
            Issue.record("broken JSON should be an invalid file")
        }
        #expect(ConfigFile.apply(changes: [ConfigChange(path: [], value: 1)], base: data("{}"), disk: data("{}")) == .failure(.badPath([])))
        #expect(ConfigFile.apply(changes: [ConfigChange("homepage", "x", "y")], base: data("{\"homepage\": \"a\"}"), disk: data("{\"homepage\": \"a\"}"))
            == .failure(.badPath(["homepage", "x"])))
    }

    @Test func wrongTypeIsAnInvalidResultBeforeAnythingIsWritten() {
        if case .failure(.invalidResult(let why)) = ConfigFile.apply(changes: [ConfigChange("maxAwakeTabs", "four")], base: data("{}"), disk: data("{}")) {
            #expect(why.hasPrefix("maxAwakeTabs:"), "\(why)")
        } else {
            Issue.record("a string for an Int key must not produce a file")
        }
    }

    @Test func editElsewhereSucceedsBesideAWrongTypedValue() throws {
        // The bad value is someone's hand edit: it survives, and the edit to another key still lands.
        let disk = "{\n  \"maxAwakeTabs\": \"four\",\n  \"homepage\": \"x\"\n}\n"
        let result = try applied([ConfigChange("historyDays", 30)], to: disk)
        #expect(result == "{\n  \"maxAwakeTabs\": \"four\",\n  \"homepage\": \"x\",\n  \"historyDays\": 30\n}\n")
        #expect(try PaddleConfig.decodeReportingIssues(data(result)).issues.map(\.path) == [["maxAwakeTabs"]])
    }

    @Test func editOntoAnEntryPaddleSkipsIsRefused() throws {
        // `zoom` is wrong, so Paddle skips the whole a.com entry; writing a sibling field into it would keep it skipped.
        let disk = "{\"sites\": {\"a.com\": {\"zoom\": \"big\"}}}"
        let result = ConfigFile.apply(changes: [ConfigChange(path: ["sites", "a.com", "javaScript"], value: .bool(false))], base: data(disk), disk: data(disk))
        if case .failure(.invalidResult(let why)) = result {
            #expect(why.hasPrefix("sites.a.com: Expected a number for zoom in this entry."), "\(why)")
        } else {
            Issue.record("an edit inside a skipped entry must be refused, got \(result)")
        }
        // Fixing the value in the same edit is fine: the entry decodes again.
        let fixed = try ConfigFile.apply(changes: [ConfigChange(path: ["sites", "a.com", "zoom"], value: .number(1.5))], base: data(disk), disk: data(disk)).get()
        #expect(try PaddleConfig.decode(fixed).sites == ["a.com": SiteSettings(zoom: 1.5)])
    }

    @Test func editOntoAnUnknownWordIsRefused() {
        let disk = "{\"sites\": {\"a.com\": {\"zoom\": 1.5}}}"
        let result = ConfigFile.apply(changes: [ConfigChange(path: ["sites", "a.com", "autoplay"], value: .string("loud"))], base: data(disk), disk: data(disk))
        if case .failure(.invalidResult(let why)) = result {
            #expect(why.hasPrefix("sites.a.com: Expected one of the allowed words for autoplay in this entry."), "\(why)")
        } else {
            Issue.record("an unknown autoplay word must not produce a file, got \(result)")
        }
    }

    @Test func tidyLeavesEntriesPaddleSkipsAlone() throws {
        let disk = "{\"sites\": {\"a.com\": {\"zoom\": \"big\", \"javaScript\": true}, \"b.com\": {\"javaScript\": true}}}"
        let tidy = try ConfigFile.tidy(data(disk)).get()
        #expect(tidy.removed == [["sites", "b.com", "javaScript"]])
        #expect(try JSONSpans.scan(tidy.data).object["sites"] == .object([
            "a.com": .object(["zoom": "big", "javaScript": true]),
            "b.com": .object([:]),
        ]))
    }

    @Test func duplicatedKeyIsSetOrRemovedAsOne() throws {
        // The first copy is the one the app runs with; the edit changes it and drops the stale second copy.
        let dup = "{\n  \"maxAwakeTabs\" : 10,\n  \"homepage\" : \"x\",\n  \"maxAwakeTabs\": 6\n}\n"
        #expect(try applied([ConfigChange("maxAwakeTabs", 4)], to: dup) == "{\n  \"maxAwakeTabs\" : 4,\n  \"homepage\" : \"x\"\n}\n")
        #expect(try applied([ConfigChange("maxAwakeTabs", nil)], to: dup) == "{\n  \"homepage\" : \"x\"\n}\n")
        #expect(try applied([ConfigChange("homepage", "y")], to: dup) == "{\n  \"maxAwakeTabs\" : 10,\n  \"homepage\" : \"y\",\n  \"maxAwakeTabs\": 6\n}\n")
        let tidy = try ConfigFile.tidy(data("{\"maxAwakeTabs\": 8, \"maxAwakeTabs\": 6, \"homepage\": \"x\"}")).get()
        #expect(tidy.removed == [["maxAwakeTabs"]])
        #expect(text(tidy.data) == "{\"homepage\": \"x\"}")
    }

    @Test func utf16FileIsAnInvalidFileWithASpecificMessage() throws {
        let utf16 = try #require("{\"maxAwakeTabs\": 4}".data(using: .utf16))
        #expect(try PaddleConfig.decode(utf16).maxAwakeTabs == 4)
        #expect(ConfigFile.apply(changes: [ConfigChange("homepage", "x")], base: utf16, disk: utf16)
            == .failure(.invalidFile("config.json must be saved as UTF-8")))
        #expect(ConfigFile.tidy(utf16) == .failure(.invalidFile("config.json must be saved as UTF-8")))
    }

    @Test func tidyListsAndRemovesDefaultsOnly() throws {
        let disk = """
            {
              "showTabMemory" : true,
              "maxAwakeTabs" : 4,
              "filterLists" : [
                "https://easylist.to/easylist/easylist.txt",
                "https://easylist.to/easylist/easyprivacy.txt"
              ],
              "extensions" : {"a" : true, "b" : false},
              "unknownKey" : true,
              "shortcuts" : {}
            }

            """
        let tidy = try ConfigFile.tidy(data(disk)).get()
        #expect(tidy.removed == [["showTabMemory"], ["filterLists"], ["extensions", "a"], ["shortcuts"]])
        #expect(text(tidy.data) == "{\n  \"maxAwakeTabs\" : 4,\n  \"extensions\" : {\n    \"b\": false\n  },\n  \"unknownKey\" : true\n}\n")
        #expect(try ConfigFile.tidy(data("{\"maxAwakeTabs\": 4}")).get() == ConfigFile.TidyResult(removed: [], data: data("{\"maxAwakeTabs\": 4}")))
    }

    @Test func tidyDropsShortcutsThatRepeatTheDefaultAndSiteFieldsAtDefaults() throws {
        let standard: [String: Shortcut] = [
            "togglePin": Shortcut(key: ""),
            "newTab": Shortcut(key: "t", command: true),
            "closeTab": Shortcut(key: "w", command: true),
        ]
        let disk = """
            {
              "shortcuts" : {"togglePin": "none", "newTab": "Command+T", "closeTab": "none", "mystery": "none", "bad": "x+"},
              "sites" : {
                "a.com": {"zoom": 1, "javaScript": true, "autoplay": "muted", "contentBlocking": true, "location": "ask"},
                "b.com": {"zoom": 1.25, "javaScript": true, "autoplay": "block", "location": "deny"},
                "c.com": {"zoom": 1.5}
              }
            }

            """
        let tidy = try ConfigFile.tidy(data(disk), shortcutDefaults: standard).get()
        #expect(tidy.removed == [
            ["shortcuts", "togglePin"], ["shortcuts", "newTab"],
            ["sites", "a.com", "autoplay"], ["sites", "a.com", "contentBlocking"], ["sites", "a.com", "javaScript"],
            ["sites", "a.com", "location"], ["sites", "b.com", "javaScript"],
        ])
        let after = try JSONSpans.scan(tidy.data).object
        #expect(after["shortcuts"] == .object(["closeTab": "none", "mystery": "none", "bad": "x+"]))
        // The entry stays, empty, until Remove Site; the others keep their non-default fields.
        #expect(after["sites"] == .object([
            "a.com": .object(["zoom": 1]),
            "b.com": .object(["zoom": 1.25, "autoplay": "block", "location": "deny"]),
            "c.com": .object(["zoom": 1.5]),
        ]))
        #expect(try ConfigFile.tidy(data("{\"shortcuts\": {\"togglePin\": \"none\"}}")).get().removed == [])
    }

    @Test func applyEditsOneFieldOfASitesEntry() throws {
        let disk = "{\"sites\": {\"a.com\": {\"zoom\": 1.5, \"javaScript\": false}}}"
        let result = try applied([ConfigChange(path: ["sites", "a.com", "zoom"], value: nil)], to: disk)
        #expect(try JSONSpans.scan(data(result)).object["sites"] == .object(["a.com": .object(["javaScript": false])]))
        #expect(ConfigFile.apply(changes: [ConfigChange(path: ["sites", "a.com", "zoom", "x"], value: nil)], base: data(disk), disk: data(disk))
            == .failure(.badPath(["sites", "a.com", "zoom", "x"])))
    }

    @Test func unknownKeysAreListedInFileOrder() throws {
        #expect(try ConfigFile.unknownKeys(in: data("{\"zeta\": 1, \"homepage\": \"x\", \"alpha\": {}, \"zeta\": 2}")) == ["zeta", "alpha"])
        #expect(try ConfigFile.unknownKeys(in: Data()) == [])
        let withDefaults = PaddleConfig.CodingKeys.allCases.filter { !PaddleConfig.leftOutByDefault.contains($0) }
        #expect(ConfigFile.defaults.keys.sorted() == withDefaults.map(\.rawValue).sorted())
    }
}
