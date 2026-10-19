import Foundation
import JavaScriptCore
@testable import PaddleCore
import Testing

struct ScriptLatin1Tests {
    /// `body` as the body of a classic script's `run` function.
    private func script(_ body: String) -> String { "function run() { \(body) }" }

    /// What `run()` in `script` returns, as JSON (nil when it throws).
    private func evaluate(_ script: String) -> String? {
        let context = JSContext()!
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        context.evaluateScript(script)
        let value = context.evaluateScript("JSON.stringify(run())")
        return failed ? nil : value?.toString()
    }

    private func rewritten(_ source: String) throws -> String {
        guard case .rewritten(let text) = ScriptLatin1.rewrite(source) else {
            Issue.record("not rewritten: \(ScriptLatin1.rewrite(source))")
            return source
        }
        return text
    }

    @Test(arguments: [
        #"return "Ābé" + 'ō';"#,
        #"return "\Ā";"#,
        #"const n = 2; return `${n}Ā${`ī${n}`}ū`;"#,
        "// Ā comment\nreturn 1; /* ō */",
        "var Āb = 3; return Āb * 2;",
        #"return ["😀".length, "😀" === "😀", new RegExp("😀", "u").test("😀")];"#,
        #"const a = 6, b = 3; return [a / b / 1, "Ā".length, a /b/ 2];"#,
        #"return { k: `Ā` }.k + (x => x)(`ā`);"#,
    ])
    func keepsMeaning(_ body: String) throws {
        let source = script(body)
        let output = try rewritten(source)
        #expect(output.unicodeScalars.allSatisfy { $0.value <= 0xFF }, "still has a character beyond Latin-1: \(output)")
        #expect(evaluate(output) != nil)
        #expect(evaluate(output) == evaluate(source))
    }

    @Test func leavesLatin1Alone() {
        #expect(ScriptLatin1.rewrite("const é = 'ü'; // ß") == .unchanged)
        #expect(ScriptLatin1.rewrite("let a = 1") == .unchanged)
    }

    @Test(arguments: [
        "const t = String.raw`Ā`;",
        "function tag(s) { return s.raw[0] } tag`ō`;",
        "const t = String.raw`${1}Ā`;",
        "// ends here\u{2028}const a = 'Ā';",
        "const a = 'Ā'\u{3000};",
        "var 𐐀 = 'Ā';",
        "const r = /Ā+/u;",
        #"const r = /a\Ā/;"#,
    ])
    func skipsWhatCouldChange(_ source: String) {
        guard case .skipped = ScriptLatin1.rewrite(source) else {
            Issue.record("expected a skip: \(ScriptLatin1.rewrite(source))")
            return
        }
    }

    @Test func dropsALeadingByteOrderMark() throws {
        let output = try rewritten("\u{FEFF}const a = 'Ā';")
        #expect(output == #"const a = '\u0100';"#)
    }

    @Test func overlayNarrowsContentScripts() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("paddle-latin1-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("const label = 'Ā';".utf8).write(to: work.appendingPathComponent("wide.js"))
        try Data("const t = String.raw`ō`;".utf8).write(to: work.appendingPathComponent("raw.js"))
        try Data("const ok = 1;".utf8).write(to: work.appendingPathComponent("plain.js"))
        let manifest = Data(#"{"content_scripts":[{"matches":["<all_urls>"],"js":["wide.js","raw.js","plain.js"]}]}"#.utf8)
        #expect(try ExtensionOverlay.narrowContentScripts(in: work, manifest: manifest, fileManager: fm) == 1)
        #expect(try String(contentsOf: work.appendingPathComponent("wide.js"), encoding: .utf8) == #"const label = '\u0100';"#)
        #expect(try String(contentsOf: work.appendingPathComponent("raw.js"), encoding: .utf8) == "const t = String.raw`ō`;")
    }
}
