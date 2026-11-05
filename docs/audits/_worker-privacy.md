# Privacy / security / permissions audit (read-only)

**Tree:** `main` @ `015dc73`  
**Scope:** ATS, `WKWebsiteDataStore` isolation, site permission prompts (camera, microphone, location, notifications), private browsing, contact autofill (not site passwords), WebAuthn/passkeys entitlement state, on-disk file modes.  
**Out of scope:** Apple-managed passkeys capability approval (Request ID `84Z8XFC523` pending); control-bridge peer signing detail (see architecture worker) except private-window exposure.

**S0:** **None.** No unauthenticated remote access to private session data, no silent bypass of permission prompts reviewed here, and no finding where Paddle enables passkeys without the signed entitlement.

---

## ATS and transport

| Layer | Setting | Effect |
|---|---|---|
| App (native `URLSession`, filter downloads, etc.) | Default ATS (no `NSAllowsArbitraryLoads` in `Info.plist`) | Non-WebKit fetches must meet standard ATS unless exempt by Apple rules. |
| Web content (`WKWebView`) | `NSAppTransportSecurity` → `NSAllowsArbitraryLoadsInWebContent` = **true** (`App/Paddle/Info.plist` lines 31–34) | Pages may load **cleartext HTTP** and other ATS-relaxed resources inside WebKit even when the app shell is strict. |
| User policy | `httpsOnly` + `HTTPSOnlyPolicy.upgrade` (`Sources/PaddleCore/HTTPSOnlyPolicy.swift`) | Main-frame `http://` upgrades to `https://` when enabled; local hosts exempt (`isLocal`); per-site and session exceptions in `TabWebDelegate` (~179–200). |

Paddle documents HTTPS-only in Settings (`PrivacyPane.swift`); it is **off unless the user turns it on** (default from empty `config.json` follows `PaddleConfig` defaults — verify in config worker if needed).

---

## Cookies, storage, and profiles

```text
Default profile     → WKWebsiteDataStore.default()  (WebEnvironment.dataStore, line 15–18)
Other profiles      → WKWebsiteDataStore(forIdentifier: profileUUID)  (lines 83–89)
Private windows     → WKWebsiteDataStore.nonPersistent(), one shared store until last private window closes (lines 75–77, 132–139, 220–221)
```

- **Isolation:** Non-default profiles get separate persistent stores; deleting a profile calls `WKWebsiteDataStore.remove(forIdentifier:)` (`ProfileStore.delete`, `WebEnvironment.removeDataStore`).
- **Private session teardown:** When the last private window closes, `AppModel.windowClosed` calls `web.endPrivateSession()`, clears `privatePermissions`, private HTTP exceptions, and private downloads tracking (`App/Paddle/AppModel.swift` ~1187–1194).
- **Session restore:** Private windows are omitted from `session.json` (`Sources/PaddleCore/PrivateBrowsing.swift` `SessionRecord.saving`).
- **Website data UI:** `WebsiteDataSheet` reads only the **persistent** store for the chosen profile — private ephemeral data is intentionally not listed (`WebsiteDataSheet.swift` header comment, init `store`).

**Extension storage:** Per-profile paths under `~/Library/WebKit/com.walker.Paddle/WebExtensions/` (`Paths.webExtensionStorage`). Private windows that allow extensions reuse the **default profile’s** `WKWebExtensionController` (`WebEnvironment.makeConfiguration` line 161) — extension state is not the same isolation model as cookies (architecture worker FA-ARC-02).

---

## Permission prompts and entitlements

| Capability | Sandbox entitlement (`Paddle.entitlements`) | Info.plist usage string | Runtime gate |
|---|---|---|---|
| Camera | `com.apple.security.device.camera` | `NSCameraUsageDescription` | `TabWebDelegate.decideMediaCapturePermissionsFor` (~908–938): session map per private/profile; sheet; embed `#in:<top>` site key |
| Microphone | `com.apple.security.device.audio-input` | `NSMicrophoneUsageDescription` | Same delegate; combined camera+mic type maps to both kinds |
| Location | `com.apple.security.personal-information.location` | `NSLocationUsageDescription`, `NSLocationWhenInUseUsageDescription` | `SitePermissionDecision.location` + `askSitePermission` (~965–991); embedding page must allow |
| Contacts (import only) | `com.apple.security.personal-information.addressbook` | `NSContactsUsageDescription` | `ContactsImport.myCard()` requests access when user chooses “Use My Contacts Card” |
| Notifications | (none — app posts via WebKit) | — | `SitePermissionDecision.notifications` requires **https**; **private windows always deny** (~1007–1009) |

