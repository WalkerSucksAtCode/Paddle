# Full audit — PaddleCore tests vs product claims (read-only)

**Commit:** `main` @ `015dc73a2c04beeb7308c3e77e3148dc075f680b`  
**Scope:** `swift test` / `PaddleCoreTests` only; App target has no XCTest attachment.

## Method (5 lines)

1. Listed and sampled `Tests/PaddleCoreTests/` (Swift Testing `@Test`; no legacy `XCTestCase` test methods in tree).
2. Read `Package.swift`, `project.yml` Paddle scheme, `CONTRIBUTING.md:16`, `AGENTS.md` Commands (oracle, `swift test` gate).
3. Mapped core modules in `Sources/PaddleCore/` to nearest test files; flagged core sources with no exercising tests.
4. Cross-checked README / agent behavioral claims against automated coverage (not suite execution this session).
5. Aliased hygiene findings **FA-HYG-02** and **FA-HYG-08** where they are the same verification debt; did not re-number.

## Test harness topology

| Layer | Entry | Tests |
|---|---|---|
| **PaddleCore** | `swift test` (`Package.swift` → `PaddleCoreTests`) | **103** top-level `Tests/PaddleCoreTests/*.swift` plus `Oracle/` (3 files: `AdblockOracleTests.swift`, `WebKitRuleEvaluatorTests.swift`, helper `WebKitRuleEvaluator.swift`) and shared fixtures (`PackageTestSupport.swift`, `BrowserImportFixtures.swift`, `EasyListRegexFixture.swift`) |
| **App (Paddle.app)** | `xcodebuild -scheme Paddle` | **`project.yml` → `scheme.testTargets: []`** — no UI or integration tests in Xcode scheme |
| **paddle-mcp** | `App/PaddleMCP/main.swift` | Not a SwiftPM test target; stdio relay untested in package |

**Framework:** Swift Testing (`import Testing`); WebKit used in a subset of tests (`@MainActor`, real `WKContentRuleListStore` / `WKWebView`).

## Coverage map (PaddleCoreTests by domain)

