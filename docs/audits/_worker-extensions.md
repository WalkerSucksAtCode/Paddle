# Paddle extensions audit (read-only)

**Tree:** `main` @ `015dc73a2c04beeb7308c3e77e3148dc075f680b`  
**Scope:** WebExtensions load path (MV2/MV3), overlay/compat prelude, permission prompts, store updates (CRX3/AMO), personas, on-demand parking, `chrome.*` / README gaps.  
**Out of scope:** Settings pane IA density (wave 2), overlay RAM numbers (perf worker), implementing new shims.

**S0:** None identified in this pass (store packages go through signature + `ZipSafety`; permission prompts are not skipped for undeclared grants; native messaging does not launch arbitrary hosts).

---

## Load path (disk → WebKit)

```text
extensions/<folder>/          user folder (never patched in place)
        │
        ▼
ExtensionScan.scan            skip ._*; symlink escape checks; manifest at top or one subfolder
        │
        ▼
ExtensionHost.compatSetup       Persona.detect + ExtensionIdentity.resolve + CompatPlan.make
        │
        ▼
ExtensionOverlay.make           clone/copy → ~/Library/.../extension-overlays/<folder>/
        │                       manifest patch + paddle-prelude.js / paddle-content.js / paddle-sw.js
        ▼
WKWebExtension(resourceBaseURL: overlay or source if overlay fails / native / compat off)
        │
        ▼
ExtensionManifest preflight     missing background files block load; optional host/permission prompt
        │
        ▼
WKWebExtensionContext           grants from extension-permissions.json (+ bus grant for nativeMessaging)
        │
        ▼
WKWebExtensionController        per profile (private windows use default profile host when allowed)
```

**Shared vs per-profile:** Folders, overlays, salt, `extension-sources.json`, and store installs are shared (`ExtensionShared`, `Paths.extensionOverlays`). Each profile has its own `ExtensionHost`, permission answers file (`profiles/<id>/extension-permissions.json` for non-default), and WebKit extension storage under `~/Library/WebKit/com.walker.Paddle/WebExtensions/<profile id>/`.

**Salt gate:** Unreadable `extension-id-salt` stops all extension loads for the session (`ExtensionShared.swift` ~63–69, `ExtensionHost.loadEntries` ~759–761).

**MV2 vs MV3:** WebKit parses the manifest; Paddle classifies backgrounds via `ExtensionManifest.backgroundFiles` (service worker, then `scripts[]`, then `page`). Compat prelude treats MV2 explicitly (`CompatPrelude.swift`: `browserAction` alias, `tabs.executeScript` content-prelude injection, MV2 `chrome.extension` shims). MV3 service workers get `paddle-sw.js` wrapper when persona is `chrome` or `firefox` (`ExtensionCompat.patchManifest` ~166–169). Wave **4b** (`persona.none`) leaves `background.service_worker` **unpatched** (`ExtensionCompat.UnpatchedBackground`, `ExtensionOverlayTests`).

---

## Overlay / compat prelude

| Piece | Location | Role |
| --- | --- | --- |
| Wave 4b prelude | `ExtensionCompat.prelude` | Pins `chrome`/`browser`, stubs `runtime.onUpdateAvailable`, `requestIdleCallback` |
| Wave v2 prelude | `CompatPrelude.source` | Persona globals/UA, permission filtering (E23), enums, action/tabs/storage shims |
| Overlay clone | `ExtensionOverlay.make` | APFS `clonefile` or full copy; `recipeVersion` 8; stamp `.paddle-overlay.json` |
| Generated JS | Rewritten each load | Plan embeds manifest JSON, permissions, locale, `installReason` once |
| Fallback | `ExtensionHost` | Overlay failure → load original folder + problem line; v2 background failure → **compat off** session reload from source (`ExtensionHost` ~1187–1217) |
| Safari builds | `Persona.native` | No overlay (`ExtensionCompat.needsPrelude` false when only `browser_specific_settings.safari`) |

**Perf pointer:** Duplicate overlay storage (~100 MB cited in README/AGENTS.md for extensions + overlays) and on-demand unload savings are measured in `docs/measurements.md` — not re-derived here.

