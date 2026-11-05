# Networking / content blocking audit (read-only)

**Tree:** `main` @ `015dc73` (Track B lightness port). **Method:** code and bundled resources only — no Paddle launch, no EasyList download, no `PADDLE_ORACLE`.  
**S0:** **None.** No crash, credential leak, or silent bypass of documented HTTPS-only / blocking intent found in this slice.

**ATS (App Transport Security):** `App/Paddle/Info.plist` sets `NSAllowsArbitraryLoadsInWebContent` to `true` under `NSAppTransportSecurity` (lines 31–35). Severity and product rationale belong in the privacy/ATS worker; this memo does not assign an ATS finding ID.

---

## Executive summary

Paddle blocks ads/trackers by compiling Adblock Plus–syntax lists into `WKContentRuleList` JSON (`FilterListConverter` → `WKContentRuleListStore` under `~/Library/Application Support/Paddle/compiled-rules/`), attaching lists to a **shared** `WKUserContentController` (`WebEnvironment.performBlockerLoad`). Defaults: `contentBlocking: true`, EasyList + EasyPrivacy URLs, bundled `FilterSnapshots/{easylist,easyprivacy}.txt` seed first launch, plus bundled `PaddleFilters/paddle-filters.txt` and `user-filters.txt`. Startup uses `BlockerGate` (3 s) so first loads wait for lists or accept a documented unblocked window with one reload (`UnblockedReload`). Rules using **`redirect`, `csp`, `removeparam`, `replace`, `header`, …** are **skipped and counted**, not approximated — matching README filter-syntax text.

**HTTPS-only** (`httpsOnly` default true) upgrades main-frame `http://` in `TabWebDelegate.handleHTTPSOnly` via `HTTPSOnlyPolicy.upgrade`; TLS/connection failures after upgrade show `HTTPSOnlyNotice`; redirect/script loops back to `http://` within 10 s show the same notice. Local/single-label hosts are exempt.

**User agent:** `WKWebViewConfiguration.applicationNameForUserAgent` is `Version/<installed Safari> Safari/605.1.15` when `userAgentSuffix` is empty (`WebEnvironment.swift:64–73`). Per-host overrides: `siteUserAgents`, `sitePersonas` (+ `SitePersonaScript`), built-in `SiteCompat` (Proton → Firefox UA at current `BrowserVersions`).

**Speculative loading:** `speculativeLoading` enables private `_setDNSPrefetchingEnabled:` on non-private tabs; `BrowserModel.preconnect` calls `_preconnectToServer:` for address-bar targets and hovered links, gated by `PreconnectPolicy` (30 s per origin).

**Notifications vs Web Push:** `WebsiteNotifications` implements macOS Notification Center for page notifications (process-pool provider) and service-worker–originated notifications (data-store delegate). Code and README state **Web Push** (background/quit) is **not** supported pending Apple entitlement.

**Apple Pay / Payment Request:** README “Not supported (yet)”; no Paddle payment SPI in tree.

**Media (network/policy slice only):** Default configuration requires user action for **audio** autoplay (`mediaTypesRequiringUserActionForPlayback = .audio`); per-site `sites.<host>.autoplay` maps to private `WKWebpagePreferences._autoplayPolicy` when available (`TabWebDelegate.apply`).

---

## Content blocking: compile, cache, apply