| Domain | Test files (representative) | Core modules exercised |
|---|---|---|
| **Config & docs sync** | `ConfigTests`, `ConfigFileTests`, `ConfigValidatorTests`, `SiteSettingsTests`, `ProfileOverridesTests`, `SettingsLinkTests` | `PaddleConfig`, `ConfigFile`, `ConfigValidator`, `SiteSettings`; **`readmeTableMatchesCodingKeys`** in `SiteSettingsTests` |
| **Shortcuts (parse/display only)** | `ShortcutTests` | `Shortcut` — **not** README ↔ `MainMenu` parity (see FA-HYG-02) |
| **MCP / control bridge (core)** | `MCPTests`, `BridgeLimitsTests` | `MCP.swift`, `PaddleBridgeTools`, bridge key/menu classifications; reads `App/Paddle/MainMenu.swift` from disk for **allow-listed** actions only |
| **Tab sleep policy** | `TabSleepPolicyTests`, `MosaicSleepTests` | `TabSleepPolicy` (freeze/sleep rules; PiP/sound/busy/pinned) — **not** `Tab.swift` WebView drop |
| **Session & profiles** | `SessionTests`, `ProfilesTests`, `SpacesTests`, `TabGroupsTests`, `TabOrderTests`, `SplitsTests`, `PaneLayoutTests` | `Session`, `SessionStore`, profiles/spaces/mosaic models |
| **History & suggestions** | `HistoryStoreTests`, `SuggestionsTests`, `FaviconsTests`, `NewTabSitesTests`, `NewTabSectionTests`, `SuggestedFeedsTests`, `FeedsTests` | SQLite history via `HistoryStore` ( **`ImportSQLite.swift` has no direct unit tests** ) |
| **Bookmarks & imports** | `BookmarksTests`, `Browser*ImportTests`, `BrowserImportFixtures` | Chromium/Firefox/Edge readers, MozLZ4 (`MozLZ4Tests` in `BrowserSettingsImportTests.swift`), SNSS fixtures |
| **Address & navigation helpers** | `AddressResolverTests`, `OpenableURLTests`, `DisplayURLTests`, `HTTPSOnlyPolicyTests`, `PreconnectPolicyTests`, `SameSiteTests` | URL/policy core |
| **Site policy & scripts** | `SitePolicyTests`, `SitePersonaScriptTests`, `UserScriptTests`, `ScrollRestoreScriptTests`, `PageWorkScriptTests`, `DarkModeScript` (via `SitePolicyTests`) | Page-world scripts; **`PictureInPictureScript.swift` has no tests** |
| **Blocking & filters** | `FilterListConverterTests`, `FilterListTextTests`, `FilterUpdatePolicyTests`, `RuleListSummaryTests`, `RegexTranslatorTests`, `RegexSafetyTests`, `BlockerGateTests`, `ScriptletParserTests`, `ScriptletLibraryTests`, `ScriptletDispatcherTests`, `ScriptletLatin1Tests`, `BlockerGateTests` | Converter, scriptlets, startup gate; **`webKitCompilesOutput` / `bundledPaddleFiltersCompile`** compile real lists |
| **Oracle (opt-in + always-on helper tests)** | `Oracle/AdblockOracleTests.swift`, `Oracle/WebKitRuleEvaluatorTests.swift` | uBO TSV comparison **only when `PADDLE_ORACLE=1`**; evaluator unit tests run in default suite |
| **Extensions (install/parse/policy)** | `ExtensionManifestTests`, `CRX3Tests`, `ExtensionScanTests`, `ExtensionPermissionsTests`, `ExtensionIdentityTests`, `ExtensionCompatTests`, `ExtensionOverlayTests`, `OnDemandExtensionTests`, `StoreInstallTests`, … | Manifest/CRX/permissions — **not** `App/Paddle/Extensions/ExtensionHost.swift` runtime |
| **Passkeys (core helpers only)** | `BrowserPasskeySupportTests` | Entitlement key + authorization gating — **not** WebAuthn in `BrowserPasskeyCoordinator` |
| **Privacy & safety** | `PrivateBrowsingTests` (includes `TabAudioTests`, `ViewSourceTests`), `LogRedactionTests`, `FilePermissionsTests`, `PrivateHostTests`, `ContactAutofillTests`, `CertificateInfoTests` | |
| **Themes & chrome models** | `ThemeTests`, `MosaicIconTests`, `ResponsiveDevicesTests`, `ProcessBreakdownTests`, `DisplayTextTests` | `ProcessBreakdownTests` parses **labels**, does not measure live RAM |
| **Reader** | `ReaderArticleTests` | `ReaderExtractor` script strings only (light) |
| **Misc** | `PeerRequirementTests`, `PreviewExportTests`, `ChromeUpdateCheckTests`, `AMO*Tests`, `SearchEnginesTests`, `JSONSpansTests`, … | |

**Automated doc ↔ code checks that exist today**

| Claim | Test shape | Gap |
|---|---|---|
| README `config.json` **keys** ↔ `PaddleConfig.CodingKeys` | `SiteSettingsTests.readmeTableMatchesCodingKeys` | None for keys |
| README **default column** ↔ `PaddleConfig()` | — | **FA-HYG-08** |
| README **shortcut action names** ↔ `MainMenu` | — | **FA-HYG-02** (manual parity only in hygiene pass) |
| Bridge `set_config` / `menu_action` allow lists ↔ config keys / subset of menu | `MCPTests.everyConfigKeyIsClassifiedExactlyOnce`, `allowedMenuActionsAreRealMenuItems` | Full menu list not compared to README prose |
| `resumeMediaOnSelect` default off | `ConfigTests.resumeMediaOnSelectDefaultsToOff` | App behavior on tab select still manual |

## App-layer untested (by design in Xcode scheme)

All of `App/Paddle/` — including **`Tab`**, **`BrowserModel`**, **`WebEnvironment`**, **`TabWebDelegate`**, **`ControlBridge`**, **`BridgeSocketServer`**, **`ExtensionHost`**, SwiftUI chrome, session save/restore wiring, memory sampling, tab sleep **implementation** — relies on manual use and Release smoke; **`swift test` does not build or exercise the app target.**

