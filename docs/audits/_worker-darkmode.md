# Dark mode / appearance audit (read-only)

**Trees compared:** `main` @ `015dc73` vs PR #3 branch `cursor/smart-dark-mode-c272` @ `aa33b81` (worktree `Paddle-wt/smart-dark-mode`, **not shipped**).  
**Scope:** `config.json` chrome `appearance` vs page `darkMode`, `DarkModeScript` injection and engines, per-site policy, Settings UI, ⇧⌘D / `mosaicDarkMode`, and PR evidence stills. No live app run in this pass.

**S0:** **None.** No finding where page dark mode silently exfiltrates data or bypasses user intent; remaining items are product behavior, config migration, or accepted script cost.

---

## Chrome appearance vs page dark mode

| Layer | Config key | UI | Runtime (both trees unless noted) |
|---|---|---|---|
| **Chrome** (windows, tab strip, toolbar, `prefers-color-scheme` on pages via WebKit) | `appearance`: `system` \| `light` \| `dark` | Settings → Appearance → **Appearance** segmented control | `AppModel.applyAppearance` sets `NSApp.appearance` (`App/Paddle/AppModel.swift` ~211–218); `effectiveAppearanceIsDark` reads `NSApp.effectiveAppearance` (~207–208). Help text: *“pages follow the window.”* (`AppearancePane.swift` ~44). |
| **Page dark** (invert / `color-scheme` script in `.defaultClient`) | `darkMode` global + optional `sites.<host>.darkMode` | Settings → Appearance → **Website dark mode** | `WebEnvironment.reloadUserScripts` always adds `DarkModeScript` at document start (`WebEnvironment.swift` ~495–503 main; ~497–507 PR #3). Live updates via `Tab.applySiteDarkMode` / `applyPageDarkEngine`. |

These are **orthogonal**: light chrome with page dark on, or dark chrome with page dark off, is valid on both trees.

---

## Global `darkMode` modes

| Mode | `main` @ `015dc73` | PR #3 @ `aa33b81` |
|---|---|---|
| Off | `DarkModePreference.off` | same |
| Follow chrome / system | `.system` → `defaultDarkMode(systemIsDark:)` uses `appearance` + macOS when `appearance` is `.system` (`PaddleConfig.swift` ~941–951 main) | `.system` → `PageDarkEngine.resolved` yields `.smart` when effective appearance is dark, else `.off` (`SitePolicy.swift` ~17–23 PR) |
| Force dark on sites | `.always` → `defaultDarkMode` always `true` | **Removed**; decode maps legacy `"always"` → `.smart` (`PaddleConfig.swift` ~163–165 PR) |
| Smart invert | *(no separate enum)* — invert path when `defaultDarkMode` is true | `.smart` → engine `.smart` |
| Native `color-scheme` only | *(none)* | `.native` → engine `.native` (no `html` invert filter) |

README: main documents `off` / `system` / `always` (`README.md` ~136); PR documents `off` / `system` / `smart` / `native` plus `always` migration (`smart-dark-mode/README.md` ~136).

Settings picker: main Off / System / **Always** (`AppearancePane.swift` ~93–96); PR Off / System / **Smart** / **Native** (`smart-dark-mode/.../AppearancePane.swift` ~93–97).

---

## `DarkModeScript` engines

### `main` — single boolean pipeline

- Swift API: `DarkModeScript.source(for:defaultDarkMode:invertTextImages:)` (`Sources/PaddleCore/DarkModeScript.swift` ~10).
- JS: `defaultDark` bool + per-host `Map` of bools from `hostTable` (~404–411).
- `shouldBeDark()` → site table walk + `defaultDark` (~36–46).
- Active invert: `html[data-paddle-dark-mode="active"]` + global `filter: invert(90%)…` (~59–74).
- **Already-dark skip:** `isNaturallyDark()` / `measureNaturallyDark()` (~121–155, ~174–178) avoids setting `data-paddle-dark-mode="active"` when background luminance, `data-theme`, `.dark` class, or dark `theme-color` match.
- Boot: if `shouldBeDark()`, `ensureStyles()` runs at document start **before** DOM ready (~342–344), so `:root { color-scheme: dark }` is injected early even when later passes skip invert.
- Live API: `window.__paddleDarkMode.setDarkMode(on)` bool override (~358–361).

### PR #3 — `PageDarkEngine` (`off` \| `smart` \| `native`)

- Swift API: `source(for:defaultEngine:globalDarkMode:invertTextImages:)` (`smart-dark-mode/.../DarkModeScript.swift` ~8–13).
- Site table maps host → `"light"` \| `"dark"` \| `"native"` (~591–606); `tokenToEngine` respects global `.native` for site `"dark"` (~50–55).
- **Smart:** same invert CSS as main, plus extra “un-invert” selectors for maps, Monaco/CodeMirror, PDF.js, etc. (~92–112).
- **Native:** separate stylesheet id `paddle-dark-mode-native` — only `:root { color-scheme: dark }` (~118–127, ~317–320).
- **Richer** `measureNaturallyDark`: `meta color-scheme`, more theme attrs, `color-scheme` on computed style (with temporary removal during probe via `withSiteColorScheme`), shadow-root sampling (~187–296).
- Observers: theme `MutationObserver` + extra `evaluateAndApply` at 1600 ms (~492–531).
- Live API: `setPolicy({ engine, invertTextImages })`, `setKeepLight()` (~533–549).

### `always` / already-dark sites (main motivation vs current main)

On **`main` @ `015dc73`**, global `.always` does **not** unconditionally attach invert: `evaluateAndApply` skips `data-paddle-dark-mode="active"` when `isNaturallyDark()` is true (`DarkModeScript.swift` ~174–178). Sites the **narrow** detector misses can still be inverted while `.always` is on — e.g. canvas-heavy UIs without dark background on `html`/`body`/main.

PR #3 targets false negatives with the expanded detector and optional **Native** global mode; smart mode can still mark some canvases active per PR probes (see evidence below).

---

## Per-site policy

| | `main` | PR #3 |
|---|---|---|
| `sites.<host>.darkMode` type | `Bool?` (`SiteSettings.swift` ~44) | `SiteDarkMode?`: `auto`, `light`, `dark`, `native` (~25–28); legacy bool decodes to `.dark`/`.light` (~112–114) |
| Effective policy | `SitePolicy.darkMode: Bool` = `settings.darkMode ?? defaultDarkMode(...)` (`SitePolicy.swift` ~37 main) | `pageDarkEngine: PageDarkEngine` via `PageDarkEngine.resolved` (~72–76 PR) |
| Settings > Sites | Inherited bool dark on/off | Auto / Light / Dark / Native (PR UI; not re-audited line-by-line here) |

Per-site **wins** over global on both trees (Appearance help, main ~97; PR ~99).

---

## Injection and tab bridge

| Step | `main` | PR #3 |
|---|---|---|
| Build script | `defaultDarkMode: config.defaultDarkMode(systemIsDark:)` | `defaultEngine: config.pageDarkEngine(...)`, `globalDarkMode: config.darkMode` |
| Tab apply | `setDarkMode(true/false)` from resolved bool (`Tab.swift` ~1016–1022) | `setPolicy({ engine: '…' })` (`Tab.swift` ~1032–1041) |
| ⇧⌘D site toggle | Flip saved bool (`toggleDarkMode` ~1035–1052) | Off → site `.dark`, else → `.light` (~1054–1069); View submenu adds Auto/Light/Dark/Native + **Keep Light** (`MainMenu.swift` ~103–112 PR) |

Scripts reload when config keys change **or** when `effectiveAppearanceIsDark` changes (`WebEnvironment.apply` ~343–344), so system appearance flips re-bake the embedded `defaultDark` / `defaultEngine`.

---

## Mosaic ⇧⌘D (`mosaicDarkMode`)

Unchanged between trees at config level: `site` (default), `unified`, `perPane` (`README.md` ~123 both; `MosaicPane.swift` picker ~237–245).

- **Shortcut:** View → Dark Mode ⇧⌘D (`MainMenu.swift` ~103 main; PR adds submenu under same item).
- **Behavior:** `BrowserModel.toggleDarkMode(_:)` — if not in Mosaic or mode is `.site`, delegates to `tab.toggleDarkMode()`; else applies to all panes or focused pane only (`BrowserModel.swift` ~523–532, same structure on PR).
- **Pane override:** `Tab.darkModeOverride` still wins for unified/per-pane toolbar menu (`Tab.swift` ~996–1007 both).

PR changes **what** gets saved when toggling (light/dark enum vs bool) but not mosaic routing.

---

## PR #3 evidence (headless cites)

Path: `Paddle-wt/smart-dark-mode/docs/evidence/smart-dark-mode-2026-11-05/`

| Asset | Note |
|---|---|
| `probes.txt` | `native-dark`: no `data-paddle-dark-mode`, invert false; `light-article`: active + invert; **`map-canvas` / `code-editor`: active + invert true** (smart path still engages). |
| `native-dark.png`, `light-article.png`, `map-canvas.png`, `code-editor.png` | Visual corroboration for probes (not copied into audit worktree). |

---

## Cross-audit

- **FA-PERF-07** (`_worker-perf.md`): `DarkModeScript` (+ scroll restore) on every document context — **Accepted risk** on `main`; PR #3 **increases** script size and adds observers (see FA-DRK-07).

---

## Findings

### FA-DRK-01 — Global `always` renamed and split into `smart` + `native`
- **Severity:** S4  
- **Area:** Config / docs  
- **Mechanism:** `DarkModePreference`: main `case off, system, always` (`PaddleConfig.swift` ~157–158); PR `case off, system, smart, native` with `"always"` → `.smart` decode (~157–165 PR).  
- **User impact:** Existing configs with `"always"` behave as smart invert on PR, not a distinct “force invert even on native dark” mode.  
- **Disposition:** Fixed-on-PR  
- **Tree:** main \| PR #3  

### FA-DRK-02 — No global native-only page mode on main
- **Severity:** S2  
- **Area:** Page dark mode  
- **Mechanism:** Main only toggles bool `defaultDarkMode`; script always uses smart invert path when true (no `PageDarkEngine.native`).  
- **User impact:** Users who want sites to see dark `prefers-color-scheme` without Paddle invert must leave global page dark off and rely on site-native theming.  
- **Disposition:** Fixed-on-PR  
- **Tree:** main  

### FA-DRK-03 — Per-site dark mode is bool-only on main
- **Severity:** S2  
- **Area:** `sites` policy  
- **Mechanism:** `SiteSettings.darkMode: Bool?` (main ~44); PR `SiteDarkMode` with `native` and `auto` (~25–28 PR).  
- **User impact:** Cannot pin one host to native dark while global smart invert is on, except by turning global off.  
- **Disposition:** Fixed-on-PR  
- **Tree:** main  

### FA-DRK-04 — Weaker `isNaturallyDark` on main → invert on some native-dark sites when global dark is on
- **Severity:** S2  
- **Area:** `DarkModeScript`  
- **Mechanism:** main `measureNaturallyDark` (~128–155) vs PR (~258–296): no shadow-root probe, fewer theme attrs, no `meta[name=color-scheme"]`, no computed `color-scheme` pass. When `shouldBeDark()` is true and detector returns false, main sets `data-paddle-dark-mode="active"` (~177–178).  
- **User impact:** `.always` / `.system` (dark chrome) can still invert sites PR #3 treats as naturally dark (PR motivation).  
- **Disposition:** Fixed-on-PR  
- **Tree:** main  

### FA-DRK-05 — Early `color-scheme: dark` injection before natural-dark measurement (main)
- **Severity:** S3  
- **Area:** First paint  
- **Mechanism:** At document start, `if (shouldBeDark()) ensureStyles()` (`DarkModeScript.swift` ~342–344 main) installs `:root { color-scheme: dark !important; }` before `evaluateAndApply` / `isNaturallyDark`.  
- **User impact:** Native-dark sites may still get forced dark color-scheme (without full-page invert) while global/site policy asks for dark — usually desirable, but distinct from “leave page entirely alone.”  
- **Disposition:** Open  
- **Tree:** main  

### FA-DRK-06 — PR smart mode still activates invert on map / code-editor fixtures
- **Severity:** S3  
- **Area:** Smart invert / embeds  
- **Mechanism:** Probes show `data-paddle-dark-mode=active` + invert for `map-canvas` and `code-editor` despite expanded un-invert selectors (`DarkModeScript.swift` ~92–112 PR); evidence `docs/evidence/smart-dark-mode-2026-11-05/probes.txt`.  
- **User impact:** Map and IDE surfaces may still get global invert with compensating child filters — visual regressions possible vs native-dark baseline.  
- **Disposition:** Open  
- **Tree:** PR #3  

### FA-DRK-07 — Large dark-mode user script always injected
- **Severity:** S3  
- **Area:** Performance  
- **Mechanism:** `WebEnvironment.reloadUserScripts` unconditional `DarkModeScript` WKUserScript (~495–503 main; ~497–507 PR). PR script larger + theme observer (~492–531 PR).  
- **User impact:** Parse/eval cost every navigation even when `darkMode` is `off` (JS no-ops but still loads).  
- **Disposition:** Accepted risk  
- **Tree:** main \| PR #3  

### FA-DRK-08 — Tab bridge on main cannot express native/smart distinction live
- **Severity:** S3  
- **Area:** Tab / JS API  
- **Mechanism:** `applySiteDarkMode` only calls `setDarkMode(bool)` (`Tab.swift` ~1016–1022 main); PR uses `setPolicy({ engine })` (~1032–1041 PR).  
- **User impact:** After config change to `native`, open tabs need script reload path; bool API collapses engines until reload.  
- **Disposition:** Fixed-on-PR  
- **Tree:** main  

### FA-DRK-09 — ⇧⌘D site toggle semantics change (bool flip → light/dark enum)
- **Severity:** S4  
- **Area:** Shortcuts / Mosaic  
- **Mechanism:** main `toggleDarkMode` writes `.bool(next)` (~1046); PR writes `.string(mode.rawValue)` for `.light`/`.dark` (~1064–1066 PR). Mosaic routing unchanged (`BrowserModel.swift` ~523–532 both).  
- **User impact:** ⇧⌘D no longer cycles native/auto; users use View → Dark Mode submenu on PR.  
- **Disposition:** Needs Walker  
- **Tree:** main \| PR #3  

### FA-DRK-10 — View menu ⇧⌘D label change on PR
- **Severity:** S4  
- **Area:** Chrome UX  
- **Mechanism:** main menu item “Dark Mode” + single action (`MainMenu.swift` ~103); PR “Toggle Light / Dark” plus per-site submenu (`smart-dark-mode/.../MainMenu.swift` ~103–112).  
- **User impact:** Discoverability of Auto/Native/Keep Light improves; shortcut alone is coarser.  
- **Disposition:** Fixed-on-PR  
- **Tree:** PR #3  

### FA-DRK-11 — Chrome `appearance` and page `darkMode` remain decoupled (both trees)
- **Severity:** S4  
- **Area:** Documentation / UX  
- **Mechanism:** Separate pickers and keys (`AppearancePane.swift` Windows vs Pages sections; `AppModel.applyAppearance` vs dark script).  
- **User impact:** Intentional; README and help text describe linkage only for `.system` page mode.  
- **Disposition:** Closed  
- **Tree:** main \| PR #3  
