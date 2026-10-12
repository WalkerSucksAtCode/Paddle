import Foundation
@testable import PaddleCore
import Testing

struct JSONSpansTests {
    static let three = "{\n  \"a\": 1,\n  \"b\": \"x, y\",\n  \"c\": {\"d\": [1, 2]}\n}\n"

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
    private func text(_ data: Data, _ range: Range<Int>) -> String { String(decoding: data[range], as: UTF8.self) }

    @Test func scanFindsTopLevelSpansOnly() throws {
        let data = Data(Self.three.utf8)
        let spans = try JSONSpans.scan(data)
        #expect(spans.members.map(\.key) == ["a", "b", "c"])
        let b = try #require(spans.member("b"))
        #expect(text(data, b.keyRange) == "\"b\"")
        #expect(text(data, b.valueRange) == "\"x, y\"")
        #expect(text(data, b.memberRange) == "\"b\": \"x, y\"")
        let c = try #require(spans.member("c"))
        #expect(text(data, c.valueRange) == "{\"d\": [1, 2]}")
        #expect(spans.object == ["a": 1, "b": "x, y", "c": ["d": [1, 2]]])
        #expect(spans.nestedKeys(of: "c") == ["d"])
        #expect(spans.nestedKeys(of: "a") == nil)
    }

    @Test func keysWithEscapesAndBracesInStrings() throws {
        let data = Data(#"{"a\"b": "}{", "c": "\\"}"#.utf8)
        let spans = try JSONSpans.scan(data)
        #expect(spans.members.map(\.key) == ["a\"b", "c"])
        #expect(spans.object == ["a\"b": "}{", "c": "\\"])
    }

    @Test func bomIsKeptThroughEdits() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let spans = try JSONSpans.scan(bom + Data("{\n  \"a\": 1\n}\n".utf8))
        #expect(spans.members.map(\.key) == ["a"])
        let appended = spans.appending("b", text: "2")
        #expect(appended.prefix(3) == bom)
        #expect(text(appended.dropFirst(3)) == "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
        #expect(try JSONSpans.scan(appended).object == ["a": 1, "b": 2])
    }

    @Test func emptyFileReadsAsEmptyObject() throws {
        for empty in [Data(), Data("  \n".utf8)] {
            let spans = try JSONSpans.scan(empty)
            #expect(spans.members.isEmpty)
            #expect(spans.object == [:])
            #expect(text(spans.appending("a", text: "1")) == "{\n  \"a\": 1\n}\n")
        }
        #expect(text(try JSONSpans.scan(Data("{}\n".utf8)).appending("a", text: "1")) == "{\n  \"a\": 1\n}\n")
    }

