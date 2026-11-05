# Settings IA + aesthetics audit (read-only)

**Main:** `015dc73` — `/Users/Walker/Code/Projects/Paddle/App/Paddle/Settings/` (24 Swift files)  
**PR #2:** `cursor/settings-ui-audit-a3f0` @ `73d02c6` — `/Users/Walker/Code/Projects/Paddle-wt/settings-audit/App/Paddle/Settings/`  
**Prior narrative (not rubber-stamped):** `settings-audit/docs/settings-audit.md`, `settings-audit/docs/settings-ux-audit-2026-11-05.md`  
**Evidence (cite only):** `settings-audit/docs/evidence/settings-audit-2026-11-05/`, `settings-audit/docs/evidence/settings-ux-audit-2026-11-05/`

**S0:** **None.** No blank panes, no Settings saves that silently drop keys in code reviewed; misleading copy is P1 at worst.

---

## Sidebar IA (both trees)

Order matches `SettingsLink.Pane` / `SettingsPane.allCases`: General → Appearance → Profiles → Tabs & Memory → Mosaic → Privacy & Blocking → Sites → Extensions → Shortcuts → Advanced. Deep links: `paddle://settings/<rawValue>` (`SettingsTabView.swift`, `SettingsLink.swift`).

Search: whitespace-AND match on pane title + `keywords` (`SettingsViews.swift` ~140–148). PR #2 adds `SettingsPane.matchHint` in sidebar rows (`SettingsTabView.swift` ~60, `SettingsViews.swift` ~151–168).

---

## Pane → `PaddleConfig` / data map (main @ `015dc73`)

Instant apply via `SettingsModel` → `config.json` unless noted. Per-profile extension toggles and overrides use `profiles.json` (Profiles pane).

| Pane | Primary keys / surfaces | Notes |
|------|-------------------------|--------|
| **General** | `onLaunch`, `externalLinks`, `newTabPosition`, `afterClosingTab`, `askBeforeQuitting`, `askBeforeClosingWindow`, `openLinksInBackground`, `homepage`, `newTabPage`, `searchTemplate`, `searchSuggestTemplate`, `showFullAddress`, `downloadFolder`, `askWhereToDownload`, `newTabFrequentSites`, `newTabNotifications`, `newTabHiddenNotifications`, `newTabSections`, `newTabExtension`, `newTabFeeds`, `sites.*.notifications` (notifier rows), `swipeNavigation`, `pinchZoom`, `tabKeyHighlightsLinks`, `soundEffects` | Default browser: OS API, not config. Bookmarks bar: `AppModel.showBookmarksBar` (UserDefaults), not `config.json`. |
| **Appearance** | `appearance`, `tabLayout`, `interfaceTextSize`, `highContrastTabs`, `showHomeButton`, `alwaysShowDownloadsButton`, `alwaysShowTabCloseButtons`, `darkMode`, `invertTextImages`, `underlineLinks`, `reduceMotion`, `reduceTransparency`, `theme`, `accentColor`, `chromeTint`, `chromeTintStrength`, `defaultZoom`, `minimumFontSize` | Theme builder writes `themes/*.json`; `theme` key selects file. |
| **Profiles** | `profiles.json` overrides (per profile): search/pages, downloads, history, theme/tint, tab timers, `sites`, etc. | Global `config.json` still drives default profile; UI explains split (`ProfilesPane.swift`). |
| **Tabs & Memory** | `tabFreezeAfterMinutes`, `keepPageWorkRunning`, `keepNotifyingSitesLive`, `tabSleepAfterMinutes`, `sleepPinnedTabs`, `maxAwakeTabs`, `cpuSleepPercent`, `sessionHistoryTabs`, `resumeMediaOnSelect`, `linkPreview`, `showTabMemory` | |
| **Mosaic** | All `mosaic*` keys (`mosaicMaxPanes` … `mosaicStripStyle`, optional `mosaicFreezeAfterMinutes`, `mosaicSleepAfterMinutes`) | Legacy `multiViewMaxPanes` cleared on save from Mosaic picker. |
| **Privacy** | `contentBlocking`, `filterLists`, `filterUpdateDays`, `scriptlets`, `trustedLists`, `httpsOnly`, `fraudWarnings`, `speculativeLoading`, `historyDays`, `contactAutofill` | Filter/user rules are files (`filters/`, `user-filters.txt`); Website data sheet uses `WKWebsiteDataStore`, not a top-level key. |
| **Sites** | `sites.<host>.*` (`zoom`, `darkMode`, `javaScript`, `autoplay`, `contentBlocking`, `popups`, `location`, `notifications`, `freeze`; model also supports `httpsOnly` field), `siteUserAgents.<host>` | Camera/mic/download answers: **session map** in `SettingsModel+Sites.swift`, not `config.json`. Table + Clear Data / Forget. |
| **Extensions** | `extensions.<folder>`, `extensionsInPrivate`, `extensionCompat.<folder>.private`, `extensionToolbar.<folder>`, `extensionUpdates` | Folder install under `extensions/`; permissions in `extension-permissions.json`. |
| **Shortcuts** | `shortcuts.<actionName>` | Validates against `MainMenu.actionNames`. |
| **Advanced** | `developerTools`, `userAgentSuffix`, `controlBridge`, `controlBridgeScripts` | Unknown keys / validator issues / Tidy UI for redundant defaults. |

