import Foundation

/// Page-controlled text (a link, a file name) cleaned for a dialog.
public enum DisplayText {
    /// Newlines and tabs become spaces; other control characters and bidi override characters are dropped, so a page
    /// can't add lines to a prompt or reverse its text; then the first `limit` characters.
    public static func cleaned(_ text: String, limit: Int = 200) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s == "\n" || s == "\r" || s == "\t" || s.value == 0x2028 || s.value == 0x2029 { scalars.append(" "); continue }
            if s.properties.generalCategory == .control || DownloadFilename.isBidiOverride(s) { continue }
            scalars.append(s)
        }
        return String(String(scalars).prefix(limit))
    }
}