| Stage | Location | Behavior |
|---|---|---|
| Sources | `config.filterLists` (https only per `FilterUpdatePolicy.fileName`), `Resources/PaddleFilters/paddle-filters.txt`, `Paths.userFilters` | Other files in `filters/` are **not** loaded (`WebEnvironment.performBlockerLoad` comment ~551–553). |
| Seed | `BundledFilterSnapshots` | Copies `FilterSnapshots/easylist.txt`, `easyprivacy.txt` when missing. |
| Convert | `FilterListConverter.convert` (+ optional `SelectorValidator` web view) | `converterVersion` 8 in cache id; max 150k rules/list; skip breakdown persisted in sidecar JSON. |
| Compile | `ruleStore.compileContentRuleList` | On failure with regex rules, retries **`dropRegex: true`** once; sidecar remembers WebKit refusal. |
| Apply | `contentController.add(list)` | Shared controller for normal/private tabs; `addContentRules` for Reader-only controllers. |
| Off | `contentBlocking: false` | Removes all lists; status line only. |
| Exceptions | `SharedExceptions` | User `@@` / `#@#`, `contentBlocking: false` hosts, cross-list `@@` in cache key. |
| Scriptlets | `config.scriptlets` | Separate user scripts from `##+js` lines; not WebKit network rules. |
| Startup gate | `BlockerGate` 3 s | `Tab.wake` waits; late ready → one reload unless post/media/typed (`UnblockedReload`). |

**Extension pages:** `makeExtensionPageBaseConfiguration` deliberately **does not** share the content controller — block lists, user CSS, and userscripts do not apply to extension UI pages (`WebEnvironment.swift:264–266`).

---

## HTTPS-only and redirects

- **Upgrade:** Main-frame `http://` → `https://` when policy allows (`TabWebDelegate.swift:138–141`, `HTTPSOnlyPolicy.upgrade`).
- **Session exceptions:** “Continue to HTTP” inserts host into `httpExceptions` / `privateHTTPExceptions` until quit (`HTTPSOnlyNotice.swift:55–57`).
- **Persistent allow:** “Always Allow HTTP” writes `sites.<host>.httpsOnly: false` (normal windows only).
- **Redirect attribution:** `startedByUser` treats `_isRedirect` navigations as inheriting prior user intent (`TabWebDelegate.swift:48–49`) — relevant for download prompts, not HTTPS loop detection.
- **Loop:** Same host returned to `http://` within 10 s via non-user navigation → `httpsOnlyBlocked` (`TabWebDelegate.swift:190–196`).
- **TLS failure:** Within 30 s of upgrade, provisional navigation errors matching `isSecureConnectionProblem` → notice with **original** http URL (`TabWebDelegate.swift:572–579`, `HTTPSOnlyNotice` in `BrowserView`).

---

## User agent and site identity

| Layer | Mechanism |
|---|---|
| WebKit suffix | `applicationNameForUserAgent` = Safari version string or full `userAgentSuffix` replacement |
| Per navigation | `_setCustomUserAgent:` on `WKWebpagePreferences` when supported; else GET reload with `webView.customUserAgent` |
| Persona JS | `SitePersonaScript` for Chrome/Firefox `sitePersonas` |
| Built-in fix | `SiteCompat.defaults` — `account.proton.me`, `pass.proton.me` → Firefox UA when no config entry covers host |

WebKit’s own Safari site-quirks list remains enabled separately (`SiteCompat.swift:5–6`).

---

## Speculative loading

- **DNS prefetch:** `WebEnvironment.enableDNSPrefetching` — private selector, only if `config.speculativeLoading && !isPrivate` (`WebEnvironment.swift:163–164, 192–200`).
- **TCP preconnect:** `BrowserModel.preconnect` — `_preconnectToServer:` with origin from `PreconnectPolicy.originToWarm` (30 s dedupe); triggered from address suggestions and link hover (`TabWebDelegate.swift:474–480`, `AddressSuggestions.swift`).

---

## Notifications, Web Push, Apple Pay

