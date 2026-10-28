import Foundation

/// The rules behind the location and notification delegates in `TabWebDelegate`, kept pure so they can be tested.
/// `site` is the frame's own setting from the tab's config; `embeddingPage` is the top page's setting for an embedded
/// frame from another host, and nil for the page itself (or when the embedding page is the same host).
public enum SitePermissionDecision {
    public enum Outcome: Sendable, Equatable {
        case grant, deny, ask
    }

    /// Location: a frame's own `allow` is not enough on its own; the embedding page must allow too.
    public static func location(site: SiteSettings.Permission, embeddingPage: SiteSettings.Permission?) -> Outcome {
        combined(site, embeddingPage)
    }

    /// Notifications: only https origins can be granted. Other schemes are refused without asking.
    public static func notifications(scheme: String, site: SiteSettings.Permission, embeddingPage: SiteSettings.Permission?) -> Outcome {
        guard scheme.lowercased() == "https" else { return .deny }
        return combined(site, embeddingPage)
    }

    /// A deny on either side denies; `allow` needs the embedding page to allow as well (or be the page itself);
    /// anything else asks.
    private static func combined(_ site: SiteSettings.Permission, _ embedding: SiteSettings.Permission?) -> Outcome {
        if site == .deny || embedding == .deny { return .deny }
        if site == .allow && (embedding == nil || embedding == .allow) { return .grant }
        return .ask
    }
}
