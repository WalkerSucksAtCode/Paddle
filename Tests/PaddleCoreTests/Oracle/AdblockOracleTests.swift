import Foundation
@testable import PaddleCore
import Testing

/// Opt-in oracle: Paddle's converter against uBlock Origin's recorded decisions.
///
/// Run: `PADDLE_ORACLE=1 swift test --filter AdblockOracle`. Optional: `PADDLE_ORACLE_DIR` (default
/// `build/oracle`) and `PADDLE_ORACLE_LIMIT` (rows; default all). Report: `<data directory>/report.txt`.
///
/// WebKit applies each list on its own; as in the app, each list is converted with the other's `@@`
/// exceptions, so one list's exception still cancels the other's block. Paddle blocks if either list does.
///
/// Disagreement is reported, not failed. Fails if the data is missing, or if the token index disagrees
/// with brute force on the first 300 rows.
struct AdblockOracleTests {
    static let header = "url\tsourceUrl\ttype\tblocked\tfilter"

    /// One TSV row: `blocked` is uBO's value (1 blocked, 0 no filter, 2 an exception allowed it).
    struct Row {
        let url: String
        let sourceURL: String
        let type: String
        let blocked: Int
        let filter: String

        init?(_ line: Substring) {
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, let blocked = Int(fields[3]) else { return nil }
            url = String(fields[0])
            sourceURL = String(fields[1])
            type = String(fields[2])
            self.blocked = blocked
            filter = String(fields[4])
        }

        /// uBO blocked it (value 1). Value 2 is a block filter an exception allowed: not blocked.
        var uboBlocked: Bool { blocked == 1 }
    }

    /// Counts for one slice of rows, from uBO's and Paddle's decisions.
    struct Tally {
        var rows = 0
        var uboBlocked = 0
        var paddleBlocked = 0
        var bothBlock = 0
        var bothAllow = 0
        var paddleOnly = 0
        var uboOnly = 0

        mutating func add(ubo: Bool, paddle: Bool) {
            rows += 1
            if ubo { uboBlocked += 1 }
            if paddle { paddleBlocked += 1 }
            switch (ubo, paddle) {
            case (true, true): bothBlock += 1
            case (false, false): bothAllow += 1
            case (false, true): paddleOnly += 1
            case (true, false): uboOnly += 1
            }
        }

        var agreement: Double { rows == 0 ? 100 : Double(bothBlock + bothAllow) / Double(rows) * 100 }
    }

    /// One group of rows sharing a filter, with its first example.
    struct Example {
        var count = 0
        var url = ""
        var sourceURL = ""
        /// Rows where uBO's value was 2 (an exception allowed it).
        var uboException = 0

