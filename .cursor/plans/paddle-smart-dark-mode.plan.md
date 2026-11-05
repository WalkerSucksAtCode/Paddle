# Paddle smart dark mode

Status: W1–W3 audited, Debug build green. Worktree `/Users/Walker/Code/Projects/Paddle-wt/smart-dark-mode` on `cursor/smart-dark-mode-c272` from `origin/main` (`015dc73`). Settings aesthetic PR `cursor/settings-ui-audit-a3f0` is a sibling worktree — do not merge or restyle it. Extend the existing Sites "Dark mode" column; do not add a second control.

Workers never edit this file. Parent audits `git diff` + Done look before any `- [x]`.

## Goal

Automatic page dark mode that Just Works on ~all sites (native-dark untouched, light sites darkened cleanly, maps/canvas/editors/media protected), with first-class per-site Auto / Light / Dark / Native overrides. Paddle’s inject stands alone; Dark Reader stays Off and is not a dual engine.

Walker live: `appearance=dark`, `darkMode=always` (must load as Smart), `invertTextImages` off, zero per-site overrides.

## Research (smallest WKWebView approach)

Do **not** vendor Dark Reader. Keep one stylesheet + html attribute toggles.

| Source | Takeaway for Paddle |
|---|---|
| Current inject | `color-scheme: dark` + `filter: invert(90%) hue-rotate(180deg)` on `html[data-paddle-dark-mode=active]`; reverse on img/video/canvas/picture/iframe/`[role=img]`/`[style*=background-image]`; nested reverse `filter: none`; native-dark skip via luminance / `data-theme` / `.dark` / `theme-color`; 400ms SPA retry; live `__paddleDarkMode`. |
| Dark Reader **filter** | Same invert+hue-rotate family. Dynamic color-rewrite is too heavy for a document-start user script. Reverse media with CSS, not per-element JS. Maps/editors/PDF need extra reverse selectors. Google Docs: `#docs-editor canvas` must not invert. |
| Chromium Auto Dark | Sites with `color-scheme: dark` (or meta) are native — we should detect that. Per-element `color-scheme: only light` opts out of *Chrome’s* engine, not our CSS filter; for filter mode we reverse with `filter: invert(100%) hue-rotate(180deg)` on the fragile subtree (same as media). |
| Safari Reader | Article extraction; irrelevant to full-page theming. |
| Perf | One `html` filter is GPU-composited. Per-element invert storms wreck scroll. MutationObserver must be attribute-filtered on html/body/known roots, debounced (~100ms), not subtree class spam. |

Softer invert curve (`contrast`/`brightness` tokens): **optional, evidence-gated**. Default stays `invert(90%) hue-rotate(180deg)` unless a before/after shot shows a real wash/sepia win without contrast loss.

## Product shape

### Global `darkMode` (`config.json`)

| Value | Behavior |
|---|---|
| `off` | Never invert; do not force `color-scheme`. |
| `system` | If chrome/appearance is dark → Smart path; if light → Off. |
| `smart` | Prefer native dark when detected; else invert + exclusions; re-eval SPAs. |
| `native` | `color-scheme` / `prefers-color-scheme` only. **Never invert.** |
| `always` (legacy read) | Decode as `smart`. Encode writes `smart`. Not shown in Settings. |

Default for a new config stays `off` (no surprise invert). Smart is the Settings recommendation. Walker’s `always` migrates on decode.

### Per-site `sites.<host>.darkMode`

Stored as a string. Missing / `"auto"` = Auto (no key). Legacy bool: `true` → `dark`, `false` → `light`.

| Override | Engine |
|---|---|
| `auto` | Follow global. |
| `light` | Never darken, never invert (escape hatch). |
| `dark` | Force Smart invert path if not naturally dark; under global Native, force color-scheme dark (still no invert). |
| `native` | This host only: color-scheme / prefers-color-scheme, no invert. |

**Write rule:** Auto always removes the key. Light/Dark/Native always write the string. Do **not** prune Dark just because global Smart currently resolves the same — Auto vs Dark must stay distinct.

