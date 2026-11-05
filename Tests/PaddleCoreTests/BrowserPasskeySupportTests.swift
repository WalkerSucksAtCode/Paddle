import Foundation
@testable import PaddleCore
import Testing

struct BrowserPasskeySupportTests {
    @Test func entitlementKeyMatchesAppleIdentifier() {
        #expect(BrowserPasskeySupport.entitlementKey == "com.apple.developer.web-browser.public-key-credential")
    }

    @Test func shouldRequestOnlyWhenNotDetermined() {
        #expect(BrowserPasskeySupport.shouldRequestPlatformAuthorization(.notDetermined))
        #expect(!BrowserPasskeySupport.shouldRequestPlatformAuthorization(.authorized))
        #expect(!BrowserPasskeySupport.shouldRequestPlatformAuthorization(.denied))
    }

    @Test func entitlementStatusFromEmbedFlag() {
        #expect(BrowserPasskeySupport.entitlementStatus(entitlementPresent: false) == .entitlementMissing)
        #expect(BrowserPasskeySupport.entitlementStatus(entitlementPresent: true) == .entitlementEmbedded)
    }
}
