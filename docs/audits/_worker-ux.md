# UX craft / accessibility audit (read-only)

**Tree:** `main` @ `015dc73`. **Live app:** not run (bundle-id conflict PID 7716; Paddle MCP unavailable).  
**Method:** SwiftUI/AppKit source on main; Settings chrome visuals cited only from PR #2 evidence PNGs (no layout inferred as verified elsewhere).  
**Settings evidence (PR #2):** `/Users/Walker/Code/Projects/Paddle-wt/settings-audit/docs/evidence/settings-ux-audit-2026-11-05/`  
**S0:** **None.** No VoiceOver trap, keyboard dead-end, or contrast mechanism failure identified in scoped chrome/settings surfaces.

**Already green (parent):** `chromeTintStrength` README cap for **4.5:1** text contrast; mosaic dividers `accessibilityAdjustableAction`; Sites table `.accessibilityElement(children: .combine)` on PR #2 shot; color claims cite code caps not hue judgment.

---

## Executive summary

Paddle’s **menu bar** registers **121** rebindable shortcut action names (`MainMenu.add`), including **Find** (`find`, `findNext`, `findPrevious`), **tab cycling** (`nextTab`, `previousTab`, `tab1`…`tab9`), **spaces** (`space1`…`space9`, `control`+digit), and **mosaic pane focus/move** (`focusPaneLeft`/`Right`/`Up`/`Down`, `movePaneLeft`/`Right`/`Up`/`Down`, `toggleMosaic`, layout actions). SwiftUI chrome applies **explicit `accessibilityLabel`s** on icon toolbar controls (via `help`), tabs, mosaic panes/dividers, find navigation, downloads, and most Settings controls. **Contrast:** runtime tint uses `AppModel.effectiveTintStrength` → `ThemeContrast.maxTintStrength` (WCAG **4.5:1** on text/secondary on strip and toolbar); Settings shows a **“Capped at N %”** caption when the saved strength exceeds the cap. **Empty states** are explicit strings in Settings (Sites, Extensions) and Activity (downloads); New Tab mostly **omits sections** when empty rather than inline copy (except News/feeds). Gaps: **Private** / multi-profile toolbar badges rely on visible `Label` text without dedicated VO strings (**UNVERIFIED visually**); pinned/frequent New Tab empties are **silent** in code.

---

## Keyboard & menu coverage

| Area | Action names (sample) | Default keys (from `MainMenu.swift`) | VO / label notes |
|------|------------------------|--------------------------------------|------------------|
| Find in page | `find`, `findNext`, `findPrevious`, `useSelectionForFind`, `jumpToSelection` | ⌘F, ⌘G, ⇧⌘G, ⌘E, ⌘J | Find bar field placeholder **“Find on page”**; prev/next buttons labeled (**UNVERIFIED visually**) |
| Tab cycle | `nextTab`, `previousTab`, `tab1`…`tab9` | ⌃Tab, ⌃⇧Tab; ⌘1…⌘9 (`tab9` = “Last Tab”) | Tab rows: `accessibilityLabel` + `accessibilityValue` (pin/audio/group) |
| Spaces | `space1`…`space9`, `nextSpace`, `previousSpace`, … | ⌃1…⌃9 (items hidden but keys live) | Space chips: **“Space {name}”** |
| Mosaic panes | `focusPaneLeft/Right/Up/Down`, `movePaneLeft/Right/Up/Down`, `toggleMosaic`, `zoomPane`, … | ⌃⌥ arrows (focus); ⇧⌃⌥ arrows (move); ⌃⌘\\ toggle | Pane chrome labels in `MultiPanes.swift` (**UNVERIFIED visually**) |
| Tab search | `searchTabs` | ⇧⌘A | **“Search tabs”** on field |
| Settings shortcuts UI | (same 121 names) | user overrides | `ShortcutsPane`: **“Menu shortcuts”**, per-row combine (**PR #2** `shortcuts.png`) |

Mechanical count: **121** `MainMenu.add` registrations; README shortcut list line 163 comma-splits to **121** names (orchestrator brief cited **119** — treat as stale unless a narrower subset is defined elsewhere).

---

## VoiceOver & keyboard focus (chrome)

| Surface | Mechanism | Visual verification |
|---------|-----------|---------------------|
| Toolbar nav | `iconButton` → `.accessibilityLabel(help)` for Back, Forward, Reload/Stop, Home | **UNVERIFIED visually** |
| Address | `TextField("Search or enter address", …)`; security control **“Connection security and site settings”** + value | **UNVERIFIED visually** |
| Tabs strip / sidebar | Container **“Tabs”**; per-tab title + spoken pin/audio/group; mute/close buttons labeled | **UNVERIFIED visually** |
| Mosaic | Pane **“Focused pane, …”** / **“Pane, …”**; dividers **adjustable** with percent value; move/remove/address actions labeled | **UNVERIFIED visually** |
| Find bar | `AccessibilityNotification.Announcement("Not found")` on each no-match | **UNVERIFIED visually** |
| Activity / downloads | **“Downloads”**; row actions Cancel/Show/Retry labeled; empty copy below | **UNVERIFIED visually** |
| Settings sidebar | **“Settings panes”**, **“Search settings”**, **“Clear search”** | PR #2 `general.png` / `search-hints.png` (sidebar/search only) |
| Settings Sites rows | Per-control labels + table `.combine` | PR #2 `sites.png` |
| Settings Extensions | Row/details labels; empty section copy | PR #2 `extensions.png` |
| Settings Appearance tint | Slider **“Tint strength”**; cap caption when capped | PR #2 `appearance.png` (caption **UNVERIFIED** in PNG unless visible in shot — cap mechanism verified in code) |

Web page content accessibility is WebKit/site-dependent; out of scope except `tabKeyHighlightsLinks` → `WKPreferences.tabFocusesLinks`.

---

## Contrast & motion mechanisms

- **`chromeTintStrength`:** stored 0–100 (`PaddleConfig.normalizedTintStrength` clamps only range, not contrast). **Effective** strength: `AppModel.effectiveTintStrength` min of strip/toolbar bases via `ThemeContrast.maxTintStrength` (**4.5:1** on `text` and `secondaryText` per `Sources/PaddleCore/Themes.swift`). README documents automatic lowering for **4.5:1**.
- **Settings UI:** `AppearancePane` shows `Text("Capped at \(capped) % so text stays readable.")` when `effectiveTintStrength` &lt; saved value (`AppearancePane.swift`).
- **`highContrastTabs`:** environment `chromeHighContrastTabs` strengthens selected-tab fill, stroke width, and semibold title in `TabStrip`, `VerticalTabs`, mosaic view items (**brightness/weight only**, not measured on screen — **UNVERIFIED visually**).
- **`reduceMotion` / `reduceTransparency`:** `AppModel.reducesMotion` → `chromeReducesMotion`; transparency → solid window background in `BrowserView` and materials elsewhere (**UNVERIFIED visually**).

---

## Empty states (code strings; visuals unless PR #2)

| Surface | When empty | User-facing copy (main) | Evidence |
|---------|------------|-------------------------|----------|
| New Tab — Pinned | `app.newTab.sites` empty | No dedicated empty message; **Add** tile (`accessibilityLabel` **“Add site”**) still shown | **UNVERIFIED visually** |
| New Tab — Frequent | `frequent.isEmpty` | Section **hidden** (no “no history yet” string) | **UNVERIFIED visually** |
| New Tab — News | `feeds.items.isEmpty` | **“Loading stories…”** / **“No stories yet.”** / feed error → Settings pointer | **UNVERIFIED visually** |
| New Tab — feeds unset | `newTabFeeds` empty | **AddNewsPrompt** (“Add news to New Tab”, **Add News…** / **Not Now**) | **UNVERIFIED visually** |
| Settings — Sites | `rows.isEmpty` | **“No sites yet. Add one, or zoom a page: Zoom In and Zoom Out remember the zoom here.”** | PR #2 `sites.png` if empty row shown in capture |
| Settings — Extensions | `summaries.isEmpty` | **“No extensions. Put each unpacked extension in its own folder in the extensions folder, then Reload Extensions.”** | PR #2 `extensions.png` |
| Activity — Downloads | `listed.isEmpty` | **“No downloads this session.”** | **UNVERIFIED visually** |
| File — Share menu | no URL | **“No Shareable Page”** (disabled item) | **UNVERIFIED visually** |

---

## Findings

### FA-UX-01 — Tint strength capped for WCAG AA text contrast (4.5:1)
- **Severity:** S4  
- **Area:** contrast / appearance  
- **Mechanism:** `ThemeContrast.maxTintStrength` + `AppModel.effectiveTintStrength`; Settings caption when capped; `ResolvedChromeTheme` uses capped strength for drawn surfaces.  
- **Evidence:** `AppModel.swift` `effectiveTintStrength`; `Themes.swift` `maxTintStrength`; `AppearancePane.swift` cap caption; `README.md` `chromeTintStrength` row.  
- **User impact:** Strong tint requests do not push chrome text below **4.5:1** against computed surfaces.  
- **Disposition:** Already green  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73`; Settings chrome PR #2 `appearance.png` (optional visual; cap text **UNVERIFIED visually** in PNG).

### FA-UX-02 — Menu keyboard coverage for find, tabs, spaces, mosaic
- **Severity:** S4  
- **Area:** keyboard  
- **Mechanism:** `MainMenu.build` registers actions and key equivalents; hidden items keep `allowsKeyEquivalentWhenHidden` for spaces; mosaic focus/move on ⌃⌥ and ⇧⌃⌥ arrows.  
- **Evidence:** `MainMenu.swift` Edit Find block; Tabs menu `tab1`…`tab9`, `space1`…`space9`, mosaic/focus selectors.  
- **User impact:** Power users can operate core navigation without pointer; rebinding via Settings > Shortcuts.  
- **Disposition:** Accepted  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73`.

### FA-UX-03 — Mosaic splitters expose VoiceOver adjustable actions
- **Severity:** S4  
- **Area:** VoiceOver / mosaic  
- **Mechanism:** Divider views use `.accessibilityLabel` (horizontal vs stacked), `.accessibilityAdjustableAction`, and percent `.accessibilityValue`.  
- **Evidence:** `MultiPanes.swift` ~531–537.  
- **User impact:** VO users can resize panes without drag precision.  
- **Disposition:** Already green  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73` (**UNVERIFIED visually**).

### FA-UX-04 — Settings Sites table combines row accessibility (PR #2)
- **Severity:** S4  
- **Area:** VoiceOver / settings  
- **Mechanism:** Sites list rows use `.accessibilityElement(children: .combine)` with per-field labels (`SitesPane.swift`).  
- **Evidence:** `SitesPane.swift`; PR #2 `sites.png`.  
- **User impact:** Fewer redundant VO stops per site row when navigating the table.  
- **Disposition:** Already green  
- **Suggested fix shape:** N/A.  
- **Tree:** PR #2 evidence + `main` @ `015dc73` code.

### FA-UX-05 — Find-in-page announces “Not found” on each failed match
- **Severity:** S4  
- **Area:** VoiceOver / find  
- **Mechanism:** `FindBar` posts `AccessibilityNotification.Announcement("Not found")` whenever `findNoMatch` becomes true (comment: every search, not only first).  
- **Evidence:** `BrowserView.swift` `FindBar` ~772–775; menu actions `find`/`findNext`/`findPrevious`.  
- **User impact:** Non-visual feedback when string absent on page.  
- **Disposition:** Accepted  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73` (**UNVERIFIED visually**).

### FA-UX-06 — New Tab hides empty Frequent (and Pinned) without explanatory copy
- **Severity:** S3  
- **Area:** empty states / New Tab  
- **Mechanism:** `.frequent` section omitted when `frequent.isEmpty`; pinned section always shows tile grid with **Add** only when no pins — no “No pinned sites” string.  
- **Evidence:** `NewTabPage.swift` `sectionView` `.pinned` / `.frequent`.  
- **User impact:** First-time or cleared-history users may not know why a section is missing vs loading.  
- **Disposition:** Fix candidate  
- **Suggested fix shape:** Optional secondary copy when `showsFrequent && frequent.isEmpty` or when `sites.isEmpty` (keep **Customize Paddle…** link).  
- **Tree:** `main` @ `015dc73` (**UNVERIFIED visually**).

### FA-UX-07 — Settings & Activity empty states are explicit (good pattern)
- **Severity:** S4  
- **Area:** empty states  
- **Mechanism:** Sites, Extensions Settings sections and Activity downloads list inject secondary `Text` when collections empty.  
- **Evidence:** `SitesPane.swift` ~111–112; `ExtensionsPane.swift` ~42–45; `ActivityView.swift` ~239–240.  
- **User impact:** Clear next steps (add site, install extension, wait for download).  
- **Disposition:** Accepted  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73`; Settings PR #2 `sites.png`, `extensions.png` where captures include empty UI.

### FA-UX-08 — Private window and profile toolbar badges lack dedicated accessibility labels
- **Severity:** S3  
- **Area:** VoiceOver / toolbar  
- **Mechanism:** `Label("Private", …)` and profile `Label(profile.name, …)` use visible text + `.help` on Private only; no `.accessibilityLabel` override.  
- **Evidence:** `BrowserView.swift` `Toolbar` ~377–389.  
- **User impact:** VO may read symbols + text inconsistently; profile badge may be easy to skip in rotor order.  
- **Disposition:** Fix candidate  
- **Suggested fix shape:** `.accessibilityElement(children: .combine)` or explicit **“Private browsing”** / **“Profile: {name}”** labels.  
- **Tree:** `main` @ `015dc73` (**UNVERIFIED visually**).

### FA-UX-09 — `highContrastTabs` strengthens selection by opacity/stroke only (not verified on screen)
- **Severity:** S3  
- **Area:** contrast / tabs  
- **Mechanism:** `chromeHighContrastTabs` adjusts fill opacities, stroke opacity/width, semibold selected titles — no separate color token.  
- **Evidence:** `TabStrip.swift`, `VerticalTabs.swift` `sidebarBackground`; config key `highContrastTabs` in `PaddleConfig`.  
- **User impact:** May help low-vision users who need edge emphasis; benefit depends on theme/tint (**not measured this pass**).  
- **Disposition:** Monitor  
- **Suggested fix shape:** Optional user testing with Reduce Transparency + high contrast on; no code change required for audit.  
- **Tree:** `main` @ `015dc73` (**UNVERIFIED visually**).

### FA-UX-10 — Shortcut action catalog size (121) vs brief reference (119)
- **Severity:** S4  
- **Area:** keyboard / docs  
- **Mechanism:** `MainMenu.add` registers **121** unique action names; README shortcut line comma-count **121**.  
- **Evidence:** `MainMenu.swift`; `README.md` shortcut action names line.  
- **User impact:** Settings Shortcuts list completeness; doc drift if external brief still says 119.  
- **Disposition:** Monitor  
- **Suggested fix shape:** Reconcile README/validator counts with `MainMenu.actionNames.count` in a docs-only pass (out of scope here).  
- **Tree:** `main` @ `015dc73`.

### FA-UX-11 — Tab key on pages (`tabKeyHighlightsLinks`) off by default
- **Severity:** S4  
- **Area:** keyboard / web content  
- **Mechanism:** `PaddleConfig.tabKeyHighlightsLinks` default `false`; `WebEnvironment` sets `tabFocusesLinks`; General Settings toggle with help text.  
- **Evidence:** `PaddleConfig.swift`; `GeneralPane.swift` ConfigToggle; `WebEnvironment.swift`.  
- **User impact:** Tab key stays in form controls unless user opts into link walking (standard macOS browser default).  
- **Disposition:** Accepted  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73`.

### FA-UX-12 — Settings search & pane list expose accessibility labels (PR #2)
- **Severity:** S4  
- **Area:** VoiceOver / settings  
- **Mechanism:** `SettingsTabView` labels sidebar **“Settings panes”**, search field, clear button.  
- **Evidence:** `SettingsTabView.swift`; PR #2 `search-hints.png`, `general.png`.  
- **User impact:** VO navigation of Settings IA.  
- **Disposition:** Accepted  
- **Tree:** PR #2 + `main` @ `015dc73`.

---

## Out of scope / not audited live

- Web content ARIA/roles, extension popups, and system share sheets.  
- Pixel confirmation of chrome tab strip, toolbar, New Tab page, Activity popover, or Find bar (no app launch).  
- Settings information architecture duplicates (settings worker).

---

## Reference counts

- `accessibilityLabel` occurrences under `App/Paddle/**/*.swift`: **135** line matches (see `_worker-ux.verify.txt`).  
- Findings: **12** (`FA-UX-01` … `FA-UX-12`).