### Page chrome

- View menu: **Dark Mode** becomes a submenu: Auto / Light / Dark / Native for the current host, plus **Looks Wrong → Keep Light** (`keepPageLight`). ⇧⌘D (`toggleDarkMode`) stays: if the page is in a dark engine, write Light; else write Dark (same on/off feel as today). Private windows stay tab-local (override, no `config.json`).
- Mosaic pane context menu: map Follow Site / On / Off onto Auto / Dark / Light. Native stays in the View submenu.
- Toolbar menu already copies `toggleDarkMode`; Keep Light appears via the View submenu copy if present.

`invertTextImages` only runs on the Smart invert path (global Smart/System-dark or per-site Dark), never Native / Off / Light.

## Engine (DarkModeScript)

Baked at document-start in `.defaultClient`. Iframes still follow the **tab host** (ancestorOrigins), not the iframe host.

### Policy API (live, no restart)

```
window.__paddleDarkMode.setPolicy({ engine: 'off'|'smart'|'native', invertTextImages: bool })
window.__paddleDarkMode.setDarkMode(on)  // compat: true→smart, false→off
window.__paddleDarkMode.setKeepLight()   // engine off (Swift also writes Light)
```

Host table: `Map<host, 'light'|'dark'|'native'>`. JS resolves like Swift so embeds match.

Swift `Tab.applySiteDarkMode` must call `setPolicy`, not only `setDarkMode(bool)`.

### Native-dark detector (Smart)

Keep current luminance probe (html, body, `main/#root/#app/#__next/ytd-app/[role=main]`, threshold 0.45) **without** Paddle’s invert attribute.

Add, cheap and ordered:

1. Computed `color-scheme` on html/body includes `dark`.
2. `meta[name=color-scheme]` / `meta[name=theme-color]` (existing) luminance.
3. Attributes (html, then body): `data-theme`, `data-color-mode`, `data-bs-theme`, `data-mdb-theme`, `theme`, `color-scheme` — value contains `dark` (not `light`). GitHub: `data-color-mode=dark` or `auto` + `data-dark-theme` active. YouTube: `html[dark]`, `ytd-app[dark]`.
4. Class tokens: `dark`, `dark-mode`, `darkMode`, `theme-dark`, `night-mode`, `is-dark`, `docs-darkmode-on`.
5. Open shadow roots of the first ~8 custom-element hosts under body (catch late SPA roots); skip closed shadows.

False-positive guard: a single 1×1 dark overlay does not count; luminance only on html/body/named roots.

### Re-eval (no CPU thrash)

Keep DOMContentLoaded + 400ms. Add:

- One extra timeout ~1600ms for late hydration.
- Theme `MutationObserver` on `document.documentElement` and `document.body` only: `attributes` + `attributeFilter` for `class`, `style`, `data-theme`, `data-color-mode`, `data-bs-theme`, `dark`, `theme`. Debounce 100ms. Do **not** observe subtree class mutations.
- ChildList on `head` for `meta[name=theme-color|color-scheme]` only if cheap (or re-check those metas inside the debounce).
- Existing invertTextImages observer stays separate and still only runs when invertTextImages is on.

If a site flips to native dark after invert was applied, drop `data-paddle-dark-mode` (avoid double-dark). If it flips back to light while engine is smart, restore invert.

### Exclusions (CSS on `html[data-paddle-dark-mode=active]`, reverse invert)

Same trick as media: `filter: invert(100%) hue-rotate(180deg) !important` on the fragile root; nested media already `filter: none`.

Selectors (keep tight; no `[id*=map]`):

- Maps: `.gm-style`, `.mapboxgl-map`, `.mapboxgl-canvas`, `.leaflet-container`, `.leaflet-pane`, `[class*="apple-map"]`
- Editors: `.monaco-editor`, `.cm-editor`, `.CodeMirror`, `.ace_editor`
- Docs/PDF: `#docs-editor`, `#docs-editor canvas`, `.pdfViewer`, `.canvasWrapper`
- Other: `embed`, `object`, `[style*="mix-blend-mode"]`
- Nested reverse already covers img-in-img; extend that `:is(...)` list to the new reverse roots so a map marker img is not inverted twice.

