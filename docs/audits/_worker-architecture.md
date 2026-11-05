# Paddle architecture audit (read-only)

**Tree:** `main` @ `015dc73a2c04beeb7308c3e77e3148dc075f680b`  
**Scope:** Swift 6 isolation, WebKit process model, module boundaries, control bridge + `paddle-mcp`.  
**Out of scope:** Settings IA, extensions chrome UI, filter-list syntax (other workers).

**S0:** None identified in this pass (no unauthenticated remote control path, no private-window MCP leak in code reviewed, no uncaught private-selector calls that bypass `PrivateAPI` / local `responds(to:)` guards in the audited bridge/WebEnvironment paths).

---

## Process model (WebKit + Paddle)

Paddle is a **single UI process** (`com.walker.Paddle`) hosting AppKit/SwiftUI chrome. Page work runs in **WebKit child processes** spawned from shared **`WKProcessPool`** instances. A separate **Foundation-only helper** (`paddle-mcp`) is not part of WebKit; it only relays stdio ↔ Unix socket.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│  Paddle.app (UI / AppKit + SwiftUI) — MainActor-default                 │
│  AppModel · BrowserWindowController · ControlBridge · WebEnvironment    │
└───────────────┬─────────────────────────────────────────────────────────┘
                │ WKWebView (per awake tab / extension page)
                │ shared WKUserContentController (block lists, userscripts)
                │ per-profile WKWebsiteDataStore (+ one non-persistent private store)
                ▼
┌─────────────────────────── WKProcessPool ("Paddle") ─────────────────────┐
│  WebContent (×N)     one primary process per active page (may be shared) │
│  Networking (×1–N)   reported via _networkingProcessInfo                 │
│  GPU (×1)            reported via _gpuProcessInfo                        │
│  Service / shared worker WebContent (orphan worker sweep in AppModel)     │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────── WKProcessPool ("Paddle Private") ────────────────┐
│  WebContent for private windows only (no persistent cookies/storage)     │
└──────────────────────────────────────────────────────────────────────────┘

