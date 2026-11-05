import AppKit
import AuthenticationServices
import os
import PaddleCore
import Security

/// Browser passkeys: WebKit performs `navigator.credentials` once Apple's browser entitlement is granted.
/// Paddle only checks the signed entitlement and drives the one-time AuthenticationServices authorization
/// for platform (Touch ID) passkeys; security keys follow WebKit's WebAuthn path with the same entitlement.
@MainActor
final class BrowserPasskeyCoordinator {
    static let shared = BrowserPasskeyCoordinator()

    private let log = Logger(subsystem: "com.walker.Paddle", category: "passkeys")
    private var didAttemptAuthorizationRequest = false

    private init() {}

    /// Call after the first browser window exists so the system sheet has a sensible anchor.
    func prepareAfterLaunch(frontWindow: NSWindow?) {
        guard Self.embeddedEntitlementIsTrue else {
            log.info("passkeys: \(BrowserPasskeySupport.entitlementKey, privacy: .public) not embedded; WebAuthn for sites like accounts.google.com stays disabled until Apple grants the capability and the app is re-signed")
            return
        }
        log.info("passkeys: browser entitlement embedded; WebKit WebAuthn enabled when Apple has approved the Team ID capability")

        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        let state = Self.platformAuthorization(manager.authorizationStateForPlatformCredentials)
        switch state {
        case .authorized:
            log.debug("passkeys: platform credential authorization already granted")
        case .denied:
            log.notice("passkeys: platform passkeys denied for Paddle in System Settings; site sign-in may fail until allowed")
        case .notDetermined:
            requestPlatformAuthorization(manager: manager, anchor: frontWindow)
        }
    }

    private func requestPlatformAuthorization(manager: ASAuthorizationWebBrowserPublicKeyCredentialManager, anchor: NSWindow?) {
        guard !didAttemptAuthorizationRequest else { return }
        didAttemptAuthorizationRequest = true
        _ = anchor?.makeKeyAndOrderFront(nil)
        manager.requestAuthorizationForPublicKeyCredentials { [log] authorizationState in
            Task { @MainActor in
                let mapped = Self.platformAuthorization(authorizationState)
                switch mapped {
                case .authorized:
                    log.notice("passkeys: user allowed platform passkeys for Paddle")
                case .denied:
                    log.notice("passkeys: user denied platform passkeys for Paddle")
                case .notDetermined:
                    log.notice("passkeys: platform authorization still not determined after request")
                }
            }
        }
    }

    nonisolated static var embeddedEntitlementIsTrue: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(task, BrowserPasskeySupport.entitlementKey as CFString, nil) else {
            return false
        }
        return (value as? Bool) == true
    }

    static func platformAuthorization(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState)
        -> BrowserPasskeySupport.PlatformAuthorization
    {
        switch state {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