**Remember vs session-only:** Location/notifications may write `sites.<host>.*` to `config.json` when the user checks “Remember for &lt;host&gt;” — **not offered in private windows** (`askSitePermission` ~1056–1067). Camera/microphone grants are **session-only** until quit (alert copy ~931). Media capture does not offer “Remember” to config.

**Geolocation / notification embedding:** `SitePermissionDecision` denies if either frame or embedding top page is `.deny`; grant requires both `.allow` when embedding applies (`Sources/PaddleCore/SitePermissionDecision.swift`).

---

## Private browsing

| Data class | Private behavior | Mechanism |
|---|---|---|
| Cookies / localStorage / cache | Non-persistent store; released when last private window closes | `WebEnvironment` private store |
| History | Not recorded | `recordInHistory` guard `!tab.isPrivate` (`TabWebDelegate.swift` ~541–542) |
| Favicons | Not fetched to disk | Comment ~558–559 |
| Notifications | Denied without prompt | `notificationDecision` ~1008–1009 |
| HTTPS-only exceptions | Separate `privateHTTPExceptions` | `AppModel` cleared on private session end |
| Session permissions | `privatePermissions` only | Subscript `permissionsFor` in `AppModel` |
| Speculative loading / DNS prefetch | Off | `makeConfiguration` ~163–164; `PrivacyPane` caption |
| Process pool | Separate “Paddle Private” pool | `configureProcessIdentity(..., isPrivate: true)` |

Navigation logs for blocked extension URLs use `.private` privacy on URL fields (`TabWebDelegate` ~107–108). Exception reasons redact URLs via `LogRedaction` (`App/Paddle/ExceptionLog.swift` ~39).

---

## Passwords and autofill

| Feature | Paddle behavior |
|---|---|
| **Saved website passwords** | **Not implemented.** WebKit/Safari Keychain integration and third-party password managers handle login fields; Paddle does not ship a password autofill store. |
| **HTTP Basic/Digest/NTLM** | Native sheet; credential `persistence: .forSession` → WebKit session store for that tab’s data store (`TabWebDelegate` ~421–456). In private windows, store is non-persistent. |
| **Contact autofill** | Optional `contactAutofill`; **https main frame only**; classifier rejects password/card/autocomplete tokens (`ContactAutofillScript` in `Sources/PaddleCore/ContactAutofill.swift`); values in Keychain generic password (`App/Paddle/Web/ContactAutofill.swift` `ContactCardStore`); fill only after native chip click; isolated content world. |
| **Control bridge `run_js`** | Documented non-sandbox; password inputs guarded in injected prelude (`ControlBridge+Tools.swift` ~514+); cookies redacted from results (~501+). |

Settings copy states passwords stay with the password manager (`PrivacyPane.swift` ~523).

---

## WebAuthn / passkeys

| Item | State |
|---|---|
| Entitlement key | `com.apple.developer.web-browser.public-key-credential` **commented out** in `App/Paddle/Paddle.entitlements` (lines 13–16); Apple Request **`84Z8XFC523` pending** (`docs/passkeys.md`). |
| `plutil -p` on entitlements | Shows camera, audio, location, addressbook only — **no passkeys key**. |
| Runtime | `BrowserPasskeyCoordinator.embeddedEntitlementIsTrue` uses `SecTaskCopyValueForEntitlement`; when false, logs once and **does not** request platform authorization (`BrowserPasskeyCoordinator.swift` ~20–24, ~58–63). |
| Product expectation | WebAuthn in pages remains **disabled until Apple grants capability and Release is re-signed** with entitlement uncommented (`docs/passkeys.md`). |