Extension background pages / popups: additional WebContent processes tagged
`.extensionView` in ProcessBreakdown (ExtensionHost + WKWebExtensionController
per profile; private windows reuse default profile's controller when allowed).

┌──────────────── paddle-mcp (Contents/Helpers) ───────────────────────────┐
│  stdin/stdout ◄──► AF_UNIX stream ◄──► BridgeSocketServer (in Paddle)    │
│  No MCP parsing; SecCode peer check happens in Paddle on accept()          │
└──────────────────────────────────────────────────────────────────────────┘
```

**Tab ↔ WebContent lifecycle:** `Tab.sleep()` saves `interactionState`, nils delegates, removes `WKWebView` (process may exit when unreferenced). `Tab.wake()` builds configuration via `WebEnvironment.makeConfiguration`, creates a new `WKWebView`, restores state or loads URL. Sleeping tabs are intentionally **invisible to MCP tab lists** until woken (`readableWebView` / `select_tab`).

**Memory accounting:** `AppModel.measureMemory()` uses `ProcessMemory.snapshot()` (`WKProcessPool._webContentProcessInfo`, GPU/networking private APIs via `PrivateAPI.call`) when available; falls back to per-tab `_webProcessIdentifier`. Aggregation is pure logic in `PaddleCore.ProcessBreakdown`.

**Single-instance guard:** `PaddleApp` detects another running copy with the same bundle ID, forwards URLs, and terminates before touching Application Support (prevents session/config corruption).

---

## Module map

| Layer | Location | Role |
| --- | --- | --- |
| **PaddleCore** | `Sources/PaddleCore/` | Swift 6 package (`swift-tools-version: 6.2`, `.v6`); UI-free: config model, session/history stores, adblock converter, MCP protocol + bridge allow-lists (`MCP.swift`, `BridgeLimits`, `PeerRequirement`, `PrivateAPI`, `ProcessBreakdown`, tab sleep policy, etc.). Unit-tested with `swift test`. |
| **Paddle app** | `App/Paddle/` | macOS 27 target; `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`; links PaddleCore. Subsystems: `AppModel`, `Browser/` (`Tab`, `BrowserModel`), `Web/` (`WebEnvironment`, delegates, downloads), `Bridge/`, `Extensions/`, `UI/`, `Settings/`. |
| **paddle-mcp** | `App/PaddleMCP/main.swift` | Tool target; `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`; embedded to `Contents/Helpers`, signed with app (`project.yml`). |
| **Build** | `project.yml` | XcodeGen source of truth; `OTHER_SWIFT_FLAGS` includes `-disable-dynamic-actor-isolation` on app target. |
| **Resources** | `Resources/*` | Bundled filter snapshots, AMO root, Paddle filters (not architecture-critical here). |

**Control bridge data path**

1. MCP client → `paddle-mcp` (stdio lines).
2. Helper connects to `~/Library/Application Support/Paddle/bridge/control.sock` (or temp fallback); checks socket uid.
3. `BridgeSocketServer` (private serial queue) accepts only peers passing `PeerRequirement` + `SecCodeCheckValidity` for `paddle-mcp` / team `VB3UP263YT`.
4. Each line → `Task { @MainActor in ControlBridge.received }` → `MCPServerCore.handle` → `ControlBridge+Tools.perform`.
5. Replies clamped by `BridgeLimits.clamped`.

**WebEnvironment sharing model**

- **One** `WKUserContentController` on `WebEnvironment` shared by all configurations: content blockers, `user.css`, userscripts, scriptlets, page-world bridge scripts.
- **Per-profile** persistent `WKWebsiteDataStore` (UUID-named); default profile uses `WKWebsiteDataStore.default()`.
- **One** shared non-persistent store for all private windows until `endPrivateSession()`.
- **Two** process pools: normal (`processPool`) vs private (`privateProcessPool`) so notification permission plumbing stays isolated (`WebsiteNotifications`).

---

## Findings

### FA-ARC-01 — Runtime MainActor checks disabled in app target
- **Severity:** S2  
- **Area:** architecture / concurrency  
- **Mechanism:** `project.yml` → Paddle target `OTHER_SWIFT_FLAGS: … -disable-dynamic-actor-isolation` (comment: crash in `swift_task_isCurrentExecutor` on macOS 27.0.1).  
- **Evidence:** Compile-time `SWIFT_STRICT_CONCURRENCY: complete` + `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` remain enabled; dynamic executor checks are off at runtime.  
- **User impact:** A future refactor that calls `AppModel` / `ControlBridge` / `Tab` off the main thread may compile yet corrupt UI or WebKit state without immediate runtime trap.  
- **Disposition:** Accepted tradeoff documented in project settings; monitor Apple/Swift fixes.  
- **Suggested fix shape:** Re-enable dynamic checks when OS/runtime fix lands; until then keep bridge/socket work on explicit `@MainActor` hops (already used in `ControlBridge.received`).  
- **Tree:** main  

### FA-ARC-02 — Global shared `WKUserContentController` across profiles and private mode
- **Severity:** S3  
- **Area:** architecture  
- **Mechanism:** `WebEnvironment.contentController` assigned to every `WKWebViewConfiguration` (`WebEnvironment.makeConfiguration`, line ~131).  
- **Evidence:** Block lists and injected scripts are process-wide for all tabs; only `websiteDataStore` and extension controller differ by profile/private flag.  
- **User impact:** Correct for adblocking/userscripts; profile-specific script injection cannot diverge at the WebKit controller level without architectural split.  
- **Disposition:** Inform intentional coupling; document for profile feature work.  
- **Suggested fix shape:** Only if product needs per-profile userscripts: secondary content controllers or profile-scoped rule list identifiers (larger WebKit compile/cache cost).  
- **Tree:** main  

### FA-ARC-03 — MCP `read_config` exposes full `config.json` including bridge/security keys
- **Severity:** S3  
- **Area:** architecture / MCP surface  
- **Mechanism:** `ControlBridge+Tools.readConfig()` reads entire file from disk (`Paths.config`) with no key filter.  
- **Evidence:** `settingsOnlyConfigKeys` blocks **writes** via `set_config`, not reads; file includes `controlBridge`, filter paths, extension policies, etc. README documents tool as full config text.  
- **User impact:** Any connected MCP client (after user enables bridge) learns sensitive **policy** flags and host/site configuration; not page cookies, but aids targeted abuse if machine is shared.  
- **Disposition:** By design; rely on bridge off by default + peer signing.  
- **Suggested fix shape:** Optional redacted `read_config` mode or split `read_config` / `read_config_public` if threat model tightens.  
- **Tree:** main  

### FA-ARC-04 — `run_js` guard is not a sandbox (documented)
- **Severity:** S3  
- **Area:** MCP / security architecture  
- **Mechanism:** `run_js` gated on `controlBridgeScripts` + per-site `BridgeConsent`; executes in isolated `WKContentWorld` with prelude guard script (`ControlBridge+Tools` ~466–545).  
- **Evidence:** Comments and MCP tool description state script reaches same capabilities as page scripts (password fields partially masked; cookies redacted in JSON output only).  
- **User impact:** User who enables Allow page scripts grants high-trust capability to MCP clients on consented origins.  
- **Disposition:** Accepted with consent UX; aligns with README.  
- **Suggested fix shape:** None required for architecture audit; keep consent + default off.  
- **Tree:** shipped (behavior intentional)  

### FA-ARC-05 — Private windows excluded from MCP via filter, not separate socket
- **Severity:** S4  
- **Area:** architecture  
- **Mechanism:** `visibleWindows` filters `!$0.model.isPrivate`; tab/window lookups never see private IDs. `menu_action` extra guard when app-level target and front window is private.  
- **Evidence:** `ControlBridge+Tools` lines 37–41, 383–386; `MCP.swift` tool descriptions.  
- **User impact:** Private browsing stays out of `paddle_state` and tab-targeted tools; user must not rely on MCP for private session automation (by design).  
- **Disposition:** OK.  
- **Suggested fix shape:** N/A.  
- **Tree:** shipped  

### FA-ARC-06 — Bridge allow-lists centralized in PaddleCore with contract tests
- **Severity:** S4 (positive)  
- **Area:** architecture  
- **Mechanism:** `PaddleBridgeTools.bridgeSettableConfigKeys`, `bridgeAllowedMenuActions`, `settingsOnlyConfigKeys`; enforced in app + described in README.  
- **Evidence:** `Tests/PaddleCoreTests/MCPTests.swift` asserts every `PaddleConfig.CodingKeys` appears exactly once in settable ∪ settings-only; menu actions cross-checked.  
- **User impact:** New config keys fail CI until classified, reducing accidental MCP write exposure.  
- **Disposition:** Keep pattern.  
- **Suggested fix shape:** N/A.  
- **Tree:** main  

### FA-ARC-07 — `PrivateAPI` wrapper used for WebKit introspection; local exceptions remain
- **Severity:** S3  
- **Area:** architecture / compatibility  
- **Mechanism:** Most sensitive reads go through `PrivateAPI` (`ProcessMemory`, `WebFeatureToggles`, `Tab` audio). Some sites use inline `responds` + `perform` (e.g. `WebEnvironment.configureProcessIdentity`, `WebInspector`, `TabWebDelegate.applySiteUserAgent`).  
- **Evidence:** `WebEnvironment` uses KVC `setValue(_:forKey: "processPool")` without `PrivateAPI.setValue` (deprecated API path). `WebInspector.show` calls `perform(showSelector)` after `inspector(of:)` already verified selector.  
- **User impact:** macOS/WebKit upgrades may drop selectors; degraded features (warm pool, inspector, site UA) rather than crash in guarded paths. Unguarded KVC on `processPool` could theoretically raise if key removed.  
- **Disposition:** Monitor WebKit betas.  
- **Suggested fix shape:** Route `processPool` assignment through existence check or `PrivateAPI.setValue` pattern.  
- **Tree:** main  

### FA-ARC-08 — Second Paddle instance race on Application Support
- **Severity:** S3  
- **Area:** process model / data integrity  
- **Mechanism:** `PaddleApp` running-copy handoff (`applicationWillFinishLaunching` / `applicationDidFinishLaunching`).  
- **Evidence:** Comment lines 20–23, 107–108 in `PaddleApp.swift`.  
- **User impact:** Debug + installed app simultaneously still risky if handoff fails; session/history corruption possible.  
- **Disposition:** Mitigated by early quit; user should run single copy.  
- **Suggested fix shape:** Optional file lock on support folder (heavier).  
- **Tree:** main  

### FA-ARC-09 — MCP memory figures from live `measureMemory()` during `paddle_state`
- **Severity:** S4  
- **Area:** architecture  
- **Mechanism:** `state()` calls `AppModel.measureMemory()` when cache stale (>1.5s), attributing WebContent PIDs via private APIs.  
- **Evidence:** `ControlBridge+Tools` ~98–107, `AppModel.measureMemory` ~1489–1543.  
- **User impact:** Bridge polling triggers periodic process walks (cost bounded by client count + rate); numbers are best-effort when snapshot API missing.  
- **Disposition:** OK for local automation.  
- **Suggested fix shape:** N/A unless profiling shows bridge-driven overhead.  
- **Tree:** main  

### FA-ARC-10 — `paddle-mcp` does not authenticate Paddle beyond socket ownership
- **Severity:** S4  
- **Area:** architecture  
- **Mechanism:** Helper validates socket inode uid; Paddle validates **client** signature on accept. No TLS or token on wire (local stream).  
- **Evidence:** `App/PaddleMCP/main.swift` lines 38–54; `BridgeSocketServer.checkPeer`.  
- **User impact:** Malware running as same user could only connect if it forged Apple-signed `paddle-mcp` binary (hard) or injected into helper; socket path mode 0600 limits other users.  
- **Disposition:** Reasonable for local MCP threat model.  
- **Suggested fix shape:** Optional peer credential or nonce handshake if paranoia increases (probably unnecessary).  
- **Tree:** main  

### FA-ARC-11 — Strict concurrency split: app MainActor vs helper nonisolated vs `BridgeSocketServer` queue
- **Severity:** S4  
- **Area:** architecture  
- **Mechanism:** Socket I/O on `BridgeSocketServer` queue; MCP parsing in `MCPServerCore` (Sendable); tool execution marshalled to MainActor. `BridgeToolError` is `nonisolated`. Log read uses `Task.detached` for OSLogStore.  
- **Evidence:** `ControlBridge.swift` 89–114; `BridgeSocketServer` marked `@unchecked Sendable`; `readLogs` nonisolated static.  
- **User impact:** Correctness depends on consistent MainActor hops for all UI/WebKit mutations (currently followed in bridge tools).  
- **Disposition:** OK pattern.  
- **Suggested fix shape:** Audit new bridge tools for MainActor confinement.  
- **Tree:** main  

---

## Leftovers (not findings)

- **Settings IA / extensions chrome / filter syntax:** delegated to other audit workers.  
- **Live process counts:** not measured this session (`ps` / footprint not run per worker constraints).  
- **Release signing / notarization / passkeys entitlement:** noted in AGENTS.md; not re-audited here.  
- **README ↔ `PaddleConfig` key sync:** spot-checked bridge paragraph vs `MCP.swift`; full README sync not in scope.  
- **WebKit beta behavior:** private API availability assumed per inline probe dates in source comments.

---

## Audit metadata

- **Method:** Static read of paths listed in worker brief @ `015dc73`.  
- **Product edits:** None.
