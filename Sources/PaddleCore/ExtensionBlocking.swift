import Foundation

/// How an extension can block network requests in Paddle, read from its manifest. WebKit applies declarativeNetRequest
/// rules. It delivers webRequest events to an extension's listeners but ignores what they answer, so an extension that
/// blocks only by answering `webRequestBlocking` blocks nothing here. Cosmetic hiding by content scripts is not
/// network blocking and is not classified.
public enum ExtensionBlocking: Equatable, Sendable {
    /// The `declarativeNetRequest` permission (or `declarativeNetRequestWithHostAccess`) and rule files: WebKit applies them.
    case declarativeNetRequest
    /// Asks for `webRequestBlocking` (in `permissions` or `optional_permissions`) and has no rule files: its blocking
    /// answers are ignored.
    case webRequestBlockingOnly
    /// Neither: nothing in the manifest blocks requests.
    case none

    public init(manifest: ExtensionManifest) {
        let permissions = Set(manifest.permissions)
        let declarative = !permissions.isDisjoint(with: ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"])
        if declarative, !manifest.ruleResources.isEmpty {
            self = .declarativeNetRequest
        } else if permissions.contains("webRequestBlocking") {
            self = .webRequestBlockingOnly
        } else {
            self = .none
        }
    }

    /// The line to show the user, or nil when there is nothing to say.
    public var notice: String? {
        switch self {
        case .webRequestBlockingOnly:
            "Asks to block or change requests (webRequestBlocking), which WebKit doesn't allow: anything it would block or change still loads. Paddle's own content blocking still runs."
        case .declarativeNetRequest, .none:
            nil
        }
    }
}
