import Foundation

/// Google's answer to an update check for a Chrome Web Store extension: `clients2.google.com/service/update2/crx` with
/// `response=updatecheck`, answered as gupdate XML. Only the version in the answer is used. The package itself is
/// downloaded as an install downloads it (`StoreLink.chromeDownloadURL`), never from the answer's `codebase`.
public enum ChromeUpdateCheck {
    public enum Answer: Equatable, Sendable {
        /// Google offers no version newer than the one sent.
        case noUpdate
        /// The newest version Google offers, in Chrome's format (`ExtensionVersion.compareChrome`).
        case update(version: String)
    }

    /// Why an answer isn't used. Each reads as a sentence for the status line.
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case malformed
        case otherApp
        /// The app or the check reported a status other than "ok" or "noupdate" (text from Google).
        case refused(String)
        case noVersion

        public var errorDescription: String? {
            switch self {
            case .malformed: "Google's update answer isn't the expected XML"
            case .otherApp: "Google's update answer is for another extension"
            case .refused(let status): "Google's update check answered \(status)"
            case .noVersion: "Google's update answer gives no usable version"
            }
        }
    }

    /// The largest answer read. A real one is a few hundred bytes.
    public static let maxAnswerSize = 64 * 1024

    /// The check address for the extension `id` installed at `installedVersion`, presenting the browser version Paddle
    /// uses everywhere else (`versions`). Nil when `id` isn't a Chrome id, or a version isn't in Chrome's format.
    public static func url(id: String, installedVersion: String, versions: BrowserVersions = .current) -> URL? {
        let id = id.lowercased()
        let prodversion = versions.chromeFullVersion
        guard ExtensionIdentity.isChromeID(id), ExtensionVersion.compareChrome(installedVersion, installedVersion) != nil,
              !prodversion.isEmpty, prodversion.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return URL(
            string: "https://clients2.google.com/service/update2/crx?response=updatecheck&acceptformat=crx3"
                + "&prodversion=\(prodversion)&x=id%3D\(id)%26v%3D\(installedVersion)%26uc"
        )
    }

    /// Reads the answer for the extension `id` (lowercase). Strict: the root is `gupdate`, the only `app` names `id` and
    /// has status "ok", and it holds one `updatecheck` that is either "noupdate" or "ok" with a Chrome version.
    public static func parse(_ data: Data, id: String) throws -> Answer {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.root == "gupdate", reader.apps.count == 1 else { throw Failure.malformed }
        let app = reader.apps[0]
        guard app.appid == id else { throw Failure.otherApp }
        guard app.status == "ok" else { throw Failure.refused(app.status ?? "no status") }
        guard app.checks.count == 1, let check = app.checks.first else { throw Failure.malformed }
        switch check.status {
        case "noupdate":
            return .noUpdate
        case "ok":
            guard let version = check.version, ExtensionVersion.compareChrome(version, version) != nil else { throw Failure.noVersion }
            return .update(version: version)
        default:
            throw Failure.refused(check.status ?? "no status")
        }
    }

    /// The elements the answer is read from, collected as the parser goes.
    private final class Reader: NSObject, XMLParserDelegate {
        struct App {
            var appid: String?
            var status: String?
            var checks: [(status: String?, version: String?)] = []
        }

        var root: String?
        var apps: [App] = []
        private var stack: [String] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes attributeDict: [String: String]
        ) {
            if stack.isEmpty { root = elementName }
            if elementName == "app", stack.last == "gupdate" {
                apps.append(App(appid: attributeDict["appid"], status: attributeDict["status"]))
            } else if elementName == "updatecheck", stack.last == "app", !apps.isEmpty {
                apps[apps.count - 1].checks.append((attributeDict["status"], attributeDict["version"]))
            }
            stack.append(elementName)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}