## Oracle (opt-in)

- **Command (documented):** `PADDLE_ORACLE=1 swift test --filter AdblockOracle` (`AGENTS.md`; ~2.5 min cited; needs `build/oracle/` data).
- **Gate:** `@Test(.enabled(if: ProcessInfo.processInfo.environment["PADDLE_ORACLE"] == "1"), .timeLimit(.minutes(60)))` in `Oracle/AdblockOracleTests.swift`.
- **Behavior:** Disagreements vs uBlock Origin are **reported**, not assertion failures; missing data fails the test.
- **Always-on:** `Oracle/WebKitRuleEvaluatorTests.swift` exercises the in-test evaluator helper (not the full 221k-row oracle).

## Flaky / slow notes (from test comments only — no “flaky” labels in tree)

| Note | Source |
|---|---|
| Scriptlet harness polls up to **15 s** when “many WebKit tests run in parallel and a page is slow to start” | `ScriptletLibraryTests.swift:45–46` |
| Oracle test **60 min** time limit when enabled | `AdblockOracleTests.swift:83` |
| `BlockerGateTests` uses **20 ms** gate timeouts (deterministic, not wall-clock suite timing) | `BlockerGateTests.swift` |
| Default suite includes multiple **real WebKit** compiles/loads: `FilterListConverterTests.webKitCompilesOutput`, `bundledPaddleFiltersCompile`, scriptlet library pages, scroll restore file loads, dark-mode script injection tests | `@MainActor` + `import WebKit` in 12+ test files |
| **No** test marked flaky via `.disabled` / comment “flake” in `PaddleCoreTests` | — |

## S0 summary

**No S0 test-gap findings** — core tests do not falsely assert full-browser or bridge-transport safety; the largest risks are **missing App tests** and **partial README sync**, not inverted security tests.

---

### FA-TEST-01 — App target has zero scheme tests

- Severity: S2
- Area: tests
- Mechanism: XcodeGen Paddle scheme sets `testTargets: []`; all automated tests live in SwiftPM `PaddleCoreTests` only
- Evidence: `project.yml:76`; `Package.swift:15–18`; no `Tests/PaddleAppTests/`
- User impact: Regressions in tab switching, WebKit delegates, bridge socket, extension host, and SwiftUI only surface in manual runs or after ship.
- Disposition: Accepted risk
- Suggested fix shape: Optional small App test target for pure Swift helpers, or documented requirement to run `/Applications/Paddle.app` smoke; not expanding scope without Walker.
- Tree: main

### FA-TEST-02 — README shortcut list not guarded by tests (alias FA-HYG-02)

- Severity: S3
- Area: tests
- Mechanism: Same as **FA-HYG-02** — `CONTRIBUTING.md:16` overstates coverage; `ShortcutTests` covers parsing only; `MCPTests.mainMenuActionNames()` validates bridge allow-list ⊆ MainMenu, not README paragraph
- Evidence: `CONTRIBUTING.md:16`; `Tests/PaddleCoreTests/ShortcutTests.swift`; `Tests/PaddleCoreTests/MCPTests.swift:177–197`; hygiene worker manual 119=119
- User impact: Shortcut rename / README drift until manual review.
- Disposition: Open
- Suggested fix shape: Test that parses README shortcut sentence and compares to `mainMenuActionNames()` set (mirror `readmeTableMatchesCodingKeys`), or narrow CONTRIBUTING text.
- Tree: main

### FA-TEST-03 — README config default column not guarded (alias FA-HYG-08)

- Severity: S4
- Area: tests
- Mechanism: Same as **FA-HYG-08** — keys synced; defaults live in Swift (`PaddleConfig.init`, `ConfigFile.defaults`) without README table column test
- Evidence: `SiteSettingsTests.readmeTableMatchesCodingKeys`; `ConfigFileTests` / `ConfigTests` default tests ≠ README prose
- User impact: Wrong default documented in README until caught manually.
- Disposition: Accepted risk
- Suggested fix shape: Table-driven test comparing README default cells to `PaddleConfig()` / site field defaults for scalar keys.
- Tree: main

