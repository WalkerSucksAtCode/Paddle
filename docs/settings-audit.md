# Settings audit (2026-11-05, UI polish pass + round 2)

**App (after screenshots):** Debug build from this branch (`build/DerivedData.noindex/…/Paddle.app`).  
**Reference install:** `/Applications/Paddle.app` **0.1.157 (157)** (notarized).  
**Evidence:** [`docs/evidence/settings-audit-2026-11-05/`](evidence/settings-audit-2026-11-05/) — **after** at pane root; **before** initial audit at [`before/`](evidence/settings-audit-2026-11-05/before/); **round-1 after** (post first polish, pre round 2) at [`before-round-2/`](evidence/settings-audit-2026-11-05/before-round-2/).  
**Method:** Code inventory + live Settings navigation; config cross-check via `paddle-mcp` `read_config` where needed.

---

## Executive summary

**Aesthetics (primary)**  
Settings had a consistent functional surface but poor *scanability*: four-column masonry dumps (especially Mosaic, Privacy, Extensions), menu values tinted in theme accent green, and multi-paragraph “README walls” across General, Profiles, Privacy, Tabs & Memory, Sites, and Advanced. This PR lands shared form rhythm (max two columns by default, Mosaic single column + jump bar + collapsible groups), primary-colored menu values, `SettingsLearnMore` footers, a slimmer Sites table with a **More…** sheet for rare columns, the Sites subtitle fix (no false per-site camera claim), and a **round 2** pass that collapses the remaining caption walls (Privacy filter lists, General Search/New Tab, Profiles footer, Advanced bridge disclaimer), fixes default-browser status wrapping, and separates extension **status** text (secondary) from **toggle** accent.

**Function / config (secondary)**  
All ten panes map to `PaddleConfig` / README keys as before. Remaining **config gaps** (unchanged by polish): `extensionsOnDemand` and `sitePersonas` have no Settings controls (README notes file-only for on-demand). No crashes or blank panes observed.

**Residual aesthetic notes (honest)**  
Extensions remain one card per installed folder by design; with many extensions the pane scrolls (single-column layout when ≥5 folders). No further P2–P3 items from the original scorecard remain open.

---

## UI/UX aesthetics scorecard (all 10 panes)

Severity: **P0** broken · **P1** misleading/harmful · **P2** polish gap · **P3** nice-to-have · **Fixed** addressed in this PR.

| Pane | Hierarchy / grouping | Density / scroll | Typography / copy | Accent discipline | Form consistency | Table / list | Empty states | A11y notes | Evidence (after) |
|------|----------------------|------------------|-------------------|-------------------|------------------|--------------|--------------|------------|------------------|
| General | Good section cards | OK 2-col | **Fixed** Search/New Tab → Learn more | **Fixed** menu values | Baseline | N/A | **Fixed** default browser wraps | Toggles distinct from values | [general.png](evidence/settings-audit-2026-11-05/general.png) |
| Appearance | Clear Theme / Windows | OK | OK | **Fixed** pickers | Matches General | N/A | Missing theme shows “not found” | Segmented appearance OK | [appearance.png](evidence/settings-audit-2026-11-05/appearance.png) |
| Profiles | Per-profile sections | **Fixed** footer → Learn more | **Fixed** | OK | 2-col masonry | N/A | loadError message | Rename fields labeled | [profiles.png](evidence/settings-audit-2026-11-05/profiles.png) |
| Tabs & Memory | 4 section cards | **Fixed** essay → Learn more | **Fixed** | **Fixed** | **Fixed** 2-col (was 3 orphan cols) | N/A | Memory readout clear | Sleep custom field labeled | [tabsMemory.png](evidence/settings-audit-2026-11-05/tabsMemory.png) |
| Mosaic | **Fixed** jump + disclosures | **Fixed** collapsed groups | **Fixed** Learn more | **Fixed** | **Fixed** 1-col stack | N/A | N/A | Jump bar horizontal scroll | [mosaic.png](evidence/settings-audit-2026-11-05/mosaic.png) |
| Privacy | Named sections | **Fixed** 2-col max | **Fixed** list footers → Learn more | **Fixed** pickers + toggles | **Fixed** rhythm | Filter list readable | Empty rules message | Fraud toggle labeled | [privacy.png](evidence/settings-audit-2026-11-05/privacy.png) |
| Sites | Table + session | **Fixed** fewer columns | **Fixed** subtitle + footers | **Fixed** More button primary | Custom layout | **Fixed** More… sheet | Empty table overlay | Table combine a11y | [sites.png](evidence/settings-audit-2026-11-05/sites.png) |
| Extensions | Per-extension cards | **Fixed** slimmer rows; 1-col when ≥5 (P3 residual: scroll) | Details disclosure OK | **Fixed** status secondary; toggles accent | **Fixed** 2-col / 1-col | Card scan OK | No extensions message | Busy progress announced | [extensions.png](evidence/settings-audit-2026-11-05/extensions.png) |
| Shortcuts | Single list section | OK | OK | OK | OK | List | N/A | Search in sidebar | [shortcuts.png](evidence/settings-audit-2026-11-05/shortcuts.png) |
| Advanced | 3 logical groups | **Fixed** 2-col | **Fixed** bridge disclaimer → Learn more | **Fixed** bridge toggles accent | **Fixed** | N/A | Problems empty state | Setup command copy | [advanced.png](evidence/settings-audit-2026-11-05/advanced.png) |