---

## Permission prompts

| Stage | Mechanism | File:line (anchor) |
| --- | --- | --- |
| First run / upgrade | `ExtensionDecisions.needsPrompt` → `ExtensionPrompts.install` | `ExtensionPermissions.swift` ~176–181; `ExtensionPrompts.swift` ~11–36 |
| Store update | `ExtensionPermissionDiff.asks` → `ExtensionPrompts.update` | `ExtensionPermissionDiff.swift` ~37–52; `ExtensionPrompts.swift` ~42–64 |
| Runtime `permissions.request` | Sheet or app-modal via `ExtensionPrompts.runtime` | `ExtensionPrompts.swift` ~67–81 |
| Identity binding | `ExtensionSnapshot.identity` + `permissionIdentity` | `ExtensionPermissions.swift` ~22–45; `ExtensionHost` ~826–828 |
| Never prompted | `nativeMessaging` in `ExtensionSnapshot.unrecorded` | `ExtensionPermissions.swift` ~102–104 |
| Blocking honesty | `ExtensionBlocking.notice` in install/update alerts | `ExtensionBlocking.swift` ~28–35 |
| Optional permissions | Not in install diff (`ExtensionPermissionDiff.required`) | `ExtensionPermissionDiff.swift` ~9–10 |

Answers persist in `extension-permissions.json` (0600). **Only When I Click** stores host patterns as `.click` so WebKit can still grant via `activeTab` on button click (`ExtensionSnapshot.apply` ~84–86).

---

## Updates (store)

| Source | Verify | Install |
| --- | --- | --- |
| Chrome Web Store | `CRX3.verify` + publisher key hash + developer id match | `ZipSafety.entries` → `StoreInstall.unpack` |
| AMO | Lookup hash/size + `AMO.verifySignature` (chain if `AMO.bundledRootCertificate()`) | Same unpack path |
| Policy | `extensionUpdates` default on; ~daily `ExtensionUpdatePolicy` | `ExtensionUpdater` hourly gate + manual Check All |
| Permission regression | New version staged in `.staged-<folder>/` until Allow | `ExtensionUpdater` ~9–12 |
| Hand folder | One-time adoption offer; `adoptedNotice` on first update | `ExtensionUpdater` ~35–37 |

Declined update versions recorded in `extension-sources.json` (`declinedVersion`) so the same build is not re-prompted.

---

## Personas

**Detection order** (`ExtensionPersona.swift` ~19–37): `extensionCompat.persona` override → install source (CWS → chrome, AMO → firefox, `.appex` → native) → Safari-only manifest → gecko id + non-SW-only background → firefox → else chrome.

**Runtime surface**

| Persona | Extension URL | Page `sitePersonas` | Prelude |
| --- | --- | --- | --- |
| `chrome` | `chrome-extension://<id>/` | Injects page-world Chrome identity (`SitePersonaScript`) | v2 + `browser` undefined on extension pages |
| `firefox` | `moz-extension://<uuid>/` | Same script path with Firefox UA/vendor | v2 + both globals pinned on full contexts |
| `native` | WebKit default | No script | No overlay |
| `none` | Private id, 4b prelude only | N/A | Wave 4b; SW often unpatched |

**Config:** `extensionCompat.<folder>`: `persona`, `shims` (default true), `publicID`, `private` (`ExtensionCompatConfig` ~170–205). `publicID` + verified store id used for sign-in extensions (`ExtensionHost.compatSetup` ~1031–1032).

---

## On-demand parking (`extensionsOnDemand`)

- **Default:** `true` in `PaddleConfig` (`PaddleConfig.swift` ~572).
- **Qualification:** `OnDemandExtension.sitePatterns` — site-specific content scripts + hosts, no `alwaysRunning` permissions/keys (`OnDemandExtension.swift` ~8–32).
- **Behavior:** Launch parks unvisited qualifiers (`ExtensionHost.loadEntries` ~844–848); tab open triggers `loadOnDemand` + page defer (`TabWebDelegate` comment ~158); idle unload after 5 min (`ExtensionHost.onDemandIdle` ~1277–1319).
- **Settings UI:** No toggle — **config.json / MCP `set_config` only** (`SettingsModel+Extensions.swift` has no `extensionsOnDemand`; `ExtensionsPane` updates section covers `extensionUpdates` only). Confirms parent “file-only” note.