**Apple-blocked vs Paddle:** Missing capability is **Out-of-scope (Apple)**. Paddle’s ungated path is **Closed** (no coordinator authorization without embedded entitlement).

---

## On-disk permissions (`FilePermissions`)

- **Policy:** folders `0700`, files `0600` (`Sources/PaddleCore/FilePermissions.swift` lines 5–6).
- **Application:** `Paths.tightenExisting()` at launch restricts support folder, profiles, sessions, favicons, and sensitive files (`App/Paddle/Support/Paths.swift` ~73–87); `AppModel` creates profile/history paths with `createPrivateFolder` / `restrictDatabase` (~986–989).
- **Tests:** `FilePermissionsTests` confirms `tightened`, `restrict`, `restrictDatabase`, `createPrivateFolder` (`Tests/PaddleCoreTests/FilePermissionsTests.swift`).

AGENTS.md inventory (support 0700, listed files 0600) matches code intent; this pass did not chmod the live `~/Library/Application Support/Paddle/` directory.

---

## Control bridge and private data (minimal)

- MCP/window tools use `visibleWindows` = non-private only (`ControlBridge+Tools.swift` ~37–39).
- `open_url` to `PrivateHost.isPrivate` hosts prompts once per session (`~297–298`) — LAN/localhost guard, not private-window leak.
- `PeerRequirement` + `BridgeSocketServer.checkPeer` enforce owner UID + signed `paddle-mcp` (`Sources/PaddleCore/PeerRequirement.swift`, `BridgeSocketServer.swift` ~246+).

No finding that the bridge exposes private window tabs or their storage when `controlBridge` is on.

---

## Findings

### FA-SEC-01 — WebKit ATS relaxation allows arbitrary loads in page context
- **Severity:** S2  
- **Area:** ATS / transport  
- **Mechanism:** `Info.plist` `NSAllowsArbitraryLoadsInWebContent` = true (lines 31–34).  
- **Evidence:** Web pages can initiate cleartext and non-compliant TLS loads inside WebKit independent of native app ATS.  
- **User impact:** Without `httpsOnly`, users can browse and submit data over HTTP on the open internet; mixed content behavior follows WebKit.  
- **Disposition:** **Closable** — product choice for browser compatibility; mitigated by optional HTTPS-only mode and fraud warnings toggle (`PrivacyPane`).  
- **Tree:** main  

### FA-SEC-02 — Passkeys/WebAuthn blocked at Apple entitlement; Paddle gates correctly
- **Severity:** S4 (informational)  
- **Area:** WebAuthn  
- **Mechanism:** Entitlement XML-commented `Paddle.entitlements` 13–16; `BrowserPasskeyCoordinator.prepareAfterLaunch` 21–23.  
- **Evidence:** `SecTaskCopyValueForEntitlement` false → log + no `ASAuthorizationWebBrowserPublicKeyCredentialManager` request.  
- **User impact:** FIDO2 sign-in in `WKWebView` fails until Apple approves Request `84Z8XFC523` and Release rebuild.  
- **Disposition:** **Out-of-scope (Apple)** for enablement; **Closed** for mishandling ungated state.  
- **Tree:** main  

### FA-SEC-03 — Profile and private `WKWebsiteDataStore` separation matches documented model
- **Severity:** S4  
- **Area:** storage isolation  
- **Mechanism:** `WebEnvironment.dataStore(for:)` 83–89; `makeConfiguration` 132–141; `endPrivateSession` 220–221.  
- **Evidence:** Default profile keeps `.default()` store; UUID profiles use `forIdentifier:`; private uses `.nonPersistent()`.  
- **User impact:** Expected cookie/login separation between profiles; private session cleared when last private window closes.  
- **Disposition:** **Closed** (by design).  
- **Tree:** main  

### FA-SEC-04 — Private browsing excludes persistent artifacts
- **Severity:** S4  
- **Area:** private mode  
- **Mechanism:** `PrivateBrowsing.swift` session filter; `TabWebDelegate.recordInHistory` 541–542; `AppModel.windowClosed` 1187–1194.  
- **Evidence:** No history rows, no session.json windows, notifications hard-deny, private permission map cleared.  
- **User impact:** Aligns with user expectation of ephemeral private windows modulo WebKit/engine bugs (Apple).  
- **Disposition:** **Closed**.  
- **Tree:** main  