No per-element JS invert. No new user-script worlds.

### Native engine

Inject `color-scheme: dark` on `:root` only. Never set `data-paddle-dark-mode=active`. WK `_setColorSchemePreference` = 2 (dark) when engine is smart or native; 0 when off. `responds(to:)` stays.

### Off / Light

Remove invert stylesheet and `data-paddle-dark-mode`. Do not force `color-scheme: dark`. Preference 0.

## Types (PaddleCore)

```swift
public enum DarkModePreference: String, Sendable, CaseIterable {
    case off, system, smart, native
    // Codable: decode "always" → .smart; encode .smart as "smart"
}

public enum SiteDarkMode: String, Sendable, CaseIterable {
    case auto, light, dark, native
    // Codable: true→dark, false→light, "auto"→nil at SiteSettings layer
}

public enum PageDarkEngine: String, Sendable {
    case off, smart, native
}
```

`SiteSettings.darkMode: SiteDarkMode?` (nil = Auto). `isEmpty` unchanged (nil).

`SitePolicy`:

- `darkModeOverride: SiteDarkMode` (merged; `.auto` if unset)
- `pageDarkEngine: PageDarkEngine` (resolved vs global + `systemIsDark`)
- Keep `darkMode: Bool` as `pageDarkEngine != .off` so WK backdrop / color-scheme call sites stay obvious.

Resolution (Swift and JS, same table):

```
site light → off
site native → native
site dark → global native ? native : smart
site auto:
  global off → off
  global native → native
  global smart → smart
  global system → appearance/system dark ? smart : off
  global always (decoded smart) → smart
```

`PaddleConfig.defaultDarkMode(systemIsDark:)` becomes `pageDarkEngine(systemIsDark:)` (Bool helper OK if `!= .off`).

`SiteSettings.defaultValue(.darkMode)` = `.string("auto")`. `ConfigFile.siteFieldDefaults` matches.

`DarkModeScript.source(for:sites, defaultEngine:invertTextImages:)`.

## UI

- `AppearancePane`: picker Off / System / Smart / Native. Help: Smart is the recommendation; Native never inverts; per-site still wins. Four segments is OK.
- `SitesPane`: replace Dark mode checkbox with a compact menu Picker Auto / Light / Dark / Native (labels-hidden, accessibility label includes host). Widen column (~88). Do not invent a second column. Do not restyle the rest of Sites (leave Settings PR’s More… sheet alone — it is not on this branch).
- `SettingsModel+Sites.setSiteField`: Auto → nil key; other modes → `.string`. Accept `.string` (and still accept legacy `.bool` if a test writes it). Inherited prune must **not** collapse Dark to Auto.
- Mosaic pane picker: Follow site / Dark / Light.

## Tests

`Tests/PaddleCoreTests/SitePolicyTests.swift` (extend) + script assertions:

- Decode `"always"` → `.smart`; encode writes `"smart"`.
- Site bool `true`/`false` → dark/light; strings auto/light/dark/native.
- Resolution matrix (global × site × systemIsDark).
- `entry(..., to: .string("auto"))` removes the key; `"light"` writes.
- Script contains `__paddleDarkMode.setPolicy`, exclusion selectors (`.gm-style`, `.monaco-editor`, `#docs-editor`), `color-scheme` detection, debounce observer (not subtree class).
- Existing WebKit execute + invertTextImages toggle tests still pass with the new `source` signature.

## App files after core

