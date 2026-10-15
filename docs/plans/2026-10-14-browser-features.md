# Browser features roadmap (2026-10-14)

Walker's list, plus the best ideas from Chrome, Firefox, Brave, Edge, Safari, Arc and Zen. Built in waves of at most
about 45 minutes. Each wave: spec, builder(s), two-lens review, then a check in the running debug build. Each wave is
committed locally; no notarized release until Walker asks (a signed `scripts/release.sh --install` without
`--notarize` is the cheap way to try a build in /Applications).

Status: approved 2026-10-14 (vertical tabs optional; extras Profiles, Spaces, Split view, Link preview as waves 6-9). Wave 1 committed (934594c). Wave 2 committed (6e66ff2). Wave 3 built and checked in the app 2026-10-15, uncommitted.

## Wave 1: tab foundations, rename, tab groups (horizontal strip)
Where from: Chrome, Firefox, Edge and Brave tab groups; Arc and Zen tab renaming.
- [x] Session model: a tab's `customTitle` and `groupID`, and a window's `groups` (id, name, color, collapsed), saved
  in session.json; PaddleCore tests.
- [x] Rename Tab: right-click > Rename Tab… or double-click the title, edited in place; empty restores the page title.
  It survives navigation and relaunch.
- [ ] Tab groups:
  - [x] Right-click a tab > Add Tab to New Group / Add to Group ▸.
  - [x] A group label in the strip (name and color). Clicking it collapses or expands the group.
  - [ ] Right-click the label: Rename, Color, Ungroup, Close Group, Move Group to New Window. (Built; only Color was checked in the app.)
  - [ ] A tab opened from a grouped tab joins its group, and dragging a tab moves it in or out of a group. (Dropping onto the label was checked; opening from a grouped tab and dragging out were not.)
  - [x] Group colors differ in brightness as well as hue, and the name is always shown, never color alone.
- Done when: a renamed tab and a two-group window survive a relaunch, collapse works, and drag in and out works.

## Wave 2: vertical tabs (optional; horizontal stays the default)
Where from: Edge, Brave and Firefox vertical tabs; the Arc and Zen sidebar.
- [x] New `tabLayout` key ("horizontal" | "vertical"); View > Vertical Tabs (rebindable `toggleVerticalTabs`);
  also in Settings > Appearance. (The picker is in Settings > General until Wave 4 adds Appearance.)
- [ ] Sidebar contents:
  - [x] Pinned tabs as an icon grid at the top (Arc favorites / Zen essentials).
  - [x] Groups as collapsible sections.
  - [x] Tab rows with close, sound and asleep state. (The sound button wasn't seen in the app.)
  - [x] A New Tab row. (It's a + button in the sidebar's top row.)
  - [ ] Drag to reorder, middle-click to close, and the same right-click menus as the strip. (The menus were checked; dragging and middle-click in the sidebar were not.)
- [x] Sidebar width can be dragged and is remembered. It can collapse to icons only (Edge).
- [x] Window layout: the traffic lights and toolbar form the top row, and the tab strip row goes away.
- Done when: switching layouts keeps the tabs, groups and selection, and both layouts pass the Wave 1 checks.

## Wave 3: New Tab page with pinned sites
Where from: Chrome shortcuts, Firefox top sites, Safari favorites, Brave speed dial.
- [x] Pinned-site tiles (favicon and name) on the blank new tab page, saved in a plain file, `newtab.json`.
  - [ ] Add one with a "+" tile, or from the ≡ menu or a page's right-click menu (Add to New Tab Page). (The + tile
    and Bookmarks > Add Page to New Tab Page were checked, and the ≡ menu shows the item. A web page's right-click menu
    doesn't have it: Paddle has no hook into WebKit's page menu yet.)
  - [x] Right-click a tile to Edit or Remove it; drag to reorder.
- [x] An optional "Frequently visited" row built from history, with a remove button per site. (Remove is Don't Show
  This Site in the tile's right-click menu; each tile opens the site's front page.)
- [x] Keyboard: Tab moves through the tiles and Return opens one; the address field keeps focus at first.
- Done when: tiles are added, edited, reordered and removed, and they survive a relaunch.

## Wave 4: themes and accessibility
Where from: Chrome themes, Arc and Zen colors, Firefox and macOS accessibility.
- [ ] Settings > Appearance pane:
  - [ ] Paddle's light/dark (System / Light / Dark).
  - [ ] Accent and tint presets, plus a custom color.
  - [ ] Tint strength for the tab strip and toolbar.
  - [ ] A high-contrast selected tab.
  - [ ] Interface text size.
  - [ ] Default page zoom.
  - [ ] Minimum page font size.
  - [ ] Reduce motion and transparency (follows macOS, with an override).
- [ ] Theme files in `themes/<name>.json` (tab strip, toolbar, selected tab, accent, new tab background) and a
  `theme` key in config.json. The built-in themes are measured: text contrast at least 4.5:1, and selected and
  unselected tabs differ in brightness.
- [ ] A group or window color tint (Arc spaces); optional, after the rest.
- Done when: each built-in theme passes the contrast measurement, and changing a theme applies live to every window.

## Wave 5: developer tools (extends what exists)
Exists today: Web Inspector (⌥⌘I), right-click > Inspect Element, View Source (⌥⌘U), and the `developerTools` key.
- [ ] A Develop menu, shown when `developerTools` is on. It holds:
  - [ ] Show Web Inspector.
  - [ ] JavaScript Console (⌥⌘C).
  - [ ] Element picker (⇧⌘C).
  - [ ] Page Source.
  - [ ] Reload Without Cache.
  - [ ] Reload Without Content Blockers (this page, once).
  - [ ] Disable Caches (this session).
  - [ ] Responsive Design Mode (device widths and user agents).
  - [ ] Inspect an extension's background page.
- [ ] A ≡ menu entry: Developer Tools.
- Every private inspector call is behind a `responds(to:)` check; if it's missing, the item is hidden.
- Done when: each item works on a real page, and the items hide cleanly when `developerTools` is off.

## Waves 6-9: chosen extras (Walker, 2026-10-14)
- [ ] Wave 6, Profiles: separate cookies and logins per profile, for example Work and Personal (Safari profiles,
  Firefox containers). Each profile has its own `WKWebsiteDataStore(forIdentifier:)`, history and session.
- [ ] Wave 7, Spaces: named sets of tabs with their own pinned tabs and color, switched with ⌃1–9 (Arc, Zen, Edge).
  Built on groups (Wave 1) and the sidebar (Wave 2).
- [ ] Wave 8, Split view: two tabs side by side in one window, with a draggable divider (Chrome, Arc, Zen, Edge).
- [ ] Wave 9, Link preview: ⌥-click shows a link in a floating preview over the page, which can then become a tab
  (Arc Peek, Zen Glance).

Not chosen for now: command palette (⌘K), reader mode, auto-archive, per-site boosts, full-page screenshots, sidebar
web panels.