---

## Top-level keys with no dedicated Settings control (main)

| Key | Settings exposure | Disposition |
|-----|-------------------|-------------|
| `extensionsOnDemand` | Search keyword only (Extensions pane keywords omit the key name) | **Alias FA-EXT-03** (extensions worker); file/README + MCP |
| `sitePersonas` | Sidebar search keyword on Sites (`SettingsViews.swift` ~121); no editor | Accepted risk / README file-only |
| `sites.<host>.httpsOnly` | Global `httpsOnly` toggle in Privacy; `SettingsModel+Sites` can write field but **no Sites column/sheet** | Open gap (S4) — FA-SET-16 |
| `extensionCompat.<folder>.persona` / `.shims` / `.publicID` | Read-only compat notes in extension Details; not editable | Accepted risk (power-user JSON) — FA-SET-17 |
| Bookmarks bar visibility | General toggle → UserDefaults | By design (documented in help) |

---

## Footers / Learn more / form chrome (main vs PR #2)

| Pattern | Main (`015dc73`) | PR #2 (`73d02c6`) | Evidence |
|---------|------------------|-------------------|----------|
| Long footers | `SettingsCaption` paragraphs in General, Profiles, Tabs & Memory, Privacy, Mosaic, Advanced; Sites multi-line caption footer | `SettingsLearnMore` + shorter summaries (`SettingsModel+Keys.swift` ~52+) | `settings-audit-2026-11-05/before-round-2/privacy.png` → after privacy/general |
| Form layout | `SettingsForm` hard-coded **4-column** masonry (`SettingsViews.swift` ~235) | Default **2** columns; **1** column stack on Privacy, Profiles, Tabs, Advanced, Mosaic (`maxColumns` param, `VStack` when 1) | `before/mosaic.png` vs `mosaic.png` (both evidence dirs) |
| Menu/picker tint | No form `.tint(.primary)`; pickers inherit accent | `.tint(.primary)` on form cards + `settingsMenuValueLabel()` | `before/general.png` vs `general.png` |
| Mosaic IA | ~8 peer sections, all expanded, inline captions | Jump bar + `SettingsDisclosure` groups + “Advanced tuning” bucket | `settings-audit-2026-11-05/before/mosaic.png` |
| Sites table | **11** columns (incl. Pop-ups, Freeze, UA in grid) | **8** visible + **More…** sheet (Pop-ups, Freeze, UA) | `before/sites.png` vs `sites.png` |
| Sites pane subtitle | Claims “camera” in per-site permissions (`SettingsViews.swift` ~32) | Accurate list (no false camera column claim) (~32) | sites before/after |
| Pane header icon | `Color.accentColor` tile (`SettingsViews.swift` ~172–174) | Neutral `.primary` on gray tile (~191–193) | `settings-ux-audit-2026-11-05/*.png` |
| Sidebar search | Title only; empty “No settings match” | Match hint under title; richer empty copy | `search-hints.png` |
| Default browser row | `LabeledContent` + horizontal `HStack` (`GeneralPane.swift` ~557–569) | Stacked `VStack` + wrap + Learn more (~566–587) | general after PNGs |
| Extensions status | Status merged into accent-colored caption line on same row as version (inherits form accent) | Split `statusLine` secondary + `settingsAccentToggle()` on load switch only | `before-round-2/extensions.png` |

