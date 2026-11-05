# Settings audit (2026-11-05, UI polish pass)

**App (after screenshots):** Debug build from this branch (`build/DerivedData.noindex/…/Paddle.app`).  
**Reference install:** `/Applications/Paddle.app` **0.1.157 (157)** (notarized).  
**Evidence:** [`docs/evidence/settings-audit-2026-11-05/`](evidence/settings-audit-2026-11-05/) — **after** polish at pane root; **before** at [`before/`](evidence/settings-audit-2026-11-05/before/).  
**Method:** Code inventory + live Settings navigation; config cross-check via `paddle-mcp` `read_config` where needed.

---

## Executive summary

**Aesthetics (primary)**  
Settings had a consistent functional surface but poor *scanability*: four-column masonry dumps (especially Mosaic, Privacy, Extensions), menu values tinted in theme accent green, and multi-paragraph “README walls” in Sites and Tabs & Memory. This PR lands shared form rhythm (max two columns by default, Mosaic single column + jump bar + collapsible groups), primary-colored menu values, `SettingsLearnMore` footers, a slimmer Sites table with a **More…** sheet for rare columns, and the Sites subtitle fix (no false per-site camera claim).

**Function / config (secondary)**  
All ten panes map to `PaddleConfig` / README keys as before. Remaining **config gaps** (unchanged by polish): `extensionsOnDemand` and `sitePersonas` have no Settings controls (README notes file-only for on-demand). No crashes or blank panes observed.

**Top aesthetic debts after this PR (P2–P3)**  
Privacy and Extensions still use long `SettingsCaption` blocks under filter lists and extension cards; General Search/New Tab footers could move to Learn more; Extensions grid is still one card per extension (dense but intentional).

---

## UI/UX aesthetics scorecard (all 10 panes)

Severity: **P0** broken · **P1** misleading/harmful · **P2** polish gap · **P3** nice-to-have · **Fixed** addressed in this PR.

| Pane | Hierarchy / grouping | Density / scroll | Typography / copy | Accent discipline | Form consistency | Table / list | Empty states | A11y notes | Evidence (after) |
|------|----------------------|------------------|-------------------|-------------------|------------------|--------------|--------------|------------|------------------|
| General | Good section cards | OK 2-col | Search footers still 2 lines | **Fixed** menu values | Baseline | N/A | Default browser row truncates when narrow | Toggles distinct from values | [general.png](evidence/settings-audit-2026-11-05/general.png) |
| Appearance | Clear Theme / Windows | OK | OK | **Fixed** pickers | Matches General | N/A | Missing theme shows “not found” | Segmented appearance OK | [appearance.png](evidence/settings-audit-2026-11-05/appearance.png) |
| Profiles | Per-profile sections | Long footer caption | One essay remains | OK | 2-col masonry | N/A | loadError message | Rename fields labeled | [profiles.png](evidence/settings-audit-2026-11-05/profiles.png) |
| Tabs & Memory | 4 section cards | **Fixed** essay → Learn more | **Fixed** | **Fixed** | **Fixed** 2-col (was 3 orphan cols) | N/A | Memory readout clear | Sleep custom field labeled | [tabsMemory.png](evidence/settings-audit-2026-11-05/tabsMemory.png) |
| Mosaic | **Fixed** jump + disclosures | **Fixed** collapsed groups | **Fixed** Learn more | **Fixed** | **Fixed** 1-col stack | N/A | N/A | Jump bar horizontal scroll | [mosaic.png](evidence/settings-audit-2026-11-05/mosaic.png) |
| Privacy | Named sections | **Fixed** 2-col max | Long list footers remain (P2) | **Fixed** pickers | **Fixed** rhythm | Filter list readable | Empty rules message | Fraud toggle labeled | [privacy.png](evidence/settings-audit-2026-11-05/privacy.png) |
| Sites | Table + session | **Fixed** fewer columns | **Fixed** subtitle + footers | **Fixed** More button primary | Custom layout | **Fixed** More… sheet | Empty table overlay | Table combine a11y | [sites.png](evidence/settings-audit-2026-11-05/sites.png) |
| Extensions | Per-extension cards | Still dense (P2) | Details disclosure OK | Status “Running” still accent (P3) | **Fixed** 2-col cards | Card scan OK | No extensions message | Busy progress announced | [extensions.png](evidence/settings-audit-2026-11-05/extensions.png) |
| Shortcuts | Single list section | OK | OK | OK | OK | List | N/A | Search in sidebar | [shortcuts.png](evidence/settings-audit-2026-11-05/shortcuts.png) |
| Advanced | 3 logical groups | **Fixed** 2-col | Bridge essay remains (P2) | **Fixed** | **Fixed** | N/A | Problems empty state | Setup command copy | [advanced.png](evidence/settings-audit-2026-11-05/advanced.png) |

### Before → after (high-signal)

| Pane | Before issue | After | Before PNG |
|------|----------------|-------|------------|
| Mosaic | Flat 3–4 column dump, all sections visible | Jump bar + collapsed groups (Layout & Opening open) | [before/mosaic.png](evidence/settings-audit-2026-11-05/before/mosaic.png) |
| Sites | 11 columns; footer essay | 8 columns + More… sheet (Pop-ups, Freeze, UA) | [before/sites.png](evidence/settings-audit-2026-11-05/before/sites.png) |
| Tabs & Memory | Paragraph under Sleeping tabs; 3 uneven columns | Learn more; balanced 2-col cards | [before/tabsMemory.png](evidence/settings-audit-2026-11-05/before/tabsMemory.png) |
| All Form panes | Green menu values (theme accent) | `.tint(.primary)` on forms + `.settingsMenuValueLabel()` on pickers; toggles keep accent | e.g. [before/general.png](evidence/settings-audit-2026-11-05/before/general.png) |

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
| P2 | Privacy | Filter list footer essays | Follow-up: Learn more on list sections | privacy after |
| P2 | Extensions | Many cards, accent “Running” | Follow-up: secondary label for status text | extensions after |
| P3 | General | “Another browser is th…” truncation | Wider min column or wrap | general after |
| P3 | Advanced | Long control-bridge disclaimer | Learn more disclosure | advanced after |

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

---

## Verification

- `swift test`: 1142 tests passed on this branch.
- Screenshots: Debug build Settings tab, post-polish (paths above).
- User prefs: not modified (navigation only).
