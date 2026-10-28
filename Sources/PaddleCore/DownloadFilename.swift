import Foundation

/// A file name a page suggested, made safe to save under in the Downloads folder.
public enum DownloadFilename {
    public static let fallback = "download"
    public static let maxBytes = 255

    /// Bidirectional override and isolate controls: they make a name read differently from what it is ("exe.txt" shown
    /// as "txt.exe" reversed).
    static func isBidiOverride(_ s: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
    }

    /// Path separators and ":" become "-"; control and bidi override characters go; leading dots and whitespace go
    /// (no hidden files, no names starting like a flag); an empty result becomes "download"; the name is cut to 255
    /// bytes in UTF-8, keeping the extension.
    public static func sanitized(_ suggested: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in suggested.unicodeScalars {
            if s == "/" || s == "\\" || s == ":" { scalars.append("-"); continue }
            if s.properties.generalCategory == .control || isBidiOverride(s) { continue }
            scalars.append(s)
        }
        var name = String(scalars)
        while let first = name.unicodeScalars.first, first == "." || first.properties.isWhitespace {
            name.unicodeScalars.removeFirst()
        }
        while let last = name.unicodeScalars.last, last.properties.isWhitespace { name.unicodeScalars.removeLast() }
        if name.isEmpty { return fallback }
        return capped(name)
    }

    private static func capped(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ns = name as NSString
        var ext = ns.pathExtension
        // An absurd extension is just part of a long name: cut the whole thing.
        if ext.utf8.count > 32 { ext = "" }
        let suffix = ext.isEmpty ? "" : "." + ext
        var base = ext.isEmpty ? name : ns.deletingPathExtension
        while !base.isEmpty, base.utf8.count + suffix.utf8.count > maxBytes { base.removeLast() }
        return base.isEmpty ? fallback + suffix : base + suffix
    }
}