- `WebEnvironment.swift` — pass `defaultEngine`
- `Tab.swift` — `setPolicy` JS; Keep Light; toggle writes Light/Dark strings
- `TabWebDelegate.swift` — preference from `pageDarkEngine`
- `AppModel.swift` — existing `.darkMode`/`.sites` → `applySiteDarkMode` (must still hit open tabs)
- `BrowserModel.swift` / `MultiPanes.swift` / `MainMenu.swift` / `BrowserWindowController.swift` / `ToolbarMenu.swift`
- `README.md` — `darkMode` values + per-site strings + `keepPageLight` in the shortcut list
- `MCP.swift` action names if `keepPageLight` is added to MainMenu

## Evidence (parent, Debug app only)

Folder: `docs/evidence/smart-dark-mode-2026-11-05/`

Shots from Debug Paddle (`build/DerivedData.noindex/.../Paddle.app`) or paddle MCP. Do **not** replace `/Applications/Paddle.app`. Do not notarize.

Minimum:

1. Native-dark site (x.com or github.com with the site already dark) — **not** inverted (chrome/text not hue-shifted).
2. Light article site — darkened, readable.
3. Map or canvas-heavy page (Google Maps or similar) — tiles/canvas not obviously wrecked vs the same page with Dark Mode Off.
4. One previously-wrong class if found during live pass; else say none found.

Also: change a per-site override on an open tab and confirm it applies without restart (`setPolicy`).

## Out of scope

- Dual-engine with Dark Reader; vendoring Dark Reader; requiring the extension.
- Changing Walker’s installed notarized app; `scripts/release.sh`; merge; App Store.
- Settings aesthetic restyle (PR #2 / `cursor/settings-ui-audit-a3f0`).
- New invert curve without before/after evidence.
- Per-element invert JS; subtree MutationObserver on all classes.
- Defaulting new configs to Smart (stay `off`).

## Workstreams

| ID | Worker | Model | Paths (allowlist) | Depends |
|---|---|---|---|---|
| W1 | core types + script API + tests | Composer 2.5 | `Sources/PaddleCore/{PaddleConfig,SiteSettings,SitePolicy,DarkModeScript,ConfigFile,BrowserSiteSettingsReader}.swift`, `Tests/PaddleCoreTests/{SitePolicyTests,SiteSettingsTests}.swift` | — |
| W2 | detector + exclusions + re-eval | Grok 4.6 (visual/engine judgment) | `Sources/PaddleCore/DarkModeScript.swift`, tests that assert script text | W1 |
| W3 | App wiring + Settings + menus + README | Composer 2.5 | `App/Paddle/**` listed above, `README.md`, `Sources/PaddleCore/MCP.swift` if action names | W1 |
| W4 | Debug build + live evidence + PR | parent + Composer 2.5 for build/shots if needed | `docs/evidence/smart-dark-mode-2026-11-05/`, no product code unless a hole | W2+W3 |

After W1, W2 and W3 are path-disjoint (script vs App) and may run in parallel.

## Acceptance

1. Settings Appearance: Off / System / Smart / Native. Stored `always` loads as Smart.
2. Sites + page menu: Auto / Light / Dark / Native; Keep Light writes Light and applies immediately.
3. Smart auto: native-dark not inverted; light sites darkened; maps/canvas/media not obviously broken vs Off.
4. Per-site override applies to open tabs for that host without restart.
5. Draft PR with this plan path, evidence folder, honest leftovers (hosts that still need a human Native/Light exception).

## Todos

- [x] W1 PaddleCore types, policy resolution, DarkModeScript API (`setPolicy`, host table strings, native/off/smart engines), unit tests
- [x] W2 Smart detector, CSS exclusions, SPA re-eval (debounce, no invert storms)
- [x] W3 App wiring, Settings pickers, View submenu + Keep Light, README
- [x] W4 Debug `xcodebuild` + `swift test`; live evidence shots; draft PR

## Live / git

- Worktree only: `/Users/Walker/Code/Projects/Paddle-wt/smart-dark-mode`. Do not checkout this branch in the main Paddle clone.
- Do not quit `/Applications/Paddle.app`. Do not `scripts/release.sh`.
- Parent owns paddle MCP live checks. Workers: headless unless the prompt names namespace `paddle`.
- No HANDOFF/STATUS markdown. No notarize, no merge.