### Before → after (high-signal)

| Pane | Before issue | After | Before PNG |
|------|----------------|-------|------------|
| Mosaic | Flat 3–4 column dump, all sections visible | Jump bar + collapsed groups (Layout & Opening open) | [before/mosaic.png](evidence/settings-audit-2026-11-05/before/mosaic.png) |
| Sites | 11 columns; footer essay | 8 columns + More… sheet (Pop-ups, Freeze, UA) | [before/sites.png](evidence/settings-audit-2026-11-05/before/sites.png) |
| Tabs & Memory | Paragraph under Sleeping tabs; 3 uneven columns | Learn more; balanced 2-col cards | [before/tabsMemory.png](evidence/settings-audit-2026-11-05/before/tabsMemory.png) |
| All Form panes | Green menu values (theme accent) | `.tint(.primary)` on forms + `.settingsMenuValueLabel()` on pickers; toggles keep accent | e.g. [before/general.png](evidence/settings-audit-2026-11-05/before/general.png) |
| General / Profiles / Privacy / Advanced | Caption walls under Search, profiles footer, filter lists, bridge | `SettingsLearnMore` one-line summaries | e.g. [before-round-2/privacy.png](evidence/settings-audit-2026-11-05/before-round-2/privacy.png) |
| Extensions | Accent “Running” on status line | Secondary caption + monochrome symbol; load toggle stays accent | [before-round-2/extensions.png](evidence/settings-audit-2026-11-05/before-round-2/extensions.png) |

---

## Aesthetic issue log (prioritized)

| Sev | Pane | Issue | Fix in PR / follow-up | Evidence |
|-----|------|-------|----------------------|----------|
| P1 | Sites | Subtitle claimed per-site camera | **Fixed** copy in `SettingsViews` | before vs after sites PNG |
| P1 | Mosaic | Unscannable 3-col prefs dump | **Fixed** disclosures + jump bar + 1 col | mosaic before/after |
| P2 | Sites | Table too wide | **Fixed** More… sheet | sites after |
| P2 | Tabs & Memory | README wall under freeze | **Fixed** `SettingsLearnMore` | tabsMemory after |
| P2 | Global | Green picker values | **Fixed** form tint + picker modifier | general/appearance after |
| P2 | Global | 4-col masonry | **Fixed** `maxColumns: 2` (Mosaic `1`) | privacy/extensions after |
| P2 | Privacy | Filter list footer essays | **Fixed** `SettingsLearnMore` on list sections | privacy after / before-round-2 |
| P2 | Extensions | Many cards, accent “Running” | **Fixed** secondary status; density polish; **P3 residual** scroll with many folders | extensions after |
| P2 | General | Search/New Tab caption walls | **Fixed** `SettingsLearnMore` | general after |
| P2 | Profiles | Long profiles footer | **Fixed** `SettingsLearnMore` | profiles after |
| P3 | General | “Another browser is th…” truncation | **Fixed** stacked default-browser row + wrap | general after |
| P3 | Advanced | Long control-bridge disclaimer | **Fixed** `SettingsLearnMore` | advanced after |

