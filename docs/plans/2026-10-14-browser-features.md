# Browser features roadmap (2026-10-14)

Walker's list, plus the best ideas from Chrome, Firefox, Brave, Edge, Safari, Arc and Zen. Built in waves of at most
about 45 minutes. Each wave: spec, builder(s), two-lens review, then a check in the running debug build. Each wave is
committed locally; no notarized release until Walker asks (a signed `scripts/release.sh --install` without
`--notarize` is the cheap way to try a build in /Applications).

Status: approved 2026-10-14 (vertical tabs optional; extras Profiles, Spaces, Split view, Link preview as waves 6-9). Wave 1 committed (934594c). Wave 2 committed (6e66ff2). Wave 3 committed (967ea9a). Wave 4a committed (73c241c). Wave 4b committed (d21df2b). Wave 5 committed (22c132c). Wave 6a and 6b committed (0b81f01). Wave 7 built and checked in the app 2026-10-15, uncommitted.

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
Exists today: Web Inspector (⌥⌘I, View menu), right-click > Inspect Element, View Source (⌥⌘U), Reload Without Cache
(⌥⌘R), and the `developerTools` key. Probed 2026-10-15 on macOS 27: `_WKInspector` has `show`, `showConsole`,
`toggleElementSelection`, `isElementSelectionActive`; `WKWebView` has `_reloadWithoutContentBlockers`,
`_setOverrideDeviceScaleFactor:`; `WKWebExtensionContext` has `_backgroundWebView`. Nothing turns caches off for a
session (Web Inspector's Network tab has its own Disable Caches switch), so the menu empties them instead.
- [x] A Develop menu between Bookmarks and Tabs, present only while `developerTools` is on (it appears and goes away
  live). Rebindable action names in brackets:
  - [x] Show Web Inspector ⌥⌘I (`webInspector`, moved here from View). (The console item opened the same inspector.)
  - [x] Show JavaScript Console ⌥⌘C (`javaScriptConsole`).
  - [x] Start Element Selection ⇧⌘C (`elementSelection`); reads Stop Element Selection while it's on.
  - [x] Reload Without Content Blockers (`reloadWithoutContentBlockers`): this load only, the next one blocks again.
    (A local EasyList-matched script and doubleclick's loaded once, then were blocked on the next reload.)
  - [x] Empty Caches ⌥⌘E (`emptyCaches`): memory, disk and fetch caches of the window's data store (private windows
    their own); cookies, storage and history stay. (The WebKit cache folder went from 257 MB to 4 MB.)
  - [x] Responsive Design Mode ⌃⌘R (`responsiveDesignMode`), per tab, not saved: the page drawn at a device's size
    (always 1:1, so viewport, pixel ratio, fixed positioning and clicks are exact; a device bigger than the window
    scrolls: a scale effect broke hit-testing and WebKit's view scale misplaced fixed elements), centred on a plain
    backdrop, under a bar with a device picker (iPhone SE 375 x 667, iPhone 16 393 x 852, iPhone 16
    Pro Max 440 x 956, iPad mini 744 x 1133, iPad Air 820 x 1180, Laptop 1280 x 800; names and sizes, never icons
    alone), Rotate, a user agent picker (Paddle, Safari iPhone, Safari iPad, Chrome Android) and Close. The device's
    user agent wins over `siteUserAgents` and personas while it's on (`TabWebDelegate`), and the tab returns to its
    own when it's off. Changing the user agent reloads the page.
  - [x] Inspect Extension Background Page ▸, one entry per loaded extension with background content, by name.
  - View Source (⌥⌘U) and Reload Without Cache (⌥⌘R) stay in View: they aren't developer-only.
- [ ] The ≡ menu: a Developer Tools submenu with the same items, while `developerTools` is on. (Built; not opened in
  the app.)
- Every private call is behind a `responds(to:)` check; an item whose call is missing is hidden.
- README: the Develop menu, the action names, the `developerTools` row.
- Done when: each item works on a real page in the running app, extension background pages open in the inspector, and
  the menu and submenu disappear when `developerTools` is off.

## Waves 6-9: chosen extras (Walker, 2026-10-14)
- [ ] Wave 6, Profiles: separate cookies and logins per profile, for example Work and Personal (Safari profiles,
  Firefox containers). Split in two (2026-10-15); `WKWebsiteDataStore(forIdentifier:)`, `remove(forIdentifier:)` and
  `fetchAllDataStoreIdentifiers` were probed on macOS 27.

### Wave 6a: profiles with their own data
- [x] `profiles.json`: the profiles, each an id, a name and a symbol from a named list (Person, Work, Home, School,
  Tools, Games, Shopping, Health, Star, Leaf), never a color alone. The default profile ("Personal", renamable, not
  deletable) keeps today's data store, history and windows, so nothing moves on upgrade.
- [x] Data: each other profile gets `WKWebsiteDataStore(forIdentifier:)` (cookies, logins, storage, cache) and its
  own `profiles/<id>/history.sqlite`. Everything history feeds follows the window's profile: address suggestions, the
  History window, Clear History, the New Tab page's Frequently visited. Shared: bookmarks, New Tab pinned sites,
  config.json, block lists, favicons, downloads. Private windows stay as they are (one throwaway store).
  (Checked: a cookie and localStorage set in Work were absent in Personal; each profile's history.sqlite held only
  its own visit; Work's New Tab page showed only Work's frequent site. Suggestions, the History window and Clear
  History per profile were not exercised.)
- [x] Windows: a window belongs to one profile, saved in session.json (`profile` on the window) and restored into it.
  With more than one profile the toolbar shows the window's profile (symbol and name). File > New Window opens in the
  front window's profile; File > New Window in Profile ▸ lists them. A tab never moves between windows of different
  profiles (drops are refused; Move Group to New Window keeps the profile). (Checked: badge, relaunch back into the
  profile. The New Window in Profile submenu and tab moves between profiles were not exercised.)
- [x] Settings > Profiles: add (name and symbol), rename, change symbol, open a window, delete. (Checked all but
  changing the symbol. Deleting removed WebsiteDataStore/<id>, WebExtensions/<id> and profiles/<id>/.) Settings now
  reuses an open Settings tab only in a window of the same profile: before, a Work window landed on Personal's. Deleting asks first,
  closes the profile's windows, removes its data store and its profiles/<id>/ folder.
- Done when: a cookie set in one profile is absent in another, history stays separate, windows come back in their
  profile after a relaunch, and deleting a profile removes its data from disk.

### Wave 6b: extensions per profile (built together with 6a, Walker 2026-10-15)
- [x] One extension host per profile: its own `WKWebExtensionController` (`Configuration(identifier:)` with the
  profile's id; the default profile keeps `.default()`), whose extension pages use that profile's data store, so an
  extension's storage and logins are separate per profile (a password manager signs in per profile).
- [x] Which extensions run: the default profile as today (`extensions` in config.json); another profile starts with
  none and turns them on in Settings > Extensions, saved in profiles.json. The Settings pane, the Extensions menu and
  the toolbar show the front window's profile.
- [x] Shared, owned in one place: installed folders, updates, store installs and their sources. Per profile:
  permission decisions and extension storage. Private windows use the default profile's extensions, as today.
- Done when: an extension turned on in two profiles keeps separate storage (signed in in one, not the other), and an
  extension on only in Personal doesn't run in Work. (Checked with a test extension counting page loads in
  chrome.storage: Personal counted on while Work started from 1; off in Work it didn't run. Each profile's install
  prompt names it. Website notifications still work only in the default profile: WebKit serves them for the default
  data store only.)
- [ ] Wave 7, Spaces: named sets of tabs with their own pinned tabs and color, switched with ⌃1–9 (Arc, Zen, Edge).
  Built on groups (Wave 1) and the sidebar (Wave 2). Specified 2026-10-15:
  - [x] Per window. A space is a name, a symbol from a named list (Home, Work, Study, Code, Music, Games, Shopping,
    Travel, Reading, Star) and an optional tint (one of the named presets), with its own tabs, pinned tabs, groups
    and selected tab. A window starts with one space, "Main"; nothing about spaces shows until there is a second.
  - [x] Model: the window's `tabs`, `groups` and selection stay the active space's, so the strip, sidebar, ⌘1–9,
    next/previous tab and groups work unchanged; the other spaces are kept beside them, and an `allTabs` list (every
    space) serves the session, tab sleeping, memory, extensions (which see every tab of the window) and tab search.
  - [x] Saved in session.json; an older session.json opens as one space. (The active space's place is saved too:
    restore had put it first, so ⌃1 changed meaning after a relaunch.)
  - [x] Tabs menu, rebindable: Space 1-9 (⌃1-⌃9, `space1`-`space9`), Next Space and Previous Space (`nextSpace`,
    `previousSpace`, no default keys), New Space (`newSpace`, starts with a New Tab and switches to it), Edit Space…
    (`editSpace`: name, symbol, tint), Delete Space (`deleteSpace`: asks when it has tabs, which close into Reopen
    Closed Tab; never the last space), Move Tab to Space ▸.
  - [x] Switcher: in the horizontal layout, a button at the start of the tab strip with the space's symbol and name
    (a menu of spaces, New Space, Edit Space). In the sidebar, the space's symbol and name above its tabs and a row of
    space buttons at the bottom (each labelled with its name for VoiceOver and on hover; the active one by brightness).
  - [x] A space's tint tints its window's tab strip and toolbar while it is active (the Wave 4b blend and 4.5:1 cap),
    on top of the theme. Never the only cue: the name and symbol always show.
  - [x] Search Tabs (⇧⌘A) covers every space and switches space to show the chosen tab; an extension activating a
    tab in another space switches too. Links open in the space of the tab they came from; links from other apps in
    the front window's active space.
  - Done when: two spaces keep their own tabs, pins and groups through ⌃1/⌃2, the switcher and a relaunch; Move Tab
    to Space and Delete Space work; Search Tabs finds a tab in the other space; the tint applies and is capped.
    (Checked: ⌃1/⌃2 with a page focused (control shortcuts now reach the menu first), the Tabs menu, the sidebar row,
    two relaunches, Move Tab to Space, Delete Space with its alert and Cancel, ⇧⌘T after it, Search Tabs, and the
    blue tint measured at its 25 % blend. Not exercised: pins and groups inside a second space, Next/Previous Space,
    an extension activating a tab in another space, and a tint strong enough to be capped.)
- [ ] Wave 8, Split view: two tabs side by side in one window, with a draggable divider (Chrome, Arc, Zen, Edge).
- [ ] Wave 9, Link preview: ⌥-click shows a link in a floating preview over the page, which can then become a tab
  (Arc Peek, Zen Glance).

Not chosen for now: command palette (⌘K), reader mode, auto-archive, per-site boosts, full-page screenshots, sidebar
web panels.