---

## `chrome.*`: README vs implementation

| README / product claim | Implementation |
| --- | --- |
| Native messaging only `com.walker.paddle.compat` | `CompatBus` rejects other ids (`CompatBus.swift` ~54–56); prelude hides undeclared `nativeMessaging` from `permissions.getAll` |
| No history / bookmarks / downloads APIs | No adapters or prelude namespaces; extensions calling them get `undefined` / errors from WebKit |
| Personas: Firefox → `moz-extension://` | `ExtensionIdentity.resolve` + persona detection (see above) |
| `tabs.update({ muted })` / `tab.mutedInfo` | `ExtensionTab.setMuted` → `Tab.setMuted` (`ExtensionAdapters.swift` ~92–99) |
| Proton Pass gaps (logos, HTTP auth, clipboard, desktop unlock) | Documented in README; partial coverage via prelude/page scripts, not full Chrome API surface |
| Website passkeys | Apple entitlement pending (`README` ~231, `docs/passkeys.md`) — extension passkeys vs tab WebAuthn split |
| MV3 + MV2 WebKit still runs | Manifest-driven; blocking via DNR when rule files present; MV2 `webRequestBlocking` ineffective |

**Prelude-provided (non-exhaustive):** permission shims for WebKit-unknown **declared** names when listed in `shimmedPermissions` (see finding FA-EXT-05), enum constants (including `declarativeNetRequest.*` without inventing the namespace object), `storage.managed` read-only stub, `action.getUserSettings`, `runtime.requestUpdateCheck` → `no_update`, inert `onUpdateAvailable` / suspend events, MV2 `browserAction`/`pageAction`, content-script global pin (E11), Firefox xray/page-script CSP bypass sections.

**Swift extension bridge:** Tab/window/action/options/popup behavior via `ExtensionAdapters` + `ExtensionHosts` (WebKit delegate); not a full Chrome API reimplementation.

---

## Findings

### FA-EXT-01 — Wave 4b leaves MV3 service worker backgrounds without prelude
- **Severity:** S3  
- **Area:** compat / MV3  
- **Mechanism:** `ExtensionCompat.patchManifest` with `persona.none` records `unpatchedBackground: .serviceWorker` and does not inject `paddle-prelude.js` into the worker (`ExtensionCompat.swift` ~161–163, ~210+).  
- **Evidence:** `ExtensionOverlayTests` expect status `"background.service_worker left unpatched"` for MV3 manifest under 4b overlay.  
- **User impact:** Extensions forced to `persona.none` or failing v2 and falling back to 4b can hit Proton-class bugs (`onUpdateAvailable` throw, proxy-swapped globals) in the **service worker only**.  
- **Disposition:** Use `extensionCompat.persona` chrome/firefox for affected extensions; avoid `none` unless Safari-native.  
- **Suggested fix shape:** Extend 4b to wrap SW like v2, or auto-promote to chrome persona when `background.service_worker` present.  
- **Tree:** main  

### FA-EXT-02 — `webRequestBlocking` does not block (WebKit limitation)
- **Severity:** S4  
- **Area:** MV2 adblock / network  
- **Mechanism:** `ExtensionBlocking` classifies manifests with `webRequestBlocking` and no DNR rule files as `.webRequestBlockingOnly`; install alert includes notice (`ExtensionBlocking.swift` ~16–35).  
- **Evidence:** README ~193; uBlock Origin MV2 calld out.  
- **User impact:** MV2 blockers relying on blocking listeners still load pages; Paddle filter lists still apply.  
- **Disposition:** Documented; user expectation management.  
- **Suggested fix shape:** None in Paddle; extensions must migrate to DNR where possible.  
- **Tree:** main  

