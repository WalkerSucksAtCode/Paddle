# Settings UX audit — research-backed (2026-11-05)

**Prior audit (functional + polish):** [`settings-audit.md`](settings-audit.md)  
**App for evidence:** Debug build from branch `cursor/settings-ui-audit-a3f0` (`build/DerivedData.noindex/…/Paddle.app`). Walker’s daily driver remains **`/Applications/Paddle.app` 0.1.157** — screenshots here are branch UI, not notarized unless noted.  
**Evidence:** [`docs/evidence/settings-ux-audit-2026-11-05/`](evidence/settings-ux-audit-2026-11-05/)

---

## Research summary (lenses applied)

| Source | Pattern | Paddle fit |
|--------|---------|--------------|
| **macOS / Apple** ([Form](https://developer.apple.com/documentation/swiftui/form), grouped style) | Vertical **stack of grouped sections**; labels and controls aligned; **modeless instant apply** (no Save). | `SettingsForm` uses `.formStyle(.grouped)` per section card; saves on toggle/picker change. This pass: **single-column stack** (`maxColumns: 1` + `VStack`) on dense panes (Privacy, Profiles, Tabs & Memory, Advanced) instead of two-column masonry. |
| **Firefox Acorn** (Browser settings) | **Progressive disclosure** (sub-pages, dialogs, collapses); important first; **short caption + Learn more**; search-first discovery. | Mosaic **Advanced tuning** collapsed bucket; sidebar **match hints**; `SettingsLearnMore` extended (e.g. Tabs audio). Sites **More…** sheet already matches “box affordance”. |
| **Chromium Options** | Intelligent defaults; **Basics → Minor → Under the Hood**; don’t mix everyday and esoteric. | General/Appearance stay 2-col for low-density basics; Mosaic Layout/Opening exposed; bridge/dev in **Advanced** only. |
| **Craft (Paddle)** | Hierarchy, rhythm, accent only on **state change**, designed outcomes. | Pane header icon **neutral** (accent reserved for toggles/actions); extension **lastOutcome** bar for designed success/wait/fail. |

**Safari / Arc (live comparison, same session):** System Settings and Arc use a single scrolling column of grouped rows; Arc buries per-site rules behind search. Paddle’s in-tab sidebar + pane header is closer to Firefox/Chrome *options in a tab* than macOS System Settings — acceptable; improving **search hints** and **column rhythm** matters more than cloning Apple’s window chrome.

---

## Principles shortlist (Paddle Settings)

1. **One primary column** of grouped sections on dense panes; at most two columns only when cards are short (General, Appearance).
2. **Instant apply** — every control writes through `SettingsModel`; no Apply except config banner edge cases.
3. **Progressive disclosure** — Mosaic/Advanced power knobs collapsed by default; Learn more for paragraphs.
4. **Search-first** — sidebar filter with **why** a pane matched; empty state suggests query shapes.
5. **Accent discipline** — green/accent on toggles and primary actions; menu values and headers **primary/secondary** neutrals.
6. **Caption voice** — one-line summary visible; detail in Learn more or sheet (Firefox Acorn pattern).
7. **Basics before hood** — everyday (startup, blocking on/off, extensions load) before Mosaic dividers and control bridge.
8. **Designed states** — empty, waiting, success copy as explicit as extension update outcomes (target for Sites table status, Privacy list empty).
9. **Tables scan first** — Sites: few primary columns; rare fields in **More…** (keep).
10. **Modeless depth** — sheets (Sites More, theme builder) over navigation stacks where possible.

---

## 10-pane scorecard

Severity: **P0** broken · **P1** harmful/confusing · **P2** polish · **P3** nice · **Fixed** this pass.

| Pane | macOS grouped rhythm | Progressive disclosure | Search / IA | Accent / hierarchy | Designed states | Evidence |
|------|---------------------|------------------------|-------------|-------------------|-----------------|----------|
| General | P2 two-col OK for density | **Fixed** Learn more footers | Keywords rich | **Fixed** menu tint | Default browser wrap | [general.png](evidence/settings-ux-audit-2026-11-05/general.png) |
| Appearance | P2 two-col OK | OK | OK | **Fixed** pickers | Theme missing message OK | [appearance.png](evidence/settings-ux-audit-2026-11-05/appearance.png) |
| Profiles | **Fixed** 1-col stack | Learn more footer | OK | OK | loadError inline | [profiles.png](evidence/settings-ux-audit-2026-11-05/profiles.png) |
| Tabs & Memory | **Fixed** 1-col stack | **Fixed** audio → Learn more | OK | **Fixed** | Memory readout OK | [tabsMemory.png](evidence/settings-ux-audit-2026-11-05/tabsMemory.png) |
| Mosaic | **Fixed** 1-col stack | **Fixed** Advanced tuning bucket | Jump bar trimmed | OK | P3 strip shading caption | [mosaic.png](evidence/settings-ux-audit-2026-11-05/mosaic.png) |
| Privacy | **Fixed** 1-col stack | Learn more on lists | OK | **Fixed** | Filter empty caption OK | [privacy.png](evidence/settings-ux-audit-2026-11-05/privacy.png) |
| Sites | Custom table (OK) | More… sheet | Per-host search OK | More button primary | Session/status P2 | [sites.png](evidence/settings-ux-audit-2026-11-05/sites.png) |
| Extensions | 1-col when many | Details disclosure | keywords OK | Status secondary | **Fixed** durable outcomes | [extensions.png](evidence/settings-ux-audit-2026-11-05/extensions.png) |
| Shortcuts | Table (OK) | — | Command search OK | OK | Clash warnings OK | [shortcuts.png](evidence/settings-ux-audit-2026-11-05/shortcuts.png) |
| Advanced | **Fixed** 1-col stack | Bridge Learn more | Correctly deep | Bridge toggles accent | Problems empty OK | [advanced.png](evidence/settings-ux-audit-2026-11-05/advanced.png) |

**Sidebar search:** [search-hints.png](evidence/settings-ux-audit-2026-11-05/search-hints.png) — match hints + improved empty guidance (**Fixed** this pass).

---

## Prioritized backlog (pattern tags)

| Sev | Item | Pattern tags | Status |
|-----|------|--------------|--------|
| P2 | Dense panes on 2-col masonry | `#macOS-grouped` `#chromium-depth` | **Fixed** — 1-col stack Privacy, Profiles, Tabs, Advanced |
| P2 | Mosaic esoteric wall | `#firefox-disclosure` `#chromium-hood` | **Fixed** — Advanced tuning disclosure |
| P2 | Search doesn’t explain matches | `#firefox-search` | **Fixed** — `matchHint` in sidebar |
| P2 | Pane header accent noise | `#craft-accent` | **Fixed** — neutral header icon |
| P2 | Sites session/status line plain | `#craft-states` | Open — raise to extension-outcome clarity |
| P3 | Mosaic inline SettingsCaption lines | `#firefox-learnmore` | Open — convert strip shading captions |
| P3 | Shortcuts pane visual parity with Form cards | `#macOS-grouped` | Open — table is fine functionally |
| P2 | `extensionsOnDemand` / `sitePersonas` no UI | `#chromium-defaults` | Out of scope (file/README) |

---

## Implemented this pass (before → after)

| Change | Before | After |
|--------|--------|-------|
| Form layout | Privacy/Profiles/Tabs/Advanced in 2-col masonry | Single-column grouped stack (`maxColumns: 1`, `VStack`) |
| Mosaic IA | Eight peer disclosure cards | Layout/Opening/Toolbars/Focus + one **Advanced tuning** block |
| Settings search | Pane title only | **Matches “keyword”** under title; richer empty hint |
| Pane header | Accent-tinted icon tile | Neutral primary icon on subtle gray tile |
| Tabs audio footer | Full caption paragraph | Learn more summary + detail |

Functional/config inventory unchanged — see [`settings-audit.md`](settings-audit.md).  
**Related:** extension update UX evidence in [`extension-update-ux-2026-11-05/`](../extension-update-ux-2026-11-05/).

---

## Verification

- `swift test`: 1146 passed (branch).
- Screenshots: Debug Paddle via control-bridge `window_snapshot`; navigation/search only.