### FA-SEC-05 — Camera/microphone prompts are explicit and session-scoped
- **Severity:** S4  
- **Area:** media permissions  
- **Mechanism:** `TabWebDelegate.decideMediaCapturePermissionsFor` 908–938; entitlements camera + audio-input.  
- **Evidence:** NSAlert per origin (+ embed key); grants stored in `SessionPermissions` only; abort re-checks map (fail closed on deny).  
- **User impact:** Sites cannot silently capture A/V without user allow in that Paddle session.  
- **Disposition:** **Closed**.  
- **Tree:** main  

### FA-SEC-06 — Location uses site policy, embedding rules, and optional Remember (non-private only)
- **Severity:** S4  
- **Area:** geolocation  
- **Mechanism:** `SitePermissionDecision.location` 12–14; `askSitePermission` 965–991, 1037–1069.  
- **Evidence:** `.deny` in config skips prompt; Remember writes `sites.<host>.location`; suppressed in private windows.  
- **User impact:** Cross-frame embeds cannot bypass top-page deny; persistent allow/deny is user-controlled outside private mode.  
- **Disposition:** **Closed**.  
- **Tree:** main  

### FA-SEC-07 — Notifications limited to HTTPS and blocked in private windows
- **Severity:** S4  
- **Area:** notifications  
- **Mechanism:** `SitePermissionDecision.notifications` 17–19; `notificationDecision` 1007–1030.  
- **Evidence:** Non-https → `.deny`; private → immediate false.  
- **User impact:** No web notification permission surface on http: or in private browsing.  
- **Disposition:** **Closed**.  
- **Tree:** main  

### FA-SEC-08 — Contact autofill excludes passwords and cards; user-initiated fill only
- **Severity:** S4  
- **Area:** autofill  
- **Mechanism:** `ContactAutofillScript` classifier 160–173; `ContactAutofillHandler` 95–110; `ContactCardStore` Keychain 14–16.  
- **Evidence:** Tests in `ContactAutofillTests` for password/card rejection; https-only injection.  
- **User impact:** Reduces exfiltration vs in-page autofill; still user must click native chip.  
- **Disposition:** **Closed**.  
- **Tree:** main  

### FA-SEC-09 — HTTP authentication uses ephemeral session credentials in WebKit store
- **Severity:** S3  
- **Area:** credentials  
- **Mechanism:** `TabWebDelegate` HTTP auth challenge 421–456; `URLCredential(..., persistence: .forSession)`.  
- **Evidence:** No Paddle Keychain persistence for site passwords; private tabs use non-persistent data store.  
- **User impact:** Basic auth passwords live in WebKit cookie/credential store for session/profile, not Paddle’s contact Keychain item.  
- **Disposition:** **Accepted** — standard WebKit behavior; users should prefer HTTPS and password managers for site logins.  
- **Tree:** main  

### FA-SEC-10 — Support-directory file modes tightened to 0700/0600
- **Severity:** S4  
- **Area:** local data protection  
- **Mechanism:** `FilePermissions` + `Paths.tightenExisting` 73–87; `FilePermissionsTests`.  
- **Evidence:** `restrictDatabase` covers SQLite sidecars; symlinks skipped in `restrict`.  
- **User impact:** Other local users on macOS cannot read history/session/config via group/world bits after tighten.  
- **Disposition:** **Closed** (implementation matches AGENTS.md; live disk not measured here).  
- **Tree:** main  

### FA-SEC-11 — Exception log redacts URLs including private-window pages
- **Severity:** S4  
- **Area:** logging  
- **Mechanism:** `LogRedaction.redactURLs` 9–12; `ExceptionLog` 39.  
- **Evidence:** `LogRedactionTests` cover http, file, javascript, extension schemes.  
- **User impact:** Rotated `exceptions.log` less likely to store full visited URLs in plaintext.  
- **Disposition:** **Closed**.  
- **Tree:** main  