---

## Sites table & session UX (main)

- **Table:** Host, Zoom, Dark mode, JavaScript, Autoplay, Blocking, Pop-ups, Location, Notifications, Freeze, User agent — wide horizontal scan (`SitesPane.swift` ~56–98).
- **Session block:** “This session” lists camera/mic/location/notification/download **runtime** grants; empty state is plain `Text` (~365–368). Footer essay ~137–140.
- **PR #2:** Narrower table + `siteMoreSheet`; footer → `SettingsLearnMore`; empty session → `SettingsLearnMore` (~395–398). **Still plain** `Text(status)` for Clear Data outcomes (~126–128) — UX audit P2 “session/status line” remains.

---

## Extensions UX (main)

- One **Section card per folder** inside default **4-column** masonry (`ExtensionsPane.swift` ~29, `SettingsForm` default).
- Row: headline + caption line with version · **Running** · source (`foregroundStyle(.secondary)` but form accent still tints symbols) (~186–197).
- Global: `extensionsInPrivate`, `extensionUpdates`; per-folder load, Details (private, toolbar, compat notes, actions).
- **No** `extensionsOnDemand` toggle (see FA-EXT-03).

PR #2: 1-column when ≥5 folders; slimmer row layout; persisted update outcomes in Details (`lastOutcome`); status line explicitly secondary.

---

## Findings