---

## Functional / config inventory (unchanged scope)

Sidebar order matches `SettingsPane`: General, Appearance, Profiles, Tabs & Memory, Mosaic, Privacy & Blocking, Sites, Extensions, Shortcuts, Advanced (`paddle://settings/<pane>`).

| Pane | Control / area | Config key(s) | Status | Sev | Notes |
|------|----------------|---------------|--------|-----|-------|
| General | Startup, tabs, search, New Tab, trackpad | `onLaunch`, `externalLinks`, `newTab*`, `search*`, `swipeNavigation`, … | OK | Info | Bookmarks bar not in config.json |
| Appearance | Theme, chrome, accessibility | `theme`, `accentColor`, `darkMode`, … | OK | Info | |
| Profiles | Overrides | `profiles.json` | OK | Info | |
| Tabs & Memory | Sleep/freeze/memory | `tabFreeze*`, `tabSleep*`, `maxAwakeTabs`, … | OK | Info | |
| Mosaic | All `mosaic*` keys | `mosaic*` | OK | Info | Optional freeze/sleep keys via pickers |
| Privacy | Blocking, lists, history | `contentBlocking`, `filterLists`, … | OK | Info | |
| Sites | Per-host table + More sheet | `sites`, `siteUserAgents` | OK | Info | Pop-ups, Freeze, UA in sheet |
| Extensions | Folders, updates | `extensions`, `extensionToolbar`, … | OK | Info | |
| Shortcuts | Key map | `shortcuts` | OK | Info | |
| Advanced | Dev tools, bridge, tidy | `developerTools`, `controlBridge`, … | OK | Info | |
| — | On-demand extensions | `extensionsOnDemand` | Gap | P2 | File-only; README note |
| — | Site personas | `sitePersonas` | Gap | P2 | Search keyword only |

---

## Code changes (polish)

- `SettingsForm`: default `maxColumns: 2`; per-form `.tint(.primary)`; Mosaic uses `maxColumns: 1`.
- `SettingsLearnMore`, `settingsMenuValueLabel()`, `settingsAccentToggle()` in `SettingsModel+Keys.swift` / `SettingsViews.swift`.
- `MosaicPane.swift`: jump bar + `SettingsDisclosure` groups.
- `SitesPane.swift`: slimmer table, `siteMoreSheet`, Learn more footers.
- `TabsMemoryPane.swift`: Learn more + picker/toggle styling.
- `SettingsViews.swift`: Sites pane summary (camera fix retained).
- **Round 2:** `GeneralPane.swift` (Search/New Tab Learn more, default-browser layout), `ProfilesPane.swift`, `PrivacyPane.swift`, `ExtensionsPane.swift`, `ControlBridgeViews.swift`.
- **Extension update UX:** `ExtensionUpdateOutcome` + `lastOutcome` on `extension-sources.json` records; `extension-update-last.json` batch summary; Settings + Extensions menu read persisted outcomes ([evidence](evidence/extension-update-ux-2026-11-05/extensions-after-check.png)).

---

## Verification

- `swift test`: 1146 tests passed on this branch (after round 2 + extension update UX).
- Screenshots: Debug build Settings panes via control-bridge `window_snapshot` (round 2 refresh for general, profiles, privacy, extensions, advanced).
- User prefs: not modified (Settings navigation only for captures).
