import Foundation

/// Address-bar input to a URL: a real address when it looks like one, otherwise a search (`%s` = query).
public struct AddressResolver: Sendable {
    public var searchTemplate: String

    public init(searchTemplate: String) {
        self.searchTemplate = searchTemplate
    }

    public func resolve(_ rawInput: String) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let explicit = explicitURL(input) { return explicit }
        if !input.contains(" "), let host = hostLikeURL(input) { return host }
        return searchURL(for: input)
    }

    public func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: encoded))
    }

    private static let passthroughSchemes = Set(["http", "https", "file", "about", "data", "view-source"])
        .union(ExtensionIdentity.schemes)

    private func explicitURL(_ input: String) -> URL? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let scheme = input[..<colon].lowercased()
        guard Self.passthroughSchemes.contains(scheme) else { return nil }
        // "localhost:3000" has a colon too, but its "scheme" is not in the list, so it falls through.
        if scheme == "http" || scheme == "https" {
            guard input.dropFirst(scheme.count).hasPrefix("://") else { return nil }
        }
        return URL(string: input)
    }

    private func hostLikeURL(_ input: String) -> URL? {
        let hostPart = input.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? input
        let hostOnly = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let lower = hostOnly.lowercased()

        let isLocal = lower == "localhost"
            || lower.hasSuffix(".localhost")
            || lower.hasSuffix(".local")
            || lower.hasSuffix(".test")
            || Self.isIPv4(lower)
        let hasPort = hostPart.contains(":")

        if isLocal {
            return URL(string: "http://" + input)
        }

        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter)
        else {
            return nil
        }
        if hasPort, hostPart.split(separator: ":").last?.allSatisfy(\.isNumber) != true { return nil }
        return URL(string: "https://" + input)
    }

    private static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let n = Int(part), part.count <= 3 else { return false }
            return (0...255).contains(n)
        }
    }
}
