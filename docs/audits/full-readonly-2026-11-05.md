# Paddle full read-only audit — 2026-11-05

**Status:** Waves 1–2 parent-audited and folded. Docs-only.

**Trees**

| Tree | Commit | Branch |
|---|---|---|
| Audit / main | `015dc73` | `cursor/full-audit-readonly-9af1` ← `origin/main` |
| PR #2 Settings | `73d02c6` | `cursor/settings-ui-audit-a3f0` (draft) |
| PR #3 Smart dark | `aa33b81` | `cursor/smart-dark-mode-c272` (draft) |
| Shipped | — | `/Applications/Paddle.app` **0.1.157 (157)** Developer ID, stapled |

**Method:** Code and docs only. No product edits, no notarize, no merge, no quit of other Debug Paddles. Live UI skipped: Settings-audit Debug Paddle (PID 7716) already holds `com.walker.Paddle`; `paddle` MCP discovery failed this session. Evidence index: [`docs/evidence/full-audit-2026-11-05/INDEX.md`](../evidence/full-audit-2026-11-05/INDEX.md).

**Plan (gitignored):** `.cursor/plans/paddle-full-readonly-audit.plan.md`

**S0 / S1:** none. Highest on **main:** **FA-TAB-01** (S2 Open, mounted-but-frozen switch); **FA-SET-01** (S2 Open on main / Fixed-on-PR #2, Sites “camera” subtitle); **FA-DRK-02/03/04** (S2 Fixed-on-PR #3); **FA-TEST-01** (S2 Accepted risk, no App test target).

**Correction applied:** **FA-SEC-12** claimed `httpsOnly` defaults off. **False.** `PaddleConfig` default is `httpsOnly: true` (`Sources/PaddleCore/PaddleConfig.swift:489`). Finding Closed. Residual HTTP is the exception path (user off, local hosts, Continue to HTTP). ATS in WebContent remains **FA-SEC-01**.

---

## Executive summary

Paddle at `015dc73` is a coherent personal WebKit browser: sleep/freeze policy, content blockers, profiles, extensions overlay, and a local MCP bridge with allow-lists. The shipped 0.1.157 binary matches the notarize-friendly entitlements (camera/mic/location/contacts; **no** passkeys, **no** `get-task-allow`).

Nothing in Wave 1 is a ship-blocker. The gaps that matter for daily use are: (1) **tab switch lag on idle-but-mounted pages** (freeze does not exclude `mountedWebTabs`); (2) **extension permission shims never populated**, so some Allow clicks still fail `permissions.contains`; (3) **no post–Track B Release footprint row**, so RAM claims after scroll-restore / 30 s SW grace are unverified; (4) **Apple-gated** passkeys, Web Push, and Apple Pay, handled honestly in README when Paddle does not claim they work.

Settings polish and smart dark mode exist only on **draft PRs #2 and #3**, not on main. Do not treat those UIs as shipped.

### What to do next (engineering, not this PR)

1. **FA-TAB-01** — do not freeze tabs that are still in `mountedWebTabs` (or unfreeze on mount).
2. **FA-EXT-05** — pass WebKit-unknown declared permissions into `CompatPlan.shimmedPermissions`.
3. Re-run the 2026-10-15 `footprint` protocol on Release when a quit-safe window exists (**FA-PERF-01**, **FA-PERF-06**).
4. Merge-or-rebase **PR #2** for Settings scanability; **PR #3** for already-dark sites (main `darkMode: always` invert).
5. After Apple Request **84Z8XFC523**, uncomment passkeys, `release.sh --notarize --install`.

---

## Disposition columns (locked)

`Open` · `Accepted risk` · `Fixed-on-PR` · `Out-of-scope (Apple entitlement)` · `Needs Walker` · `Closed`

Worker phrases “OK”, “By design”, “Accept”, “Closable”, “Inform”, “Fix candidate”, “Monitor” are **normalized** here. Parent corrections beat worker narrative.

---

## Disposition table

### Wave 1

| ID | Sev | Area | Title | Disposition | Tree |
|---|---|---|---|---|---|
| FA-HYG-01 | S2 | hygiene | No GitHub Actions workflows | Needs Walker | main |
| FA-HYG-02 | S3 | hygiene | CONTRIBUTING claims shortcut names are tested; only config keys are | Open | main |
| FA-HYG-03 | S4 | hygiene | README example still `0.1.156`; count is 157 | Fixed | main |
| FA-HYG-04 | S4 | hygiene | AGENTS.md same stale `0.1.156` example | Fixed | main |
| FA-HYG-05 | S3 | hygiene | `measurements.md` still says “330 MB in README”; README does not | Open | main |
| FA-HYG-06 | S3 | hygiene | `scripts/bench.py` undocumented outside its header | Open | main |
| FA-HYG-07 | S4 | hygiene | Blank issues enabled; SECURITY.md wants advisories | Accepted risk | main |
| FA-HYG-08 | S4 | hygiene | README default *values* not tested (keys are) | Accepted risk | main |
| FA-HYG-09 | S4 | hygiene | PR #3 README documents `smart`/`native` not on main | Fixed-on-PR | PR #3 |
| FA-HYG-10 | S4 | hygiene | Oracle harness only in AGENTS.md | Accepted risk | main |
| FA-HYG-11 | S4 | hygiene | CODEOWNERS single owner | Accepted risk | main |
| FA-ARC-01 | S2 | architecture | `-disable-dynamic-actor-isolation` on app target | Accepted risk | main |
| FA-ARC-02 | S3 | architecture | One `WKUserContentController` for all profiles/private | Accepted risk | main |
| FA-ARC-03 | S3 | architecture | MCP `read_config` dumps whole `config.json` | Accepted risk | main |
| FA-ARC-04 | S3 | architecture | `run_js` is consent-gated, not sandboxed | Accepted risk | main |
| FA-ARC-05 | S4 | architecture | Private windows filtered from MCP | Closed | main |
| FA-ARC-06 | S4 | architecture | Bridge allow-lists + `MCPTests` partition | Closed | main |
| FA-ARC-07 | S3 | architecture | Some KVC/`perform` paths not via `PrivateAPI` | Open | main |
| FA-ARC-08 | S3 | architecture | Second-instance Application Support race if handoff fails | Accepted risk | main |
| FA-ARC-09 | S4 | architecture | `paddle_state` triggers `measureMemory` | Accepted risk | main |
| FA-ARC-10 | S4 | architecture | Helper authenticates socket uid only | Accepted risk | main |
| FA-ARC-11 | S4 | architecture | Socket queue → MainActor hop pattern | Closed | main |
| FA-TAB-01 | S2 | tabs | Mounted-but-frozen tab misses instant switch | Fixed-on-PR | main |
| FA-TAB-02 | S4 | tabs | Leaving a tab clears BFCache | Accepted risk | main |
| FA-TAB-03 | S3 | tabs | 900 ms zoom defer vs scroll-restore window | Open | main |
| FA-TAB-04 | S4 | tabs | Cold wake after sleep is not instant | Accepted risk | main |
| FA-TAB-05 | S3 | tabs | Mosaic keeps all panes attached | Accepted risk | main |
| FA-TAB-06 | S3 | tabs | `mosaicStaysReady` keeps prior mosaic mounted | Accepted risk | main |
| FA-TAB-07 | S4 | tabs | PiP keeps tab awake; sleep exits PiP | Closed | main |
| FA-TAB-08 | S3 | tabs | Download retry skips frozen web views | Open | main |
| FA-TAB-09 | S4 | tabs | Find-in-page searches on every keystroke | Accepted risk | main |
| FA-TAB-10 | S3 | tabs | Inactive-space tabs keep views until sleep sweep | Accepted risk | main |
| FA-TAB-11 | S4 | tabs | Collapsed groups skipped in neighbor select | Closed | main |
| FA-TAB-12 | S4 | tabs | `resumeMediaOnSelect` default off | Closed | main |
| FA-SEC-01 | S2 | privacy | `NSAllowsArbitraryLoadsInWebContent` | Accepted risk | main |
| FA-SEC-02 | S4 | privacy | Passkeys entitlement pending `84Z8XFC523` | Out-of-scope (Apple entitlement) | main |
| FA-SEC-03 | S4 | privacy | Profile / private data stores | Closed | main |
| FA-SEC-04 | S4 | privacy | Private windows omit persistent artifacts | Closed | main |
| FA-SEC-05 | S4 | privacy | Camera/mic session prompts | Closed | main |
| FA-SEC-06 | S4 | privacy | Location site policy + Remember | Closed | main |
| FA-SEC-07 | S4 | privacy | Notifications HTTPS-only, denied in private | Closed | main |
| FA-SEC-08 | S4 | privacy | Contact autofill excludes passwords/cards | Closed | main |
| FA-SEC-09 | S3 | privacy | HTTP auth credentials `.forSession` in WebKit store | Accepted risk | main |
| FA-SEC-10 | S4 | privacy | Support dir 0700/0600 via `FilePermissions` | Closed | main |
| FA-SEC-11 | S4 | privacy | Exception log URL redaction | Closed | main |
| FA-SEC-12 | S4 | privacy | **Corrected:** `httpsOnly` defaults **true**; original “opt-in/off” claim was false | Closed | main |
| FA-SEC-13 | S3 | privacy | Private windows with extensions use default-profile controller | Accepted risk | main |
| FA-SEC-14 | S3 | privacy | Shared user scripts in private tabs | Accepted risk | main |
| FA-SEC-15 | S4 | privacy | Bridge excludes private windows | Closed | main |
| FA-SEC-16 | S4 | privacy | `ZipSafety` + `PrivateHost` MCP consent | Closed | main |
| FA-EXT-01 | S3 | extensions | Wave 4b leaves MV3 SW without prelude | Open | main |
| FA-EXT-02 | S4 | extensions | MV2 `webRequestBlocking` does not block | Accepted risk | main |
| FA-EXT-03 | S4 | extensions | `extensionsOnDemand` has no Settings control | Open | main |
| FA-EXT-04 | S4 | extensions | No `chrome.history` / `bookmarks` / `downloads` | Accepted risk | main |
| FA-EXT-05 | S3 | extensions | `shimmedPermissions` never set at load | Open | main |
| FA-EXT-06 | S4 | extensions | Native messaging only `com.walker.paddle.compat` | Closed | main |
| FA-EXT-07 | S4 | extensions | Store ZIP path uses `ZipSafety` | Closed | main |
| FA-EXT-08 | S3 | extensions | AMO chain needs bundled Mozilla root | Accepted risk | main |
| FA-EXT-09 | S3 | extensions | Adopted folder updates replace unverified tree | Accepted risk | main |
| FA-EXT-10 | S4 | extensions | Permission answers bound to identity | Closed | main |
| FA-EXT-11 | S3 | extensions | v2 prelude failure disables compat for session | Open | main |
| FA-EXT-12 | S4 | extensions | `extensionCompat.shims: false` strips stand-ins | Accepted risk | main |
| FA-EXT-13 | S4 | extensions | DNR enum stubs without inventing namespace | Accepted risk | main |
| FA-EXT-14 | S4 | extensions | Tab WebAuthn needs Apple entitlement | Out-of-scope (Apple entitlement) | main |
| FA-NET-01 | S4 | network | 3 s `BlockerGate` unblocked window | Accepted risk | main |
| FA-NET-02 | S2 | network | Extension pages omit content rule lists | Accepted risk | main |
| FA-NET-03 | S4 | network | `redirect`/`csp`/`removeparam` counted, not emulated | Accepted risk | main |
| FA-NET-04 | S4 | network | Compile failure drops regex or list | Accepted risk | main |
| FA-NET-05 | S4 | network | Only configured list URLs compile | Closed | main |
| FA-NET-06 | S4 | network | HTTPS-only TLS failure notice | Closed | main |
| FA-NET-07 | S4 | network | HTTP↔HTTPS loop notice | Closed | main |
| FA-NET-08 | S4 | network | Default UA suffix matches Safari | Closed | main |
| FA-NET-09 | S4 | network | SiteCompat Firefox UA for Proton hosts | Accepted risk | main |
| FA-NET-10 | S4 | network | DNS prefetch private API | Accepted risk | main |
| FA-NET-11 | S4 | network | `_preconnectToServer:` private API | Accepted risk | main |
| FA-NET-12 | S4 | network | Web Push unsupported | Out-of-scope (Apple entitlement) | main |
| FA-NET-13 | S4 | network | SW notifications ≠ Web Push | Closed | main |
| FA-NET-14 | S4 | network | Apple Pay / Payment Request absent | Out-of-scope (Apple entitlement) | main |
| FA-NET-15 | S4 | network | Audio autoplay gated; muted video allowed | Accepted risk | main |
| FA-NET-16 | S4 | network | Filter fetches https-only + 50 MB cap | Closed | main |
| FA-PERF-01 | S2 | perf | No post–Track B Release footprint row | Closed | main |
| FA-PERF-02 | S2 | perf | Orphan SW 218/647 MB claims unverified | Open | main |
| FA-PERF-03 | S4 | perf | Pool-wide `_terminateServiceWorkers` | Accepted risk | main |
| FA-PERF-04 | S4 | perf | WebKit “other” / BFCache / prewarm RAM | Out-of-scope (Apple entitlement) | main |
| FA-PERF-05 | S3 | perf | Global `org.WebKit.lowMemory` on background | Accepted risk | main |
| FA-PERF-06 | S2 | perf | On-demand savings measured on Debug only | Closed | main |
| FA-PERF-07 | S3 | perf | Dark + scroll scripts always injected | Accepted risk | main |
| FA-PERF-08 | S3 | perf | Comment-only MB/ms table still in measurements | Open | main |
| FA-PERF-09 | S3 | perf | Sweep `isBusy()` JS every minute per awake tab | Accepted risk | main |
| FA-PERF-10 | S4 | perf | Spare WebContent prewarm ~7 MB (unverified) | Accepted risk | main |
| FA-PERF-11 | S4 | perf | `malloc_zone_pressure_relief` on pressure | Accepted risk | main |
| FA-PERF-12 | S4 | perf | Process list private API with fallback | Accepted risk | main |
| FA-REL-01 | S4 | release | Passkeys entitlement commented so notary succeeds | Out-of-scope (Apple entitlement) | main |
| FA-REL-02 | S4 | release | `get-task-allow` refused at release | Closed | main |
| FA-REL-03 | S4 | release | `MIN_BUILD_NUMBER=157` | Closed | main |
| FA-REL-04 | S4 | release | Release version = `0.1.` + commit count | Closed | main |
| FA-REL-05 | S4 | release | pbxproj matches `project.yml` at this commit (drift is process) | Accepted risk | main |
| FA-REL-06 | S4 | release | Automatic Apple Development vs Manual Developer ID | Accepted risk | main |
| FA-REL-07 | S4 | release | `paddle-mcp` must be Developer ID + runtime + timestamp | Closed | main |
| FA-REL-08 | S4 | release | `spctl` only on `--notarize` path | Accepted risk | main |
| FA-REL-09 | S4 | release | `--install` `pgrep -x Paddle` may quit Debug too | Accepted risk | main |
| FA-REL-10 | S4 | release | Not MAS-ready (no sandbox) | Needs Walker | main |
| FA-REL-11 | S4 | release | No release CI (alias FA-HYG-01) | Needs Walker | main |
| FA-REL-12 | S4 | release | Installed 0.1.157 entitlements match stripped source | Closed | shipped 0.1.157 |

### Wave 2 — dark mode (parent-audited)

| ID | Sev | Area | Title | Disposition | Tree |
|---|---|---|---|---|---|
| FA-DRK-01 | S4 | dark | Global `always` → `smart`/`native` with `"always"` decode | Fixed-on-PR | PR #3 |
| FA-DRK-02 | S2 | dark | No global native-only page mode on main | Fixed-on-PR | main |
| FA-DRK-03 | S2 | dark | Per-site `darkMode` is `Bool?` on main | Fixed-on-PR | main |
| FA-DRK-04 | S2 | dark | Weaker `isNaturallyDark` still inverts some native-dark sites | Fixed-on-PR | main |
| FA-DRK-05 | S3 | dark | Early `:root { color-scheme: dark }` before natural-dark measure | Open | main |
| FA-DRK-06 | S3 | dark | PR smart invert still active on map/code-editor fixtures | Open | PR #3 |
| FA-DRK-07 | S3 | dark | `DarkModeScript` always injected (alias FA-PERF-07; PR script larger) | Accepted risk | main / PR #3 |
| FA-DRK-08 | S3 | dark | Tab bridge `setDarkMode(bool)` cannot express native/smart | Fixed-on-PR | main |
| FA-DRK-09 | S4 | dark | ⇧⌘D bool flip vs light/dark enum | Needs Walker | main / PR #3 |
| FA-DRK-10 | S4 | dark | View menu label + submenu on PR | Fixed-on-PR | PR #3 |
| FA-DRK-11 | S4 | dark | Chrome `appearance` vs page `darkMode` remain decoupled | Closed | main / PR #3 |

### Wave 2 — Settings (parent-audited)

| ID | Sev | Area | Title | Disposition | Tree |
|---|---|---|---|---|---|
| FA-SET-01 | S2 | settings | Sites subtitle claims per-site camera | Fixed-on-PR | main Open / PR #2 |
| FA-SET-02 | S3 | settings | Mosaic prefs unscannable dump | Fixed-on-PR | main Open / PR #2 |
| FA-SET-03 | S3 | settings | 4-column Settings masonry | Fixed-on-PR | main Open / PR #2 |
| FA-SET-04 | S3 | settings | Accent tints menu/picker values | Fixed-on-PR | main Open / PR #2 |
| FA-SET-05 | S3 | settings | Caption walls vs Learn more | Fixed-on-PR | main Open / PR #2 |
| FA-SET-06 | S3 | settings | Sites table 11 columns | Fixed-on-PR | main Open / PR #2 |
| FA-SET-07 | S4 | settings | Sites footer essay | Fixed-on-PR | main Open / PR #2 |
| FA-SET-08 | S4 | settings | Default-browser row truncates | Fixed-on-PR | main Open / PR #2 |
| FA-SET-09 | S4 | settings | Pane header accent fill | Fixed-on-PR | main Open / PR #2 |
| FA-SET-10 | S3 | settings | Sidebar search without match hints | Fixed-on-PR | main Open / PR #2 |
| FA-SET-11 | S3 | settings | Sites session/status not designed states | Open | both |
| FA-SET-12 | S4 | settings | Mosaic strip captions still inline | Open | both (PR residual) |
| FA-SET-13 | S4 | settings | Shortcuts pane not Form cards | Open | both |
| FA-SET-14 | S4 | settings | `extensionsOnDemand` no UI (alias FA-EXT-03) | Accepted risk | main |
| FA-SET-15 | S4 | settings | `sitePersonas` no UI | Accepted risk | both |
| FA-SET-16 | S4 | settings | Per-site `httpsOnly` not in Sites UI | Open | both |
| FA-SET-17 | S4 | settings | `extensionCompat` persona/shims view-only | Accepted risk | both |
| FA-SET-18 | S4 | settings | Card-per-folder Extensions scroll | Accepted risk | both |

### Wave 2 — tests (parent-audited)

| ID | Sev | Area | Title | Disposition | Tree |
|---|---|---|---|---|---|
| FA-TEST-01 | S2 | tests | Paddle scheme `testTargets: []` | Accepted risk | main |
| FA-TEST-02 | S3 | tests | README shortcuts untested (alias FA-HYG-02) | Open | main |
| FA-TEST-03 | S4 | tests | README default column untested (alias FA-HYG-08) | Accepted risk | main |
| FA-TEST-04 | S3 | tests | No `PictureInPictureScript` tests | Open | main |
| FA-TEST-05 | S3 | tests | Passkeys: core gating only | Accepted risk | main |
| FA-TEST-06 | S3 | tests | Bridge socket / paddle-mcp untested in SwiftPM | Accepted risk | main |
| FA-TEST-07 | S3 | tests | Tab sleep *implementation* App-only | Accepted risk | main |
| FA-TEST-08 | S4 | tests | Scroll restore vs `applySiteZoom` unwired in tests | Open | main |
| FA-TEST-09 | S4 | tests | Adblock oracle opt-in | Accepted risk | main |
| FA-TEST-10 | S4 | tests | RAM claims not asserted by tests | Accepted risk | main |
| FA-TEST-11 | S3 | tests | `ExtensionHost` runtime outside PaddleCoreTests | Accepted risk | main |
| FA-TEST-12 | S4 | tests | Default `swift test` includes heavy WebKit compiles | Accepted risk | main |

### Wave 2 — UX / a11y (parent-audited)

| ID | Sev | Area | Title | Disposition | Tree |
|---|---|---|---|---|---|
| FA-UX-01 | S4 | ux | Tint cap 4.5:1 via `ThemeContrast.maxTintStrength` | Closed | main |
| FA-UX-02 | S4 | ux | Menu keys for find, tabs, spaces, mosaic | Closed | main |
| FA-UX-03 | S4 | ux | Mosaic dividers VO adjustable | Closed | main |
| FA-UX-04 | S4 | ux | Sites table combine a11y | Closed | main / PR #2 |
| FA-UX-05 | S4 | ux | Find announces “Not found” | Accepted risk | main |
| FA-UX-06 | S3 | ux | New Tab hides empty Frequent/Pinned without copy | Open | main |
| FA-UX-07 | S4 | ux | Settings/Activity empty strings exist | Closed | main / PR #2 |
| FA-UX-08 | S3 | ux | Private/profile toolbar badges lack dedicated VO labels | Open | main |
| FA-UX-09 | S3 | ux | `highContrastTabs` unmeasured on screen | Accepted risk | main |
| FA-UX-10 | S4 | ux | Action catalog 121 vs stale “119” briefs | Closed | main |
| FA-UX-11 | S4 | ux | `tabKeyHighlightsLinks` default off | Accepted risk | main |
| FA-UX-12 | S4 | ux | Settings sidebar search labels | Closed | main / PR #2 |

---

## Deep sections (Wave 1)

### Tabs / navigation

**Mechanism:** `BrowserModel.mountedWebTabs` keeps selected, previous, hover, close-successor, and (if `mosaicStaysReady`) the prior mosaic’s panes attached. `TabSleepPolicy.tabsToFreeze` excludes selected/busy, **not** those extra mount IDs. `AppModel.sweepSleepingTabs` still calls `Tab.freeze()` (`_suspendPage:`). Return path is `unfreeze` + up to 300 ms presentation wait.

That is **FA-TAB-01**. AGENTS.md “awake tabs switch instantly” is violated for awake+frozen. Suggested shape: skip freeze while `id` is in any window’s `mountedWebTabs`.

Leaving a live tab clears BFCache (**FA-TAB-02**, Accepted risk; README Instant Back vs RAM). Track B defers `applySiteZoom` ~900 ms on back/forward (**FA-TAB-03**, still a residual race). `resumeMediaOnSelect` defaults false (**FA-TAB-12**, Closed).

### Privacy / transport

ATS: native app has no `NSAllowsArbitraryLoads`; WebKit has `NSAllowsArbitraryLoadsInWebContent` (**FA-SEC-01**, Accepted risk for browser compatibility). **HTTPS-only defaults on**, so main-frame HTTP upgrades unless local, session-excepted, or user-disabled. Do not treat FA-SEC-12 as an Open default-off bug.

Passkeys: entitlement XML-commented; `BrowserPasskeyCoordinator` checks `SecTaskCopyValueForEntitlement` and does not request platform authorization when false (**FA-SEC-02**, Apple). Profiles use `WKWebsiteDataStore(forIdentifier:)`; private uses `nonPersistent()`; last private window calls `endPrivateSession()`.

### Extensions

Load path: scan → persona → overlay clone → `WKWebExtension`. Native messaging is bus-only. **FA-EXT-05:** `CompatPlan.make` is invoked without `shimmedPermissions`; `webKitPermissionNames` omits `notifications` / `favicon`, so prelude E23 shims never fire for those declared names. **FA-EXT-03:** `extensionsOnDemand` is config-only (Settings worker should not mint a second Open ID; alias this).

### Networking / blocking

EasyList + EasyPrivacy + paddle + user filters → `WKContentRuleList`. Unsupported options are counted, not approximated (README matches). Extension *pages* do not share the content controller (**FA-NET-02**, Accepted risk). Web Push and Apple Pay are Apple-blocked; page notifications work while the tab/process is alive.

### Performance

Honest `docs/measurements.md`: 2026-10-15 Release footprint is the last full gate; 2026-10-19 on-demand numbers are Debug; 2026-11-05 Track B did not re-run the protocol. Comment-only MB claims (orphan SW, scriptlets, prewarm) stay **UNVERIFIED**. Global `notify_post("org.WebKit.lowMemory")` on resign-active reaches other apps’ WebKit (**FA-PERF-05**).

### Build / release

`scripts/release.sh` floors build at 157, refuses `get-task-allow`, verifies app + `paddle-mcp`, treats missing passkeys entitlement as PASS. Installed app 0.1.157 matches. `--install` may quit any process named `Paddle`. No MAS sandbox. No Actions CI (CONTRIBUTING forbids adding workflows unless the PR is about CI).

### Architecture

App is MainActor-default with **runtime** isolation checks disabled (`project.yml` crash comment, macOS 27.0.1). Compile-time Swift 6 stays on. Bridge: owner-only socket, `PeerRequirement` on accept, private windows invisible, `run_js` double-gated. Shared `WKUserContentController` is intentional for blockers/userscripts.

### Dark mode / appearance (Wave 2, parent-audited)

Chrome `appearance` (`NSApp.appearance`) and page `darkMode` (`DarkModeScript` in `.defaultClient`) are orthogonal on both trees (**FA-DRK-11**, Closed).

**Main** (`off` / `system` / `always`): invert path when `defaultDarkMode` is true. `evaluateAndApply` already skips `data-paddle-dark-mode="active"` when `isNaturallyDark()` is true (`DarkModeScript.swift:174–178`) — not unconditional invert. Detector is luminance + a few theme attrs (**FA-DRK-04**). No `PageDarkEngine.native` (**FA-DRK-02**). Per-site is `Bool?` (**FA-DRK-03**).

**PR #3:** `smart` / `native`; `"always"` decodes as `.smart`; richer detector; un-invert selectors; `setPolicy`. Residual: probes still show invert **active** on `map-canvas` and `code-editor` (**FA-DRK-06**, Open on PR). Live shots this session: none; cite `docs/evidence/smart-dark-mode-2026-11-05/probes.txt`.

⇧⌘D mosaic routing is unchanged; saved value changes bool → enum (**FA-DRK-09**, Needs Walker).

### Settings IA (Wave 2, parent-audited)

**Main still has the P1/P2 Settings defects PR #2 already fixed.** Parent re-checked `SettingsViews.swift:32` — Sites summary still says “location, and camera.” Camera/mic are session-only. `SettingsForm` is still `maxColumns: 4` (`SettingsViews.swift:235`). Disposition for FA-SET-01…10 is **Fixed-on-PR** (remain Open on unmerged main). Residual on both trees: Sites session/status states (**FA-SET-11**), per-site `httpsOnly` UI (**FA-SET-16**). `extensionsOnDemand` aliased to **FA-EXT-03**. Evidence: PR #2 PNGs under `settings-audit/docs/evidence/` — not re-shot this session.

### Tests (Wave 2, parent-audited)

`swift test` covers PaddleCore (~103 test files). App scheme `testTargets: []` (**FA-TEST-01**, Accepted risk). CONTRIBUTING overstates shortcut tests (**FA-TEST-02** / FA-HYG-02). No `PictureInPictureScript` tests (**FA-TEST-04**). Worker verify.txt reported `FA-TEST` count 0 because it was written before headings; parent count on disk is **12**. Suite was not re-run this session.

### UX / accessibility (Wave 2, parent-audited)

Contrast cap is code, not eyeballing: `ThemeContrast.maxTintStrength` requires 4.5:1 (**FA-UX-01**, Closed). Mosaic dividers have `accessibilityAdjustableAction` (**FA-UX-03**). Live VO of toolbar/New Tab is **UNVERIFIED visually**. Open: silent New Tab empty Frequent (**FA-UX-06**), Private/profile badge labels (**FA-UX-08**). Menu `add(` count is 121 unique actions (hygiene’s 119 was a stale brief).

---

## Apple-blocked vs closable

| Gap | Class | IDs |
|---|---|---|
| Browser passkeys for arbitrary RPs | Apple (`84Z8XFC523`) | FA-SEC-02, FA-EXT-14, FA-REL-01 |
| Web Push while quit / tab closed | Apple (requested) | FA-NET-12 |
| Apple Pay / Payment Request | Apple | FA-NET-14 |
| WebKit engine RAM / BFCache / per-registration SW stop | Apple / engine (lightness P9–P13) | FA-PERF-03, FA-PERF-04 |
| ATS-in-WebContent + HTTPS-only exceptions | Closable product | FA-SEC-01 |
| Mounted-tab freeze | Closable Paddle | FA-TAB-01 |
| Empty `shimmedPermissions` | Closable Paddle | FA-EXT-05 |
| Settings IA | Closable via PR #2 | FA-SET-01…10 Fixed-on-PR; FA-SET-11/16 still Open |
| Smart dark | Closable via PR #3 | FA-DRK-02/03/04 Fixed-on-PR; FA-DRK-06 Open on PR |

---

## Coverage gaps (honest)

- No live Settings / tab / dark-mode shots this session (bundle id + MCP).
- No `footprint` / `PADDLE_ORACLE` / Release `xcodebuild` this session.
- Live `~/Library/Application Support/Paddle/` modes not `stat`’d (code + tests only).
- App UI has **no** `xcodebuild` test target (`project.yml` `testTargets: []`) — FA-TEST-01.
- Tests worker verify.txt heading count was 0 (written early); parent counted **12** `FA-TEST-*` headings on disk and did not respawn.

---

## Recommended next eng waves (priority)

1. **Tabs:** FA-TAB-01 freeze vs mount set; optional FA-TAB-08 download retry unfreeze.
2. **Extensions:** FA-EXT-05 shim list; FA-EXT-01 4b SW wrap; FA-EXT-11 fallback banner.
3. **Measure:** FA-PERF-01 Release footprint; FA-PERF-06 on-demand on notarized app.
4. **Docs hygiene:** FA-HYG-03/04 version examples; FA-HYG-05 measurements 330 MB line; FA-HYG-02 shortcut test or CONTRIBUTING wording.
5. **Product PRs already open:** Settings UI (PR #2, FA-SET-01…10), smart dark (PR #3, FA-DRK-02/03/04) — review/merge, do not reimplement on main. Residual: FA-SET-11/16, FA-DRK-06.
6. **Apple:** passkeys uncomment after 84Z8XFC523; Web Push if granted.
7. **A11y polish:** FA-UX-06 New Tab empty Frequent copy; FA-UX-08 Private/profile VO labels.

---

## Worker memos

| Slug | Path |
|---|---|
| hygiene | [`_worker-hygiene.md`](_worker-hygiene.md) |
| architecture | [`_worker-architecture.md`](_worker-architecture.md) |
| tabs | [`_worker-tabs.md`](_worker-tabs.md) |
| privacy | [`_worker-privacy.md`](_worker-privacy.md) |
| extensions | [`_worker-extensions.md`](_worker-extensions.md) |
| network | [`_worker-network.md`](_worker-network.md) |
| perf | [`_worker-perf.md`](_worker-perf.md) |
| release | [`_worker-release.md`](_worker-release.md) |
| settings | [`_worker-settings.md`](_worker-settings.md) |
| darkmode | [`_worker-darkmode.md`](_worker-darkmode.md) |
| tests | [`_worker-tests.md`](_worker-tests.md) |
| ux | [`_worker-ux.md`](_worker-ux.md) |
