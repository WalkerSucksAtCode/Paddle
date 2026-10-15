# Browser features roadmap (2026-10-14)

Walker's list, plus the best ideas from Chrome, Firefox, Brave, Edge, Safari, Arc and Zen. Built in waves of at most
about 45 minutes. Each wave: spec, builder(s), two-lens review, then a check in the running debug build. Each wave is
committed locally; no notarized release until Walker asks (a signed `scripts/release.sh --install` without
`--notarize` is the cheap way to try a build in /Applications).

Status: approved 2026-10-14 (vertical tabs optional; extras Profiles, Spaces, Split view, Link preview as waves 6-9). Wave 1 committed (934594c). Wave 2 committed (6e66ff2). Wave 3 committed (967ea9a). Wave 4a committed (73c241c). Wave 4b built and checked in the app 2026-10-15, uncommitted.

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
Where from: Chrome themes, Arc and Zen colors, Firefox and macOS accessibility. Split in two (2026-10-15): the text
size control alone touches 72 fixed font sizes in 13 chrome files.

### Wave 4a: Appearance pane and accessibility
- [x] Settings > Appearance pane (`paddle://settings/appearance`), after General; the Tab layout picker moves there.
- [x] `appearance`: "system" | "light" | "dark" (Paddle's windows; pages' `prefers-color-scheme` follows).
- [ ] `highContrastTabs` (off): the selected tab gets a stronger fill and edge and a semibold title, in the strip and
  the sidebar. Measured: selected and unselected tabs differ clearly in brightness in light and dark. (Strip measured
  against the unselected strip: light fill 1.31 -> 1.86:1, edge 1.64 -> 6.29:1; dark fill 1.44 -> 2.31:1, edge 1.97 ->
  7.26:1. The sidebar with it on was not checked.)
- [ ] `interfaceTextSize`: "small" | "default" | "large" | "larger" scales the chrome's text and row heights (tab
  strip, sidebar, toolbar, bookmarks bar, suggestions, find bar, New Tab page, notices). Nothing clips at "larger".
  (Checked at "larger" and "small" in the strip, toolbar, sidebar and New Tab page, and after a relaunch. Not scaled
  yet: the extension toolbar buttons and the ≡ button.)
- [x] `defaultZoom` (1.0): pages without a site zoom open at it; Actual Size (⌘0) goes to it; a site zoom equal to it
  is dropped from `sites`.
- [x] `minimumFontSize` (0, off; 9-24 pt): WebKit's minimum font size, applied to open pages too.
- [ ] `reduceMotion` and `reduceTransparency`: "system" (follow macOS) | "always". Reduced transparency makes the
  chrome solid instead of the bar material; reduced motion turns off the chrome's animations. (Built and reviewed in
  code; neither difference was measurable in the app: the materials sit over flat backgrounds, and the animations are
  0.15-0.2 s.)
- Done when: each control applies live to every open window and survives a relaunch.

### Wave 4b: themes and tint
- [x] `theme` key: "default" (today's look) or a built-in: Graphite, Ocean, Forest, Dusk, Sand, High Contrast, each
  with light and dark colors for tab strip (and sidebar), toolbar, selected tab, text, secondary text, accent and New
  Tab background. A PaddleCore test measures every built-in in both modes: text at least 4.5:1 on all four
  backgrounds, secondary text at least 4.5:1 on strip, toolbar and New Tab background, accent at least 3:1, and the
  selected tab at least 1.4:1 against the strip (3:1 for High Contrast). The palettes were measured before building
  (2026-10-15): text 8.4:1 or more everywhere, selected tab 1.43-1.85:1 (High Contrast 3.36 and 4.12). In the app all
  twelve theme/mode pairs drew strip, selected tab, toolbar and New Tab background within 6 of the palette per channel
  (most within 2), and Ocean dark's tab titles measured 9.2:1 and 17.1:1 at full pixel density.
- [x] Theme files: `themes/<name>.json` as `{"light": {...}, "dark": {...}}` with the same seven `#rrggbb` keys; the
  file's name is the theme's. A missing or bad color is a warning in the config notice and that surface keeps the
  default look; a file that doesn't parse is a warning and the theme falls back to Default. A user theme below the
  contrast rules is still applied, with a warning naming the pair and its ratio. Reload Config re-reads the folder.
- [ ] `accentColor`: "system", a preset (blue, purple, pink, red, orange, yellow, green, graphite) or `#rrggbb`;
  overrides the theme's accent (progress bar, focus rings, the chrome's controls). (A preset was checked in the app:
  yellow over Ocean, with black text on the highlighted suggestion. A custom `#rrggbb` only by unit tests.)
- [x] `chromeTint` ("none", a preset or `#rrggbb`) and `chromeTintStrength` (0-100, default 25): the tint is blended
  over the strip and toolbar colors (the theme's, or today's look). The strength is capped so text stays at least
  4.5:1; Settings says when it was capped. (Yellow at 100 % on the dark default look drew at the computed 26 % cap.)
- [ ] Settings > Appearance, a Theme section: theme picker (built-ins, then files) and Open Themes Folder; accent and
  tint pickers whose entries carry their names (never a swatch alone) plus a custom color well; the strength slider.
  (Seen in the app, with every theme warning listed. The custom color well, which saves 0.4 s after the color settles,
  and the "Capped at N %" caption were not exercised.)
- [ ] Deferred: a group or window color tint (Arc spaces).
- Done when: each built-in theme passes the contrast test and measures the same in the running app, a theme or tint
  change applies live to every window, and a broken theme file shows a warning and falls back.

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