    @Test func nonObjectTopLevelIsAnError() {
        #expect(throws: JSONSpans.ScanError.notAnObject) { try JSONSpans.scan(Data("[1, 2]".utf8)) }
        #expect(throws: JSONSpans.ScanError.notAnObject) { try JSONSpans.scan(Data("\"text\"".utf8)) }
        do {
            _ = try JSONSpans.scan(Data("{\"a\": 1 \"b\": 2}".utf8))
            Issue.record("a missing comma should not scan")
        } catch JSONSpans.ScanError.invalidJSON(let why) {
            // The banner promises a location, which `localizedDescription` alone doesn't carry.
            #expect(why.contains("line 1"), "\(why)")
            #expect(why.contains("column"), "\(why)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func removeFirstMiddleLastRepairsCommas() throws {
        let spans = try JSONSpans.scan(Data(Self.three.utf8))
        #expect(text(spans.removing("a")) == "{\n  \"b\": \"x, y\",\n  \"c\": {\"d\": [1, 2]}\n}\n")
        #expect(text(spans.removing("b")) == "{\n  \"a\": 1,\n  \"c\": {\"d\": [1, 2]}\n}\n")
        #expect(text(spans.removing("c")) == "{\n  \"a\": 1,\n  \"b\": \"x, y\"\n}\n")
        for key in ["a", "b", "c"] {
            #expect(try JSONSpans.scan(spans.removing(key)).object.keys.sorted() == ["a", "b", "c"].filter { $0 != key })
        }
        #expect(text(try JSONSpans.scan(Data("{\n  \"a\": 1\n}\n".utf8)).removing("a")) == "{}\n")
    }

    @Test func replaceTouchesOnlyTheValueBytes() throws {
        let data = Data(Self.three.utf8)
        let spans = try JSONSpans.scan(data)
        let b = try #require(spans.member("b"))
        let replaced = spans.replacing("b", with: "\"new\"")
        #expect(replaced[..<b.valueRange.lowerBound] == data[..<b.valueRange.lowerBound])
        #expect(replaced[(b.valueRange.lowerBound + 5)...].elementsEqual(data[b.valueRange.upperBound...]))
        #expect(try JSONSpans.scan(replaced).object["b"] == "new")
    }

    @Test func appendUsesTheFilesOwnIndentAndColon() throws {
        let four = try JSONSpans.scan(Data("{\n    \"a\" : 1\n}\n".utf8))
        #expect(text(four.appending("b", text: "true")) == "{\n    \"a\" : 1,\n    \"b\" : true\n}\n")
        let inline = try JSONSpans.scan(Data("{\"a\": 1}".utf8))
        #expect(text(inline.appending("b", text: "2")) == "{\"a\": 1, \"b\": 2}")
        #expect(inline.text(for: ["x": 1], key: "b") == "{\"x\": 1}")
    }

    @Test func nestedRenderKeepsExistingOrderAndAppendsNewKeys() throws {
        let spans = try JSONSpans.scan(Data("{\n  \"shortcuts\": {\n    \"newTab\": \"cmd+t\",\n    \"closeTab\": \"none\"\n  }\n}\n".utf8))
        let value: JSONValue = ["closeTab": "none", "nextTab": "cmd+option+right", "newTab": "cmd+t", "back": "none"]
        #expect(spans.text(for: value, key: "shortcuts") == """
            {
                "newTab": "cmd+t",
                "closeTab": "none",
                "back": "none",
                "nextTab": "cmd+option+right"
              }
            """)
        #expect(spans.text(for: ["a", "b"], key: "filterLists") == "[\n    \"a\",\n    \"b\"\n  ]")
        #expect(spans.text(for: [:], key: "shortcuts") == "{}")
    }

    @Test func duplicateKeyEditsTheCopyFoundationReadsAndDropsTheRest() throws {
        // JSONSerialization and JSONDecoder both keep the first occurrence.
        let data = Data("{\n  \"a\": 4,\n  \"b\": 1,\n  \"a\": 6\n}\n".utf8)
        let spans = try JSONSpans.scan(data)
        #expect(spans.object == ["a": 4, "b": 1])
        #expect(text(data, try #require(spans.member("a")).valueRange) == "4")
        #expect(text(spans.replacing("a", with: "5")) == "{\n  \"a\": 5,\n  \"b\": 1\n}\n")
        #expect(text(spans.removing("a")) == "{\n  \"b\": 1\n}\n")
        #expect(text(try JSONSpans.scan(Data("{\"a\": 1, \"a\": 2, \"a\": 3}".utf8)).removing("a")) == "{}")
        let nested = try JSONSpans.scan(Data("{\"shortcuts\": {\"a\": \"x\", \"a\": \"y\"}}".utf8))
        #expect(nested.nestedKeys(of: "shortcuts") == ["a"])
        #expect(nested.text(for: ["a": "x", "b": "z"], key: "shortcuts") == "{\"a\": \"x\", \"b\": \"z\"}")
    }

    @Test func crlfFileKeepsItsLineEndings() throws {
        let spans = try JSONSpans.scan(Data("{\r\n  \"homepage\": \"x\"\r\n}\r\n".utf8))
        #expect(text(spans.appending("maxAwakeTabs", text: "4")) == "{\r\n  \"homepage\": \"x\",\r\n  \"maxAwakeTabs\": 4\r\n}\r\n")
        #expect(spans.text(for: ["a": 1], key: "shortcuts") == "{\r\n    \"a\": 1\r\n  }")
        #expect(text(try JSONSpans.scan(Data("{\r\n}\r\n".utf8)).appending("a", text: "1")) == "{\r\n  \"a\": 1\r\n}\r\n")
    }

    @Test func indentComesFromTheFirstMemberOnItsOwnLine() throws {
        let spans = try JSONSpans.scan(Data("{ \"homepage\": \"x\",\n  \"shortcuts\": {\"a\": \"cmd+1\"}\n}\n".utf8))
        #expect(text(spans.appending("maxAwakeTabs", text: "4"))
            == "{ \"homepage\": \"x\",\n  \"shortcuts\": {\"a\": \"cmd+1\"},\n  \"maxAwakeTabs\": 4\n}\n")
        #expect(spans.text(for: ["a": 1], key: "shortcuts") == "{\n    \"a\": 1\n  }")
    }

    @Test func utf16FileIsRefusedByName() throws {
        // With a BOM, JSONSerialization reads the file, so the gate here is what names the problem.
        #expect(try JSONSerialization.jsonObject(with: #require("{\"a\": 1}".data(using: .utf16))) is [String: Any])
        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf32] {
            let data = try #require("{\"a\": 1}".data(using: encoding))
            #expect(throws: JSONSpans.ScanError.notUTF8) { try JSONSpans.scan(data) }
        }
    }

    @Test func rendersValuesLikeEncoded() {
        #expect(JSONValue.number(30).render() == "30")
        #expect(JSONValue.number(0.5).render() == "0.5")
        #expect(JSONValue.string("a/b \"c\" \\ \n\u{1}é").render() == #""a/b \"c\" \\ \n\u0001é""#)
        #expect(JSONValue.bool(false).render() == "false")
        #expect(JSONValue(NSNumber(value: true)) == .bool(true))
        #expect(JSONValue(NSNumber(value: 1)) == .number(1))
        #expect(JSONValue.bool(true) != JSONValue.number(1))
    }
}