### FA-TEST-04 — `PictureInPictureScript` has no PaddleCore tests

- Severity: S3
- Area: tests
- Mechanism: PiP page script and handler name live in core; sleep policy tests mention PiP at policy level but no JS harness for toggle/exit/monitor messages
- Evidence: `Sources/PaddleCore/PictureInPictureScript.swift`; `rg PictureInPicture Tests/PaddleCoreTests` → no matches; `TabSleepPolicyTests` freeze rules only
- User impact: PiP script regressions break “keep tab awake” and ⌃⌘P until manual site test.
- Disposition: Open
- Suggested fix shape: Minimal WKWebView page test (same pattern as `ScrollRestoreScriptTests`) asserting handler registration and toggle/exit strings.
- Tree: main

### FA-TEST-05 — Passkeys: core unit tests only, not WebAuthn flow

- Severity: S3
- Area: tests
- Mechanism: `BrowserPasskeySupportTests` covers entitlement key and `shouldRequestPlatformAuthorization`; `docs/passkeys.md` describes coordinator + WebKit behavior in App
- Evidence: `Tests/PaddleCoreTests/BrowserPasskeySupportTests.swift` (3 tests); `App/Paddle/Web/BrowserPasskeyCoordinator.swift` untested in package
- User impact: Entitlement gating logic can regress in core; end-to-end passkey sign-in still manual after Apple approval.
- Disposition: Accepted risk
- Suggested fix shape: Keep core tests; optional App/UI test behind entitlement when profile enables capability.
- Tree: main

### FA-TEST-06 — Control bridge transport untested in SwiftPM

- Severity: S3
- Area: tests
- Mechanism: `MCPTests` + `BridgeLimitsTests` cover JSON-RPC core, tool schemas, write timeout constant; **`BridgeSocketServer`**, **`ControlBridge+Tools`**, and **`paddle-mcp`** relay are App/helper code with no tests
- Evidence: `Tests/PaddleCoreTests/MCPTests.swift`; `Tests/PaddleCoreTests/BridgeLimitsTests.swift`; `App/Paddle/Bridge/BridgeSocketServer.swift`; `App/PaddleMCP/main.swift`
- User impact: Socket framing, owner-only path, and tool dispatch bugs need manual MCP client exercise.
- Disposition: Accepted risk
- Suggested fix shape: Optional integration test with temporary socket + `MCPServerCore` loopback; out of scope for core-only package today.
- Tree: main

### FA-TEST-07 — Tab sleep / instant switch behavior is App-only

- Severity: S3
- Area: tests
- Mechanism: `TabSleepPolicyTests` exhaustively models freeze/sleep decisions; **`Tab.swift`** owns WKWebView drop, wake, and AGENTS “awake tabs switch instantly” rule with no automated check
- Evidence: `Tests/PaddleCoreTests/TabSleepPolicyTests.swift`; `App/Paddle/Browser/Tab.swift`; `AGENTS.md` awake-tab latency rule
- User impact: Policy vs implementation drift (e.g. PiP monitor, unsaved changes) caught only in use.
- Disposition: Accepted risk
- Suggested fix shape: UI test or bridge-driven timing probe — not present today.
- Tree: main

### FA-TEST-08 — Scroll restore script tested; zoom reapply interaction is not

- Severity: S4
- Area: tests
- Mechanism: `ScrollRestoreScriptTests` uses real WKWebView back/forward on file URLs; AGENTS notes `applySiteZoom` from `pageCommitted` can fight scroll restoration on timeline sites — **App** wiring untested with zoom
- Evidence: `Tests/PaddleCoreTests/ScrollRestoreScriptTests.swift`; `AGENTS.md` ScrollRestore / applySiteZoom bullet; no combined test
- User impact: Back-on-X scroll bugs may return if App zoom hook order changes.
- Disposition: Open
- Suggested fix shape: Integration scenario test (core script + documented zoom application order mock) or manual checklist on X/Timeline.
- Tree: main

### FA-TEST-09 — Adblock oracle regression is opt-in and data-heavy