### FA-EXT-03 — `extensionsOnDemand` has no Settings control
- **Severity:** S4 (config gap)  
- **Area:** on-demand parking  
- **Mechanism:** Key exists on `PaddleConfig` and triggers `ExtensionHost.reconcile` on change (`AppModel.swift` ~557); no API in `SettingsModel+Extensions` / `ExtensionsPane`.  
- **Evidence:** README table ~155; grep shows no Settings binding.  
- **User impact:** Users must edit `config.json` or MCP to disable on-demand unloading.  
- **Disposition:** Accepted risk / alias for Settings worker wave 2.  
- **Suggested fix shape:** Toggle + help text mirroring README measurements link.  
- **Tree:** main  

### FA-EXT-04 — No `chrome.history`, `chrome.bookmarks`, or `chrome.downloads`
- **Severity:** S4  
- **Area:** missing chrome.*  
- **Mechanism:** No prelude namespaces or `ExtensionAdapters` hooks; README states absence (~195).  
- **Evidence:** `CompatPreludeTests` ~270 `typeof chrome.declarativeNetRequest` undefined when WebKit lacks API — same pattern for unimplemented surfaces.  
- **User impact:** Extensions depending on those modules fail or degrade; password/history helpers must use other flows.  
- **Disposition:** By design.  
- **Suggested fix shape:** N/A unless product scope expands.  
- **Tree:** main  

### FA-EXT-05 — `shimmedPermissions` never populated at load time
- **Severity:** S3  
- **Area:** permissions / prelude  
- **Mechanism:** `CompatPlan.make` defaults `shimmedPermissions: []` (`CompatPrelude.swift` ~74–89); `ExtensionHost.compatSetup` calls `make` without passing shims for WebKit-unknown manifest names (`ExtensionHost.swift` ~1040–1043). Prelude only shims names in `P.shimmed` intersect required (`CompatPrelude.swift` ~608–609).  
- **Evidence:** `ExtensionCompat.webKitPermissionNames` omits e.g. `notifications`, `favicon`; tests pass shim list manually (`CompatPreludeTests` ~241).  
- **User impact:** Extensions requiring dropped permissions may see `permissions.contains` false (E23) despite user clicking Allow on manifest-declared names.  
- **Disposition:** Open gap for extensions using non-WebKit permission names.  
- **Suggested fix shape:** Compute shim list from manifest unsupported ∪ known shim set at `CompatPlan.make`.  
- **Tree:** main  

### FA-EXT-06 — Native messaging confined to compat bus (positive)
- **Severity:** S4 (positive)  
- **Area:** security  
- **Mechanism:** Only `ExtensionCompat.busID` handled; others get Chrome-compatible “host not found” (`CompatBus.swift` ~6–8, ~54–56). Context grant without persisting in permissions file (`ExtensionHost` ~907–914).  
- **User impact:** Extensions cannot spawn arbitrary native messaging hosts.  
- **Disposition:** Matches README.  
- **Suggested fix shape:** N/A.  
- **Tree:** main  

### FA-EXT-07 — Store ZIP path resists zip-slip (positive)
- **Severity:** S4 (positive)  
- **Area:** security  
- **Mechanism:** `ZipSafety.entries` rejects `..`, symlinks, overlap bombs; `StoreInstall.unpack` verifies tree matches entries (`ZipSafety.swift` ~261–271; `StoreInstall.swift` ~60–80).  
- **User impact:** Malicious store packages (if signature bypassed) still constrained on unpack.  
- **Disposition:** Keep central `ZipSafety` for any new archive ingress.  
- **Suggested fix shape:** N/A.  
- **Tree:** main  

### FA-EXT-08 — AMO chain verification depends on bundled Mozilla root
- **Severity:** S3  
- **Area:** security / updates  
- **Mechanism:** `StoreInstaller.fetchAddon` passes `AMO.bundledRootCertificate()` into `verifySignature` (`StoreInstaller.swift` ~433); without anchor, trust is `.unverifiedChain` (`AMO.swift` ~106–109). Update alert adds `unverifiedNotice` (`ExtensionUpdater.swift` ~32–33).  
- **Evidence:** `project.yml` ~41 references bundled PEM.  
- **User impact:** If resource missing/corrupt, AMO installs still hash+CMS-check but user sees certificate caveat on updates.  
- **Disposition:** Shipped with bundled root in repo; monitor packaging.  
- **Suggested fix shape:** Fail closed on install when chain unverified (stricter than today).  
- **Tree:** main  

