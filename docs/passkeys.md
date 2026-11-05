# Passkeys (WebAuthn) in Paddle

Paddle uses **system WebKit** for `navigator.credentials.create()` / `get()` — the same WebAuthn stack Safari uses inside a page, not a custom JavaScript bridge.

## What works without Apple's browser entitlement

- **Nothing useful for arbitrary sites.** Associated domains (`apple-app-site-association`) and app-site passkeys are for **native apps**, not a third-party `WKWebView` browser signing in at `accounts.google.com`, `webauthn.io`, etc.
- Paddle already declares **http** and **https** URL schemes in `Info.plist` (`CFBundleURLTypes`), which Apple lists among browser-app criteria alongside the managed entitlement.

## What requires `com.apple.developer.web-browser.public-key-credential`

Apple's **managed capability** for macOS browser apps. It is **not** automatic on a Developer ID team.

| Piece | Role |
|---|---|
| Entitlement in `App/Paddle/Paddle.entitlements` | Declares intent; must match a profile Apple enabled for Team **VB3UP263YT**. |
| Apple approval | Account Holder request via Apple's **macOS Browsers Passkeys** form. **Submitted (Nov 2026); Request ID `84Z8XFC523` — pending Apple.** |
| Re-sign / notarize | After approval, uncomment the entitlement in `Paddle.entitlements` and rebuild Release with `scripts/release.sh --notarize`. Until then, Release builds omit the key so notarization succeeds. |
| `ASAuthorizationWebBrowserPublicKeyCredentialManager` | One-time **platform passkey** authorization when state is `.notDetermined` (`BrowserPasskeyCoordinator` at launch). |
| WebKit | Platform passkeys (Touch ID) and **security keys** once the entitlement is active in the signed app. |

**Related:** Walker has also **requested Apple's Web Push entitlement** for third-party browsers (notifications while Paddle is quit or the tab is closed). That is separate from passkeys; Paddle still supports the page notification API only while a tab is open until Web Push is granted.

References:

- [Authenticating people by using passkeys in browser apps](https://developer.apple.com/documentation/authenticationservices/authenticating-people-by-using-passkeys-in-browser-apps)
- [com.apple.developer.web-browser.public-key-credential](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)

## Request checklist (for Apple)

Prepare before submitting the browser passkeys form:

- **Team ID:** VB3UP263YT (`com.walker.Paddle`).
- **Product:** Paddle — third-party macOS browser on system WebKit, Developer ID, hardened runtime.
- **Bundle ID:** `com.walker.Paddle`.
- **URL schemes:** http + https registered in `Info.plist` (done).
- **Use case:** Google account and other FIDO2 relying parties via standard WebAuthn in `WKWebView` (e.g. accounts.google.com passkey sign-in).
- **Privacy:** Passkeys stay in Apple's/WebKit's credential store; profile separation uses per-profile `WKWebsiteDataStore` identifiers (default profile uses the default store; private windows use a non-persistent store).

## Profiles and private windows

- **Profiles:** Each non-default profile has its own persistent `WKWebsiteDataStore(forIdentifier:)` — WebKit keeps site data (including WebAuthn state) separate per profile when the entitlement is active.
- **Private windows:** Non-persistent data store; passkeys created there should not persist into normal windows (same as cookies/storage).

## Verify after Apple grants the capability

1. Uncomment the entitlement in `Paddle.entitlements`, build a Release app with a Developer ID signature that **includes** the entitlement (`codesign -d --entitlements - /Applications/Paddle.app` shows `com.apple.developer.web-browser.public-key-credential` = true).
2. Launch Paddle; accept the **platform passkey** authorization sheet if shown once.
3. **webauthn.io** — register and sign in with platform passkey and, separately, a USB/NFC security key.
4. **accounts.google.com** — passkey sign-in (target use case).
5. Logs: `log show --predicate 'subsystem == "com.walker.Paddle" AND category == "passkeys"' --last 5m`

If the entitlement is missing at runtime, Paddle logs once at launch and WebAuthn fails in the page (no silent fallback).

## Local Debug without Apple approval

Automatic signing may fail if the entitlement key is uncommented before the capability is on the team. Options:

- Keep the entitlement commented out in `Paddle.entitlements` for local and Release builds (passkeys stay off), or
- After Apple enables the capability, uncomment the key, refresh profiles in Xcode, and build as usual.

Do not assume passkeys work in `/Applications/Paddle.app` until a build signed **after** approval is installed.

**Release note:** Developer ID build **156** (Nov 2026, old private history) was notarized **without** embedding this entitlement because the capability is not yet on Team VB3UP263YT. Code and `BrowserPasskeyCoordinator` are on `main` via the Track B port; the entitlement stays commented until Request ID **84Z8XFC523** is approved.