- Severity: S4
- Area: tests
- Mechanism: Full converter vs uBO on ~221k rows runs only with `PADDLE_ORACLE=1`; not part of default `swift test` or CI (no Actions on main)
- Evidence: `Tests/PaddleCoreTests/Oracle/AdblockOracleTests.swift:7–8,83`; `AGENTS.md:23`; **FA-HYG-10** (README silent on oracle)
- User impact: Filter converter regressions vs uBO may ship if contributors skip oracle locally.
- Disposition: Accepted risk
- Suggested fix shape: Document oracle in CONTRIBUTING; optional periodic Walker-run with pinned `build/oracle` data.
- Tree: main

### FA-TEST-10 — README memory / resource claims not validated by tests

- Severity: S4
- Area: tests
- Mechanism: README Features describe toolbar memory breakdown and sleep timings; `ProcessBreakdownTests` validates parsing of breakdown **strings**, not process footprint or WebContent counts
- Evidence: `README.md:11`; `Tests/PaddleCoreTests/ProcessBreakdownTests.swift`; `docs/measurements.md` (manual methodology)
- User impact: Resource claims remain measurement-backed outside tests (AGENTS requires measurement for claims).
- Disposition: Accepted risk
- Suggested fix shape: Keep measurements in docs/scripts; do not pretend `swift test` proves RAM.
- Tree: main

### FA-TEST-11 — Extension runtime (WebExtensions host) outside PaddleCoreTests

- Severity: S3
- Area: tests
- Mechanism: Large `Extension*Tests` suite covers manifests, CRX, permissions, overlays; **`ExtensionHost`**, on-demand RAM behavior, and WebKit extension APIs are App-only
- Evidence: `Tests/PaddleCoreTests/ExtensionScanTests.swift` et al.; `App/Paddle/Extensions/ExtensionHost.swift`; README extensions section
- User impact: Extension load, update, and compat shims regress without unit signal.
- Disposition: Accepted risk
- Suggested fix shape: Targeted App tests for manifest load failures only if Walker wants test weight in Xcode target.
- Tree: main

### FA-TEST-12 — Default `swift test` includes heavyweight WebKit work

- Severity: S4
- Area: tests
- Mechanism: Not flaky by declaration, but suite wall time driven by rule compilation and multi-page scriptlet/scroll tests; ScriptletLibrary documents parallel slowness
- Evidence: `FilterListConverterTests.webKitCompilesOutput`; `ScriptletLibraryTests.swift:45–46`; multiple `@MainActor` WebKit files
- User impact: Contributors may skip full `swift test` locally; core-only gate still meaningful but slow.
- Disposition: Accepted risk
- Suggested fix shape: Optional tags/filters for WebKit tests (would be product/test harness change — not done here).
- Tree: main

---

## Product claims vs automated proof (selected)

| Claim source | Automated in PaddleCoreTests? | Notes |
|---|---|---|
| CONTRIBUTING: config keys **and shortcuts** tested | Partial | Keys yes; shortcuts **FA-TEST-02** |
| EasyList → WebKit lists compile | Yes | `webKitCompilesOutput`, bundled filters compile |
| Tab sleep timings / PiP keeps awake | Partial | Policy yes (`TabSleepPolicyTests`); PiP script **FA-TEST-04**; App sleep **FA-TEST-07** |
| Passkeys (docs) | Partial | Core gating only **FA-TEST-05** |
| Control bridge MCP tools | Partial | Core MCP JSON **FA-TEST-06** |
| `swift test` proves core only (AGENTS) | Honest | App explicitly out of scheme **FA-TEST-01** |
| Oracle vs uBO | Opt-in | **FA-TEST-09** |

## Verification debt aliasing

| ID | Use in this memo |
|---|---|
| FA-HYG-02 | Same gap as **FA-TEST-02** (shortcut README sync) |
| FA-HYG-08 | Same gap as **FA-TEST-03** (README defaults) |
| FA-HYG-10 | Related context for **FA-TEST-09** (oracle not in user README) |

---

## Session note

Full `swift test` was **not** run in this worker (read-only audit). Hygiene worker reported `readmeTableMatchesCodingKeys` PASS at `015dc73`.
