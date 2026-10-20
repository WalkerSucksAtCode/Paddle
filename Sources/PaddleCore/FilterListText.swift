import Foundation

/// Checks and decoding for filter-list text, kept apart from the app's download and compile code so they can be tested.
public enum FilterListText {
    /// The largest list Paddle will store: EasyList is a few MB, so this only stops runaway downloads.
    public static let maxBytes = 50 * 1_024 * 1_024

    /// Whether downloaded `data` may replace a stored list: valid UTF-8 that starts like a list (`[Adblock` or `!`),
    /// is at most `maxBytes`, and has at least one rule line (not blank, not a `!` comment, not the header).
    public static func mayReplaceStoredList(_ data: Data) -> Bool {
        guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("[Adblock") || text.hasPrefix("!")
        else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("!") && !trimmed.hasPrefix("[Adblock")
        }
    }

    /// Text of a user-written file: UTF-8 (a BOM is dropped), else UTF-16 when it has a BOM, else Latin-1, which
    /// decodes any bytes.
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            // 0xFF and 0xFE never appear in UTF-8, so the BOM decides the byte order.
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        if let text = String(data: Data(body), encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