### FA-SET-01 — Sites pane subtitle overclaims per-site camera control
- **Severity:** S2 (misleading IA)  
- **Area:** settings / Sites header  
- **Mechanism:** `SettingsPane.summary` for `.sites` lists “camera” as a per-site permission (`App/Paddle/Settings/SettingsViews.swift` ~32); camera/mic are session-only in `sessionSection`, not table columns.  
- **Evidence:** Code on main; PR fixes copy (~32 on PR tree). Compare `settings-audit-2026-11-05/before/sites.png` vs after.  
- **User impact:** Users search Settings for camera rules and expect a column or toggle that does not exist.  
- **Disposition:** **Open** on main · **Fixed-on-PR**  
- **Suggested fix shape:** Merge PR summary text; optionally add Learn more pointing to “This session”.  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-02 — Mosaic preferences unscannable (flat multi-section dump)
- **Severity:** S3  
- **Area:** settings / Mosaic IA  
- **Mechanism:** Main `MosaicPane` exposes many sections at once inside 4-column masonry; long `SettingsCaption` blocks (~44, ~74, …).  
- **Evidence:** `MosaicPane.swift` structure; `settings-audit-2026-11-05/before/mosaic.png`.  
- **User impact:** High cognitive load; esoteric strip/shading knobs compete with layout basics.  
- **Disposition:** **Open** on main · **Fixed-on-PR** (jump bar + disclosures + 1-col)  
- **Suggested fix shape:** Land PR `MosaicPane` grouping.  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-03 — Four-column Settings masonry on dense panes
- **Severity:** S3  
- **Area:** settings / form layout  
- **Mechanism:** `SettingsForm` body uses `MasonryLayout(..., maxColumns: 4)` with no override (`SettingsViews.swift` ~235). Privacy, Extensions, Tabs, Advanced stack many cards → short columns and uneven scroll.  
- **Evidence:** Code; `settings-audit-2026-11-05/before/privacy.png` vs after (2-col/1-col).  
- **User impact:** Harder vertical scan; orphan cards in third/fourth columns.  
- **Disposition:** **Open** on main · **Fixed-on-PR**  
- **Suggested fix shape:** PR defaults (`maxColumns: 2`, dense panes `1` + `VStack`).  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-04 — Theme accent tints menu/picker values
- **Severity:** S3  
- **Area:** settings / accent discipline  
- **Mechanism:** Main grouped forms lack `.tint(.primary)`; SwiftUI menus/pickers use environment accent (theme green). PR adds `.tint(.primary)` on each form card and `settingsMenuValueLabel()` (`SettingsViews.swift` ~299, `SettingsModel+Keys.swift` ~79).  
- **Evidence:** `settings-audit-2026-11-05/before/general.png` vs `general.png`.  
- **User impact:** Values look like active state; toggles less distinct from labels.  
- **Disposition:** **Open** on main · **Fixed-on-PR**  
- **Suggested fix shape:** Ship PR form tint + picker modifier; keep accent on switches via `settingsAccentToggle()` where needed.  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-05 — Caption walls instead of progressive disclosure
- **Severity:** S3  
- **Area:** settings / copy density  
- **Mechanism:** Main uses always-visible `SettingsCaption` in General (Search), Profiles footer, Tabs & Memory freeze essay (~57), Privacy filter/history blocks, Mosaic (8 captions), Advanced bridge text.  
- **Evidence:** Grep `SettingsCaption` on main Settings; PR replaces most with `SettingsLearnMore`.  
- **User impact:** First screen reads like README; weak hierarchy.  
- **Disposition:** **Open** on main · **Fixed-on-PR** (bulk)  
- **Suggested fix shape:** Adopt `SettingsLearnMore` pattern from PR.  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-06 — Sites table too wide (11 columns)
- **Severity:** S3  
- **Area:** settings / Sites table  
- **Mechanism:** Main `Table` includes Pop-ups, Freeze, User agent inline (`SitesPane.swift` ~84–97).  
- **Evidence:** `settings-audit-2026-11-05/before/sites.png`; PR `More…` sheet (~89–95, ~173–195).  
- **User impact:** Horizontal scanning; small touch targets in narrow window.  
- **Disposition:** **Open** on main · **Fixed-on-PR**  
- **Suggested fix shape:** Keep PR column set + sheet.  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-07 — Sites footer essay below table
- **Severity:** S4  
- **Area:** settings / Sites copy  
- **Mechanism:** Main ~137–140 multi-sentence caption (freeze/notify/Web Push). PR → `SettingsLearnMore` (~134–137).  
- **Evidence:** Code diff; sites after PNG.  
- **User impact:** Minor scroll/clutter.  
- **Disposition:** **Open** on main · **Fixed-on-PR**  
- **Suggested fix shape:** One-line summary + Learn more (PR).  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-08 — Default browser status layout truncates
- **Severity:** S4  
- **Area:** settings / General  
- **Mechanism:** Main `DefaultBrowserRow` packs label + button in one `LabeledContent` `HStack` (`GeneralPane.swift` ~557–569); long “Another browser…” string can clip in narrow columns. PR stacks vertically with `fixedSize` (~566–575).  
- **Evidence:** `settings-audit.md` P3; `general.png` after round 2.  
- **User impact:** Status unreadable without widening window.  
- **Disposition:** **Open** on main · **Fixed-on-PR**  
- **Suggested fix shape:** PR `VStack` layout.  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-09 — Pane header icon uses accent fill
- **Severity:** S4  
- **Area:** settings / hierarchy  
- **Mechanism:** Main `paneHeader` tints symbol and tile with `Color.accentColor` (`SettingsViews.swift` ~172–174). PR uses neutral primary (~191–193).  
- **Evidence:** `settings-ux-audit-2026-11-05/general.png`.  
- **User impact:** Competes with toggles for accent attention.  
- **Disposition:** **Open** on main · **Fixed-on-PR**  
- **Suggested fix shape:** Neutral header tile (PR).  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-10 — Sidebar search does not explain matches
- **Severity:** S3  
- **Area:** settings / search IA  
- **Mechanism:** Main sidebar lists pane titles only (`SettingsTabView.swift` ~57–60). PR shows `matchHint` (~60).  
- **Evidence:** `settings-ux-audit-2026-11-05/search-hints.png`.  
- **User impact:** Opaque why “mosaic” matched “sleep”.  
- **Disposition:** **Open** on main · **Fixed-on-PR**  
- **Suggested fix shape:** Port `matchHint` + empty-state hint text.  
- **Tree:** main Open; PR #2 Fixed-on-PR  