### FA-SEC-12 — HTTPS-only is opt-in; cleartext remains available when off
- **Severity:** S3  
- **Area:** transport / user setting  
- **Mechanism:** `HTTPSOnlyPolicy.upgrade` 8–22; Settings toggle `PrivacyPane` 57–63.  
- **Evidence:** Local hosts exempt; user/session “Continue to HTTP” exceptions via `AppModel.httpExceptions`.  
- **User impact:** Default browsing may use HTTP unless user enables HTTPS-only.  
- **Disposition:** **Closable** — intentional compatibility default; paired with ATS-in-web-content (FA-SEC-01).  
- **Tree:** main  

### FA-SEC-13 — Extensions in private windows attach to default profile controller
- **Severity:** S3  
- **Area:** private mode / extensions  
- **Mechanism:** `WebEnvironment.makeConfiguration` 161: `extensionController(for: isPrivate ? ProfileStore.defaultID : profile)`.  
- **Evidence:** Comment lines 28–29, 123–124 same file.  
- **User impact:** Extension APIs/storage may not match user mental model of “private” when extensions are enabled in a private window.  
- **Disposition:** **Inform** — document in product copy if not already; not a cookie-store leak.  
- **Tree:** main  

### FA-SEC-14 — Shared content controller injects same scripts into private and normal tabs
- **Severity:** S3  
- **Area:** isolation (scripts vs storage)  
- **Mechanism:** Single `WKUserContentController` on all configurations (`WebEnvironment` 14, 131).  
- **Evidence:** Architecture FA-ARC-02; data still partitioned by `websiteDataStore`.  
- **User impact:** Userscripts/block lists run in private mode too (expected for ad blocking); not a credential leak by itself.  
- **Disposition:** **Accepted** — browser product choice; storage isolation remains separate.  
- **Tree:** main  

### FA-SEC-15 — Control bridge excludes private windows from automation surface
- **Severity:** S4  
- **Area:** MCP / bridge  
- **Mechanism:** `ControlBridge+Tools.visibleWindows` 37–39; menu actions refuse private front window 383–385.  
- **Evidence:** Architecture FA-ARC-05 cross-reference.  
- **User impact:** Remote MCP clients cannot list or drive private tabs via provided window APIs.  
- **Disposition:** **Closed** for private-window leak (peer auth remains architecture scope).  
- **Tree:** main  

### FA-SEC-16 — `ZipSafety` and `PrivateHost` harden extension install and local URL open prompts
- **Severity:** S4  
- **Area:** supply chain / local network  
- **Mechanism:** `ZipSafety.entries` refuses encryption/symlinks/path traversal; bridge `openURL` uses `PrivateHost.isPrivate` for consent.  
- **Evidence:** `Sources/PaddleCore/ZipSafety.swift`, `PrivateHost.swift`, `ControlBridge+Tools.openURL` ~297–298.  
- **User impact:** Reduces malicious ZIP install and drive-by LAN navigation via MCP without user confirm.  
- **Disposition:** **Closed** in reviewed paths.  
- **Tree:** main  

---

## Summary table

| ID | Topic | Disposition |
|---|---|---|
| FA-SEC-01 | ATS in WebContent | Closable (HTTPS-only) |
| FA-SEC-02 | Passkeys entitlement | Out-of-scope (Apple); Closed gating |
| FA-SEC-03 | Data store profiles | Closed |
| FA-SEC-04 | Private artifacts | Closed |
| FA-SEC-05 | Camera/mic | Closed |
| FA-SEC-06 | Location | Closed |
| FA-SEC-07 | Notifications | Closed |
| FA-SEC-08 | Contact autofill | Closed |
| FA-SEC-09 | HTTP auth credentials | Accepted |
| FA-SEC-10 | File modes | Closed |
| FA-SEC-11 | Log redaction | Closed |
| FA-SEC-12 | HTTPS-only default off | Closable |
| FA-SEC-13 | Private + extensions | Inform |
| FA-SEC-14 | Shared user scripts | Accepted |
| FA-SEC-15 | Bridge private filter | Closed |
| FA-SEC-16 | ZIP / PrivateHost | Closed |

**Apple-blocked vs closable:** Passkeys = **Apple**. ATS web-content flag and HTTPS-only default = **closable** Paddle/product choices.