### FA-EXT-09 — Hand-installed add-on updates replace unverified folder contents
- **Severity:** S3  
- **Area:** updates / trust  
- **Mechanism:** Adoption path treats folder as updatable; first update alert includes `adoptedNotice` (`ExtensionUpdater.swift` ~35–37).  
- **User impact:** User who opts into updates on a sideloaded copy trusts AMO/CWS signature thereafter, not local tamper evidence.  
- **Disposition:** Disclosed in UI.  
- **Suggested fix shape:** Optional “verify local hash before update” for paranoid mode.  
- **Tree:** main  

### FA-EXT-10 — Permission answers bound to extension identity (positive)
- **Severity:** S4 (positive)  
- **Area:** security  
- **Mechanism:** `ExtensionSnapshot.applies(name:identity:)`; new gecko/key in reused folder re-prompts (`ExtensionPermissions.swift` ~39–45, ~176–181).  
- **User impact:** Renamed/malicious swap into same folder name does not inherit Allow.  
- **Disposition:** Keep identity fill on adopt for legacy records.  
- **Suggested fix shape:** N/A.  
- **Tree:** main  

### FA-EXT-11 — v2 prelude session fallback disables compat entirely
- **Severity:** S3  
- **Area:** reliability / compat  
- **Mechanism:** Background load failure after v2 → `compatOff.insert(name)` and reload from pristine folder (`ExtensionHost.swift` ~1187–1217).  
- **User impact:** Extension may run without shims/persona fixes (intermittent site breakage) rather than staying broken.  
- **Disposition:** Pragmatic fallback; status line notes “compat off”.  
- **Suggested fix shape:** Surface banner when fallback active; offer retry v2.  
- **Tree:** main  

### FA-EXT-12 — `extensionCompat.shims: false` strips API stand-ins
- **Severity:** S4  
- **Area:** compat config  
- **Mechanism:** `CompatPlan.shims` from `ExtensionCompatConfig.shimsEnabled` (`CompatPrelude.swift` ~35–36, ~604+ sections gated on `P.shims`).  
- **User impact:** Persona UA/URL remain; permission/enums/action shims skipped — breaks extensions that relied on prelude answers.  
- **Disposition:** Advanced knob; default on.  
- **Suggested fix shape:** Document in README `extensionCompat` section.  
- **Tree:** main  

### FA-EXT-13 — DeclarativeNetRequest enum stubs without namespace object
- **Severity:** S4  
- **Area:** missing chrome.*  
- **Mechanism:** `ENUMS.declarativeNetRequest` fills constants on existing WebKit object only (`CompatPrelude.swift` ~378–388, ~400–407); tests assert namespace not invented (`CompatPreludeTests` ~270).  
- **User impact:** Extensions probing `chrome.declarativeNetRequest` before WebKit creates it may still fail; DNR-capable extensions with WebKit support OK.  
- **Disposition:** Intentional (E23-style).  
- **Suggested fix shape:** Lazy empty namespace object if product wants broader compat.  
- **Tree:** main  

### FA-EXT-14 — Website tab passkeys blocked without Apple entitlement
- **Severity:** S4  
- **Area:** passkeys / extensions  
- **Mechanism:** README ~195, ~231; entitlement commented in Release builds (`docs/passkeys.md`).  
- **User impact:** Proton Pass **extension** passkeys OK per README; site WebAuthn in tabs not until Apple approves request `84Z8XFC523`.  
- **Disposition:** External dependency tracked.  
- **Suggested fix shape:** Enable entitlement post-approval; re-notarize.  
- **Tree:** main  

---

## Cross-references (already green from parent)

- README native messaging, history/bookmarks/downloads, persona URLs, Proton Pass caveats, passkeys split — **confirmed** in code paths above.  
- `extensionsOnDemand` file-only — **confirmed** (FA-EXT-03).  
- Overlay disk cost — **pointer only** to `docs/measurements.md` / perf worker.