### FA-SET-11 — Sites session block and action status lack designed states
- **Severity:** S3  
- **Area:** settings / Sites UX  
- **Mechanism:** Main empty session = plain `Text` (~366–368); Clear Data / errors = secondary `Text(status)` (~129–131). PR improves empty copy via `SettingsLearnMore` but keeps same status line pattern (~126–128, ~395–398).  
- **Evidence:** Code both trees; UX audit backlog P2 `#craft-states`; `settings-ux-audit-2026-11-05/sites.png`.  
- **User impact:** Success/failure/waiting for Clear Data and session grants less scannable than Extensions update outcomes.  
- **Disposition:** **Open** (main and PR #2)  
- **Suggested fix shape:** Banner or labeled outcome row mirroring extension `lastOutcome` styling.  
- **Tree:** both  

### FA-SET-12 — Mosaic strip shading captions still inline (residual)
- **Severity:** S4  
- **Area:** settings / Mosaic copy  
- **Mechanism:** PR reduces main’s eight Mosaic captions to two remaining `SettingsCaption` lines (`MosaicPane.swift` ~386, ~552 on PR tree); UX audit P3 “convert strip shading captions”.  
- **Evidence:** Grep on PR MosaicPane; `mosaic.png` UX audit.  
- **User impact:** Minor inconsistency with Learn-more pattern elsewhere.  
- **Disposition:** **Open** on PR #2 (main has more instances)  
- **Suggested fix shape:** Replace remaining captions with `SettingsLearnMore`.  
- **Tree:** main Open (worse); PR #2 Open (residual)  

### FA-SET-13 — Shortcuts pane not grouped Form cards
- **Severity:** S4  
- **Area:** settings / visual parity  
- **Mechanism:** `ShortcutsPane` uses standalone `Table` + toolbar, not `SettingsForm` cards (`ShortcutsPane.swift` ~19+); unchanged on PR.  
- **Evidence:** `shortcuts.png` both evidence folders.  
- **User impact:** Slightly different rhythm vs other panes; function OK.  
- **Disposition:** **Open**  
- **Suggested fix shape:** Optional wrapper section/card for consistency (low priority).  
- **Tree:** both  

### FA-SET-14 — `extensionsOnDemand` not exposed in Settings UI
- **Severity:** S4  
- **Area:** settings / config gap  
- **Mechanism:** Key on `PaddleConfig` (`PaddleConfig.swift` ~421); reconciled in `AppModel` on change; no `ExtensionsPane` binding (confirmed grep Settings).  
- **Evidence:** **Alias FA-EXT-03** (`_worker-extensions.md`); README ~155.  
- **User impact:** Must edit JSON/MCP to disable on-demand unloading.  
- **Disposition:** **Accepted risk** (documented file-only); do not duplicate Open ID — track under FA-EXT-03  
- **Suggested fix shape:** Toggle + link to `docs/measurements.md`.  
- **Tree:** main  

### FA-SET-15 — `sitePersonas` not exposed in Settings UI
- **Severity:** S4  
- **Area:** settings / config gap  
- **Mechanism:** Only searchable keyword on Sites; persona script driven from JSON (`WebEnvironment.swift` / `SitePersonaScript.swift`).  
- **Evidence:** README ~67; Settings keywords ~121.  
- **User impact:** Chrome/Firefox identity overrides require manual JSON.  
- **Disposition:** **Accepted risk** (README file-only); UX audit Out of scope  
- **Suggested fix shape:** Optional Sites “Persona” column or Advanced link — product decision.  
- **Tree:** both  

### FA-SET-16 — Per-site `sites.<host>.httpsOnly` not editable in Sites UI
- **Severity:** S4  
- **Area:** settings / Sites completeness  
- **Mechanism:** Privacy exposes global `httpsOnly`; `SettingsModel+Sites` supports `.httpsOnly` field (~130) but `SitesPane` has no picker (only `isSet` helper ~353). Exemptions today via in-page HTTP dialog (session) + global toggle help text.  
- **Evidence:** `PrivacyPane.swift` ~61 help; `SitesPane.swift` grep.  
- **User impact:** Persistent per-host HTTP allow list requires JSON edit.  
- **Disposition:** **Open**  
- **Suggested fix shape:** Optional tri-state column or More… sheet row.  
- **Tree:** both  

### FA-SET-17 — `extensionCompat` advanced fields view-only
- **Severity:** S4  
- **Area:** settings / Extensions completeness  
- **Mechanism:** Settings edits `private` + toolbar + load; persona/shims/publicID only appear as read-only compat notes (`ExtensionsPane.swift` ~293–300).  
- **Evidence:** `PaddleConfig` comment ~422–423.  
- **User impact:** Power users edit JSON for persona overrides.  
- **Disposition:** **Accepted risk**  
- **Suggested fix shape:** None unless extension compat becomes first-class UI.  
- **Tree:** both  

### FA-SET-18 — Many extensions → long scroll (card-per-folder)
- **Severity:** S4  
- **Area:** settings / Extensions density  
- **Mechanism:** By design one section per folder; PR switches to 1-column masonry when ≥5 folders (`ExtensionsPane.swift` PR ~30).  
- **Evidence:** `settings-audit.md` P3 residual; `extensions.png`.  
- **User impact:** Large install sets require scrolling; not broken.  
- **Disposition:** **Accepted risk**  
- **Suggested fix shape:** Optional compact list mode — nice-to-have.  
- **Tree:** both (PR slightly better)  

---

## Prior P0/P1 re-verification (main code, not PR narrative)

| Prior ID | Claim | Main @ `015dc73` | PR #2 |
|----------|-------|------------------|-------|
| P1 Sites camera subtitle | Misleading | **Confirmed** (`SettingsViews.swift` ~32) | Fixed summary |
| P1 Mosaic dump | Unscannable | **Confirmed** (no disclosures) | Fixed IA |
| P2 table width / green menus / caption walls | Aesthetic | **Confirmed** on main | Fixed in PR |
| P2 `extensionsOnDemand` / `sitePersonas` | No UI | **Confirmed** | Still no UI (by design) |
| P2 Sites session/status | Plain states | **Confirmed** | Partial (Learn more empty session only) |
| P3 Mosaic captions | Inline text | **8 captions** | **2** remain (FA-SET-12) |

No P0 issues found on main Settings code path.

---

## PR #2-only polish not on main (summary)

Shared form rhythm, Learn more footers, Sites More… sheet + subtitle fix, Mosaic jump/disclosure, search hints, neutral pane header, default-browser stack, extension status secondary styling, dense-pane 1-column stacks — all present in `settings-audit` tree @ `73d02c6`; evidence paths under `docs/evidence/settings-audit-2026-11-05/` and `settings-ux-audit-2026-11-05/`.