- **Page `Notification` API:** `WebsiteNotifications.providePageNotifications` installs `PageNotificationProvider` on each shared/private process pool; permission via `TabWebDelegate` + `sites` / `notificationPermissions`.
- **Service worker notifications:** `websiteDataStore:showNotification:` path; `serviceWorkerRegistrationURL` marks persistent; click via `_processPersistentNotificationClick:` when present (`WebsiteNotifications.swift:249–250, 396–408).
- **Web Push:** Explicitly **not** supported (`WebsiteNotifications.swift:249`, README §Not supported, Settings copy). **Out-of-scope** (Apple entitlement) unless product later claims otherwise.
- **Apple Pay / Payment Request:** README §Not supported; no implementation found. **Out-of-scope.**

---

## Bundled filter resources (names only)

- `Resources/PaddleFilters/`: `paddle-filters.txt`
- `Resources/FilterSnapshots/`: `easylist.txt`, `easyprivacy.txt`

---

## Findings

### FA-NET-01 — Startup blocker gate can load pages before all lists install
- **Severity:** S4  
- **Area:** Content blocking / startup  
- **Mechanism:** `BlockerGate` timeout 3 s (`Sources/PaddleCore/BlockerGate.swift:24–40`); `markReady()` after timeout triggers `UnblockedReload` (`BlockerGate.swift:77–99`, `WebEnvironment.loadContentBlockers` log ~572).  
- **Evidence:** README filter-syntax paragraph documents wait/reload; `WebEnvironment.swift:544–546`.  
- **User impact:** Brief window without full lists on slow compile; at most one reload unless post/media/typed.  
- **Disposition:** Accept (documented behavior)  
- **Suggested fix shape:** None required for audit; optional UX if compile routinely exceeds 3 s.  
- **Tree:** main  

### FA-NET-02 — Extension and extension-page configurations omit content rule lists
- **Severity:** S2  
- **Area:** Content blocking coverage  
- **Mechanism:** `makeExtensionPageBaseConfiguration` uses no shared `userContentController`; comment states block lists never reach extension pages (`WebEnvironment.swift:264–266`). Popups inherit configuration from opener where applicable.  
- **Evidence:** `WebEnvironment.swift:267–276` vs `makeConfiguration` line 131.  
- **User impact:** Extension UI and some extension-origin navigations are not filtered by Paddle lists (WebKit/extension sandbox still applies).  
- **Disposition:** Accept (architectural)  
- **Suggested fix shape:** Document in README if not already obvious to extension authors.  
- **Tree:** main  

### FA-NET-03 — Network redirect / CSP / removeparam rules are skipped, not emulated
- **Severity:** S4  
- **Area:** Filter converter / uBO parity  
- **Mechanism:** Unsupported options tallied in `SkipBreakdown.options`; names include `redirect`, `redirect-rule`, `csp`, `removeparam`, `queryprune`, `replace`, `header`, … (`FilterListConverter.swift:64–67`, `optionNames` ~730–735); lines with those options → `.unsupported(.option(...))` (~392–432).  
- **Evidence:** README.md:209 (`counted, not approximated`); converter header ~10–11.  
- **User impact:** Fewer blocked requests vs uBO on lists relying on `$redirect` / `$removeparam` / `$csp`.  
- **Disposition:** Accept (WebKit limitation, README accurate — not S2 overclaim)  
- **Suggested fix shape:** None; Activity “Not covered” disclosure already fed by sidecar summaries.  
- **Tree:** main  

### FA-NET-04 — WebKit compile failure drops regex rules or entire list
- **Severity:** S4  
- **Area:** Content blocking reliability  
- **Mechanism:** On `contentRuleListStoreCompileFailed`, retry `FilterListConverter.convert(..., dropRegex: true)` once; else sidecar + no install (`WebEnvironment.swift:818–843`). Empty rule count → sidecar only (~792–795).  
- **Evidence:** `WebEnvironment.compile` ~783–844.  
- **User impact:** List may block less than uBO until regex culprits removed from list text.  
- **Disposition:** Accept (defensive degradation)  
- **Suggested fix shape:** None in networking slice.  
- **Tree:** main  

### FA-NET-05 — Only configured list URLs plus paddle + user filters are compiled
- **Severity:** S4  
- **Area:** Filter list inventory  
- **Mechanism:** `performBlockerLoad` builds `sources` from `config.filterLists`, bundled paddle file, `user-filters.txt`; stray `filters/*.txt` ignored (~629–645).  
- **Evidence:** `WebEnvironment.swift:551–553`, `629–645`.  
- **User impact:** Dropping a URL from config stops blocking after reload; orphan files on disk have no effect.  
- **Disposition:** Accept  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-NET-06 — HTTPS-only TLS/connection failure surfaces dedicated notice (not generic error page)
- **Severity:** S4  
- **Area:** HTTPS-only UX  
- **Mechanism:** `didFailProvisionalNavigation` correlates `tab.httpsUpgrade` with `isSecureConnectionProblem` → `httpsOnlyBlocked = upgrade.original` (`TabWebDelegate.swift:572–579`); UI `HTTPSOnlyNotice` (`BrowserView` + `HTTPSOnlyNotice.swift`).  
- **Evidence:** Notice copy explains insecure HTTP; actions Back / Continue once / Always allow.  
- **User impact:** Clear choice when HTTPS upgrade fails; aligns with README `httpsOnly` row.  
- **Disposition:** Accept  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-NET-07 — HTTP→HTTPS→HTTP redirect loop blocked with same notice
- **Severity:** S4  
- **Area:** HTTPS-only / redirects  
- **Mechanism:** `handleHTTPSOnly` sets `httpsOnlyBlocked` when same normalized host returns to `http://` within 10 s on non-user navigation (`TabWebDelegate.swift:190–196`).  
- **Evidence:** `HTTPSOnlyPolicy` + loop branch.  
- **User impact:** Avoids infinite upgrade cycles; user must explicitly allow HTTP.  
- **Disposition:** Accept  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-NET-08 — Default WebKit UA suffix matches installed Safari
- **Severity:** S4  
- **Area:** User agent  
- **Mechanism:** Reads `/Applications/Safari.app/Contents/Info.plist` `CFBundleShortVersionString`; builds `Version/<ver> Safari/605.1.15` (`WebEnvironment.swift:64–73`); empty `userAgentSuffix` uses that string (~71–72).  
- **Evidence:** README `userAgentSuffix` row.  
- **User impact:** Sites see Safari-compatible token on default profile.  
- **Disposition:** Accept  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-NET-09 — Built-in SiteCompat sends Firefox UA to Proton sign-in hosts
- **Severity:** S4  
- **Area:** User agent / compatibility  
- **Mechanism:** `SiteCompat.defaults` for `account.proton.me`, `pass.proton.me` when no `siteUserAgents` / `sitePersonas` entry covers host (`SiteCompat.swift:15–24`, `PaddleConfig.pageUserAgent` ~990–998).  
- **Evidence:** Reason string in `SiteCompat.swift:16–17`.  
- **User impact:** Network fingerprint differs from default Safari identity on those hosts only.  
- **Disposition:** Accept (intentional fix)  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-NET-10 — Speculative DNS prefetch uses private WebKit preference API
- **Severity:** S4  
- **Area:** Speculative loading  
- **Mechanism:** `_setDNSPrefetchingEnabled:` via `enableDNSPrefetching`; no-op if selector missing (`WebEnvironment.swift:192–200`); gated by `speculativeLoading` and disabled for private windows (~163–164).  
- **Evidence:** README `speculativeLoading` row.  
- **User impact:** Extra DNS lookups for link hosts when enabled; privacy worker may weigh alongside prefetch.  
- **Disposition:** Accept  
- **Suggested fix shape:** None in this slice.  
- **Tree:** main  

### FA-NET-11 — Link/address-bar preconnect depends on private `_preconnectToServer:`
- **Severity:** S4  
- **Area:** Speculative loading  
- **Mechanism:** `BrowserModel.preconnect` + `PreconnectPolicy` 30 s interval (`BrowserModel.swift:110–123`, `PreconnectPolicy.swift:16–23`).  
- **Evidence:** `TabWebDelegate` hover path ~474–480.  
- **User impact:** Warm connections when API present; silent no-op otherwise.  
- **Disposition:** Accept  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-NET-12 — Web Push unsupported; page notifications only while tab/process alive
- **Severity:** S4  
- **Area:** Push / notifications  
- **Mechanism:** No Web Push entitlement path; README and Settings state limitation; `keepNotifyingSitesLive` keeps tabs awake for in-tab delivery only.  
- **Evidence:** README.md:227–229; `WebsiteNotifications.swift:249`; `SiteSettings.swift:35` comment.  
- **User impact:** Sites expecting push when browser closed fail until entitlement granted.  
- **Disposition:** Out-of-scope (documented)  
- **Suggested fix shape:** Entitlement + WebKit integration when Apple approves.  
- **Tree:** main  

### FA-NET-13 — Service-worker notifications distinct from Web Push in implementation
- **Severity:** S4  
- **Area:** Notifications  
- **Mechanism:** Persistent flag from `serviceWorkerRegistrationURL`; page provider ignores `isPersistent` SW notifications (`PageNotificationCallbacks.show` ~658–659); data-store delegate handles SW path (`WebsiteNotifications.swift:227–257`).  
- **Evidence:** `WebsiteNotifications.swift:227–257`; comments at 249–250, 396–397.  
- **User impact:** In-tab SW notifications can work; still not Apple Web Push.  
- **Disposition:** Accept  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-NET-14 — Apple Pay and Payment Request unavailable
- **Severity:** S4  
- **Area:** Payments  
- **Mechanism:** README §Not supported; no Payment Request handler or Apple Pay entitlement usage in App/Web layers searched.  
- **Evidence:** README.md:230.  
- **User impact:** Checkout flows requiring Apple Pay fail.  
- **Disposition:** Out-of-scope (documented)  
- **Suggested fix shape:** Apple payment entitlements if product scope expands.  
- **Tree:** main  

### FA-NET-15 — Autoplay defaults to Safari-like audio gate; per-site policy optional
- **Severity:** S4  
- **Area:** Media / network policy  
- **Mechanism:** `mediaTypesRequiringUserActionForPlayback = .audio` (`WebEnvironment.swift:158–160`); `sites.<host>.autoplay` → `_autoplayPolicy` when `supportsSiteAutoplay` (`TabWebDelegate.swift:219–249).  
- **Evidence:** README `autoplay` sites field; comment on WebKit default vs Safari.  
- **User impact:** Muted video autoplay allowed globally unless site set to `block`.  
- **Disposition:** Accept (PiP handled elsewhere)  
- **Suggested fix shape:** None in networking slice.  
- **Tree:** main  

### FA-NET-16 — Filter list download restricted to https URLs with validation
- **Severity:** S4  
- **Area:** Filter update / network fetch  
- **Mechanism:** `FilterUpdatePolicy.fileName` returns nil for non-https; `updateFilterLists` uses `BoundedDownload` 50 MB cap and `FilterListText.mayReplaceStoredList` (`WebEnvironment.swift:967–994`, `FilterListText.swift:10–17`).  
- **Evidence:** `FilterUpdatePolicy.swift:12–22`.  
- **User impact:** Non-https list entries ignored with status line.  
- **Disposition:** Accept  
- **Suggested fix shape:** None.  
- **Tree:** main  

---

## Oracle / regression tooling (not run)

- **`PADDLE_ORACLE`:** Opt-in ~2.5 min converter vs uBlock comparison (`AGENTS.md`); **not executed** this pass per task constraints.

---

## README alignment (filter syntax & Not supported)

| Claim | Code match |
|---|---|
| `##+js`, `redirect`, `csp`, `removeparam`, `replace=`, `header=` counted not approximated | Yes — `FilterListConverter` skip buckets |
| 3 s list wait + conditional reload | Yes — `BlockerGate`, `UnblockedReload` |
| Web Push not supported | Yes |
| Apple Pay not available | Yes |
| `speculativeLoading` / private off | Yes |
| Empty `userAgentSuffix` → Safari | Yes |

No **S2 README overclaim** identified for unsupported filter features (would be S2/S4 if README promised redirect support).
