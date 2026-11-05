import Foundation

/// Browser-app passkeys (WebAuthn for arbitrary relying parties) need Apple's managed entitlement
/// `com.apple.developer.web-browser.public-key-credential`, not associated domains alone.
public enum BrowserPasskeySupport {
    public static let entitlementKey = "com.apple.developer.web-browser.public-key-credential"

    /// What Paddle can infer before AuthenticationServices runs (entitlement embedding only).
    public enum EntitlementStatus: Equatable, Sendable {
        case entitlementMissing
        case entitlementEmbedded
    }

    /// Maps AuthenticationServices platform-credential authorization (once the entitlement is active).
    public enum PlatformAuthorization: Equatable, Sendable {
        case notDetermined
        case authorized
        case denied
    }

    public static func entitlementStatus(entitlementPresent: Bool) -> EntitlementStatus {
        entitlementPresent ? .entitlementEmbedded : .entitlementMissing
    }

    public static func shouldRequestPlatformAuthorization(_ state: PlatformAuthorization) -> Bool {
        state == .notDetermined
    }
}