        mutating func add(url: String, sourceURL: String, uboValue: Int) {
            if count == 0 {
                self.url = url
                self.sourceURL = sourceURL
            }
            count += 1
            if uboValue == 2 { uboException += 1 }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PADDLE_ORACLE"] == "1"), .timeLimit(.minutes(60)))
    func paddleAgreesWithUBlockOrigin() throws {
        let env = ProcessInfo.processInfo.environment
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Oracle
            .deletingLastPathComponent()  // PaddleCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let dataDir = env["PADDLE_ORACLE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? repoRoot.appending(path: "build/oracle", directoryHint: .isDirectory)
        let easylistURL = dataDir.appending(path: "easylist.txt")
        let easyprivacyURL = dataDir.appending(path: "easyprivacy.txt")
        let tsvURL = dataDir.appending(path: "ublock-matches.tsv")
        for url in [easylistURL, easyprivacyURL, tsvURL] {
            try #require(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        }

        let clock = ContinuousClock()

        // Conversion as the app does it: each list with the other's `@@` exceptions (`SharedExceptions.adding`).
        let convertStart = clock.now
        let easyText = try String(contentsOf: easylistURL, encoding: .utf8)
        let privacyText = try String(contentsOf: easyprivacyURL, encoding: .utf8)
        let easyResult = FilterListConverter.convert(easyText, shared: SharedExceptions.none.adding([SharedExceptions.listExceptions(in: privacyText)]))
        let privacyResult = FilterListConverter.convert(privacyText, shared: SharedExceptions.none.adding([SharedExceptions.listExceptions(in: easyText)]))
        let easy = try WebKitRuleEvaluator(json: easyResult.json)
        let privacy = try WebKitRuleEvaluator(json: privacyResult.json)
        let convertTime = clock.now - convertStart

        // Data.
        let parseStart = clock.now
        let tsv = try String(contentsOf: tsvURL, encoding: .utf8)
        let lines = tsv.split(whereSeparator: \.isNewline)
        try #require(lines.first == Substring(Self.header), "unexpected TSV header")
        let limit = Int(env["PADDLE_ORACLE_LIMIT"] ?? "") ?? lines.count
        let rows = lines.dropFirst().prefix(limit).compactMap(Row.init)
        let parseTime = clock.now - parseStart

        // Self-check: the token index against brute force, first 300 rows, both lists.
        let selfCheckStart = clock.now
        var selfCheckFailures: [String] = []
        let selfCheckRows = rows.prefix(300)
        for row in selfCheckRows {
            let request = Self.request(for: row)
            for (name, evaluator) in [("easylist", easy), ("easyprivacy", privacy)] where !evaluator.indexedMatchesBruteForce(request) {
                selfCheckFailures.append("\(name): \(row.type) \(row.url) from \(row.sourceURL)")
            }
        }
        let selfCheckTime = clock.now - selfCheckStart

        // Full run.
        var overall = Tally()
        var perType: [String: Tally] = [:]
        var unknownTypes: [String: Int] = [:]
        var misses: [String: Example] = [:]
        var overBlocks: [String: Example] = [:]
        var subFrameSameSource = 0
        var subFrameRows = 0
        let evaluateStart = clock.now
        for row in rows {
            let request = Self.request(for: row)
            if WebKitRuleEvaluator.webKitType(uboType: row.type) == nil { unknownTypes[row.type, default: 0] += 1 }
            if row.type == "sub_frame" {
                subFrameRows += 1
                if row.url == row.sourceURL { subFrameSameSource += 1 }
            }
            let easyDecision = easy.evaluate(request)
            let privacyDecision = privacy.evaluate(request)
            let paddleBlocked = easyDecision.blocked || privacyDecision.blocked
            overall.add(ubo: row.uboBlocked, paddle: paddleBlocked)
            perType[row.type, default: Tally()].add(ubo: row.uboBlocked, paddle: paddleBlocked)

            if row.uboBlocked, !paddleBlocked {
                misses[row.filter, default: Example()].add(url: row.url, sourceURL: row.sourceURL, uboValue: row.blocked)
            } else if paddleBlocked, !row.uboBlocked {
                let (list, filter) = easyDecision.blocked
                    ? ("easylist", easyDecision.decidingURLFilter ?? "?")
                    : ("easyprivacy", privacyDecision.decidingURLFilter ?? "?")
                overBlocks["\(list)  \(filter)", default: Example()]
                    .add(url: row.url, sourceURL: row.sourceURL, uboValue: row.blocked)
            }
        }
        let evaluateTime = clock.now - evaluateStart

        let report = Self.report(
            dataDir: dataDir,
            rowCount: rows.count,
            overall: overall,
            perType: perType,
            unknownTypes: unknownTypes,
            misses: misses,
            overBlocks: overBlocks,
            subFrame: (subFrameRows, subFrameSameSource),
            conversions: [("easylist.txt", easyResult), ("easyprivacy.txt", privacyResult)],
            evaluators: [("easylist.txt", easy), ("easyprivacy.txt", privacy)],
            timing: [
                ("convert both lists", convertTime),
                ("parse TSV", parseTime),
                ("self-check (\(selfCheckRows.count) rows, both lists)", selfCheckTime),
                ("evaluate \(rows.count) rows, both lists", evaluateTime),
            ],
            selfCheck: (selfCheckRows.count, selfCheckFailures)
        )
        let reportURL = dataDir.appending(path: "report.txt")
        try report.full.write(to: reportURL, atomically: true, encoding: .utf8)
        print(report.summary)
        print("Full report: \(reportURL.path)")

        #expect(selfCheckFailures.isEmpty, "index disagrees with brute force: \(selfCheckFailures.prefix(5).joined(separator: "; "))")
    }

    static func request(for row: Row) -> WebKitRuleEvaluator.Request {
        WebKitRuleEvaluator.Request(
            url: row.url,
            sourceURL: row.sourceURL,
            resourceType: WebKitRuleEvaluator.webKitType(uboType: row.type) ?? row.type,
            isChildFrame: row.type == "sub_frame"
        )
    }

    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    static func ranked<T>(_ dictionary: [String: T], count: (T) -> Int, limit: Int) -> [(String, T)] {
        Array(dictionary.sorted { lhs, rhs in
            count(lhs.value) != count(rhs.value) ? count(lhs.value) > count(rhs.value) : lhs.key < rhs.key
        }.prefix(limit))
    }

    /// One header line and one row per uBO type, sorted by type.
    static func typeTable(_ perType: [String: Tally]) -> [String] {
        var lines = ["type            rows   uBO   Paddle  both-block  both-allow  Paddle-only  uBO-only  agree"]
        for (type, tally) in perType.sorted(by: { $0.key < $1.key }) {
            let padded = type.padding(toLength: 14, withPad: " ", startingAt: 0)
            lines.append("\(padded)\(String(tally.rows).leftPadded(7))\(String(tally.uboBlocked).leftPadded(6))"
                + "\(String(tally.paddleBlocked).leftPadded(8))\(String(tally.bothBlock).leftPadded(12))"
                + "\(String(tally.bothAllow).leftPadded(12))\(String(tally.paddleOnly).leftPadded(13))"
                + "\(String(tally.uboOnly).leftPadded(10))  \(percent(tally.agreement))")
        }
        return lines
    }

    /// The report as full text, and the short summary printed to the test output.
    static func report(
        dataDir: URL,
        rowCount: Int,
        overall: Tally,
        perType: [String: Tally],
        unknownTypes: [String: Int],
        misses: [String: Example],
        overBlocks: [String: Example],
        subFrame: (rows: Int, sameSource: Int),
        conversions: [(String, FilterListConverter.Result)],
        evaluators: [(String, WebKitRuleEvaluator)],
        timing: [(String, Duration)],
        selfCheck: (rows: Int, failures: [String])
    ) -> (summary: String, full: String) {
        func totalsBlock(_ tally: Tally) -> [String] {
            [
                "rows              \(tally.rows)",
                "uBO blocked       \(tally.uboBlocked)",
                "Paddle blocked    \(tally.paddleBlocked)",
                "both block        \(tally.bothBlock)",
                "both allow        \(tally.bothAllow)",
                "Paddle-only       \(tally.paddleOnly)  (over-blocks)",
                "uBO-only          \(tally.uboOnly)  (misses)",
                "agreement         \(percent(tally.agreement))",
            ]
        }

        var summary: [String] = ["Adblock oracle: Paddle (easylist + easyprivacy) vs uBlock Origin, \(rowCount) rows"]
        summary += totalsBlock(overall)
        summary.append("")
        summary += typeTable(perType)
        summary.append("")
        summary.append("timing: " + timing.map { "\($0.0) \(seconds($0.1))" }.joined(separator: ", "))
        summary.append("self-check: \(selfCheck.rows) rows, \(selfCheck.failures.count) mismatches")
        summary.append("sub_frame rows: \(subFrame.rows); url == sourceUrl in \(subFrame.sameSource)")

        var full = summary
        full.append("")
        full.append("== Conversion ==")
        for (name, result) in conversions {
            let skips = result.skips
            let topOptions = ranked(skips.options, count: { $0 }, limit: 8)
                .map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            full.append("\(name): ruleCount \(result.ruleCount), skippedLines \(result.skippedLines) "
                + "(scriptlets \(skips.scriptlets), extended \(skips.extendedSelectors), other \(skips.other), malformed \(skips.malformed))")
            full.append("  options: \(topOptions)")
            full.append("  styleInjection \(result.styleInjection), invalidSelectors \(result.invalidSelectors), "
                + "regexTranslated \(result.regexTranslated), regexRefused \(result.regexRefused), truncated \(result.truncated)")
        }
        full.append("")
        full.append("== Evaluator index ==")
        for (name, evaluator) in evaluators {
            let s = evaluator.stats
            full.append("\(name): totalRules \(s.totalRules), evaluated \(s.evaluated), indexed \(s.indexed), "
                + "fallback \(s.fallback), wildcard \(s.wildcard), whole keys \(s.wholeKeys), prefix keys \(s.prefixKeys), "
                + "suffix keys \(s.suffixKeys), invalid regex \(s.invalidRegex), never matching \(s.neverMatching), "
                + "cosmetic \(s.cosmetic), other actions \(s.otherActions)")
        }
        if !unknownTypes.isEmpty {
            full.append("unknown uBO types: \(unknownTypes)")
        }
        full.append("")
        full.append("== Totals ==")
        full += totalsBlock(overall)
        full.append("")
        full.append("== Per uBO type ==")
        full += typeTable(perType)
        full.append("")
        full.append("== Top 30 uBO filters behind misses (uBO blocked, Paddle allowed) ==")
        for (filter, example) in ranked(misses, count: { $0.count }, limit: 30) {
            full.append("\(example.count)\t\(filter)\n\t\(example.url)")
        }
        full.append("")
        full.append("== Top 30 Paddle deciding url-filters behind over-blocks (Paddle blocked, uBO not) ==")
        for (key, example) in ranked(overBlocks, count: { $0.count }, limit: 30) {
            full.append("\(example.count)\t\(key)\t(uBO value 2 in \(example.uboException))\n\t\(example.url)\n\tsource \(example.sourceURL)")
        }
        full.append("")
        full.append("== Timing ==")
        for (name, duration) in timing {
            full.append("\(name): \(seconds(duration))")
        }
        full.append("")
        full.append("== Self-check (indexed vs brute force, \(selfCheck.rows) rows, both lists) ==")
        full.append("mismatches: \(selfCheck.failures.count)")
        for failure in selfCheck.failures.prefix(20) {
            full.append("  \(failure)")
        }
        full.append("")
        full.append("Data: \(dataDir.path)")
        return (summary.joined(separator: "\n"), full.joined(separator: "\n"))
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
