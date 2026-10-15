# Browser features roadmap (2026-10-14)

Walker's list, plus the best ideas from Chrome, Firefox, Brave, Edge, Safari, Arc and Zen. Built in waves of at most
about 45 minutes. Each wave: spec, builder(s), two-lens review, then a check in the running debug build. Each wave is
committed locally; no notarized release until Walker asks (a signed `scripts/release.sh --install` without
`--notarize` is the cheap way to try a build in /Applications).

Status: approved 2026-10-14 (vertical tabs optional; extras Profiles, Spaces, Split view, Link preview as waves 6-9). Wave 1 committed (934594c). Wave 2 committed (6e66ff2). Wave 3 committed (967ea9a). Wave 4a committed (73c241c). Wave 4b committed (d21df2b). Wave 5 committed (22c132c). Wave 6a and 6b committed (0b81f01). Wave 7 committed (206ff00). Wave 7b committed (d1c3f40). Wave 8 committed (da2b886). Wave 9 committed (see git log).

## Wave 1: tab foundations, rename, tab groups (horizontal strip)
Where from: Chrome, Firefox, Edge and Brave tab groups; Arc and Zen tab renaming.
- [x] Session model: a tab's `customTitle` and `groupID`, and a window's `groups` (id, name, color, collapsed), saved
  in session.json; PaddleCore tests.
- [x] Rename Tab: right-click > Rename Tab… or double-click the title, edited in place; empty restores the page title.
  It survives navigation and relaunch.
- [x] Tab groups:
  - [x] Right-click a tab > Add Tab to New Group / Add to Group ▸.
  - [x] A group label in the strip (name and color). Clicking it collapses or expands the group.
  - [x] Right-click the label: Rename, Color, Ungroup, Close Group, Move Group to New Window. (Color checked first;
    the rest, and New Tab in Group, 2026-10-15.)
  - [x] A tab opened from a grouped tab joins its group, and dragging a tab moves it in or out of a group. (Dropping
    onto the label was checked; 2026-10-15: a ⌘-clicked link from a grouped tab joined it, and dragging a tab past an
    ungrouped one took it out.)
  - [x] Group colors differ in brightness as well as hue, and the name is always shown, never color alone.
- Done when: a renamed tab and a two-group window survive a relaunch, collapse works, and drag in and out works.

## Wave 2: vertical tabs (optional; horizontal stays the default)
Where from: Edge, Brave and Firefox vertical tabs; the Arc and Zen sidebar.
- [x] New `tabLayout` key ("horizontal" | "vertical"); View > Vertical Tabs (rebindable `toggleVerticalTabs`);
  also in Settings > Appearance. (The picker is in Settings > General until Wave 4 adds Appearance.)
- [x] Sidebar contents:
  - [x] Pinned tabs as an icon grid at the top (Arc favorites / Zen essentials).
  - [x] Groups as collapsible sections.
  - [x] Tab rows with close, sound and asleep state. (The sound button wasn't seen in the app.)
  - [x] A New Tab row. (It's a + button in the sidebar's top row.)
  - [x] Drag to reorder, middle-click to close, and the same right-click menus as the strip. (The menus were checked;
    dragging and middle-click, 2026-10-15.)
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
- [x] `highContrastTabs` (off): the selected tab gets a stronger fill and edge and a semibold title, in the strip and
  the sidebar. Measured: selected and unselected tabs differ clearly in brightness in light and dark. (Strip measured
  against the unselected strip: light fill 1.31 -> 1.86:1, edge 1.64 -> 6.29:1; dark fill 1.44 -> 2.31:1, edge 1.97 ->
  7.26:1. Sidebar, dark, 2026-10-15: fill 1.44 -> 2.77:1, edge 2.77 -> 7.43:1, title semibold.)
- [x] `interfaceTextSize`: "small" | "default" | "large" | "larger" scales the chrome's text and row heights (tab
  strip, sidebar, toolbar, bookmarks bar, suggestions, find bar, New Tab page, notices). Nothing clips at "larger".
  (Checked at "larger" and "small" in the strip, toolbar, sidebar and New Tab page, and after a relaunch. The ≡,
  extensions overflow and extension action icons scale too since 2026-10-15: at "larger" the ≡ measured 12.1 -> 15.9
  pt wide and an extension icon 15.9 -> 20.4 pt tall.)
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
- [x] `accentColor`: "system", a preset (blue, purple, pink, red, orange, yellow, green, graphite) or `#rrggbb`;
  overrides the theme's accent (progress bar, focus rings, the chrome's controls). (A preset was checked in the app:
  yellow over Ocean, with black text on the highlighted suggestion. A custom #2e8b57, 2026-10-15: the highlighted
  suggestion measured (74, 137, 92), with black text.)
- [x] `chromeTint` ("none", a preset or `#rrggbb`) and `chromeTintStrength` (0-100, default 25): the tint is blended
  over the strip and toolbar colors (the theme's, or today's look). The strength is capped so text stays at least
  4.5:1; Settings says when it was capped. (Yellow at 100 % on the dark default look drew at the computed 26 % cap.)
- [x] Settings > Appearance, a Theme section: theme picker (built-ins, then files) and Open Themes Folder; accent and
  tint pickers whose entries carry their names (never a swatch alone) plus a custom color well; the strength slider.
  (Seen in the app, with every theme warning listed. 2026-10-15: #ffff00 at 100 % shows "Capped at 22 % so text
  stays readable", and the selected tab title measured 5.46:1 and the address text 6.54:1. Not exercised: the custom
  color well, which saves 0.4 s after the color settles.)
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
- [x] The ≡ menu: a Developer Tools submenu with the same items, while `developerTools` is on. (Opened in the app
  2026-10-15: the same seven items as the Develop menu.)
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
  its own visit; Work's New Tab page showed only Work's frequent site. 2026-10-15, in a second profile: address
  suggestions and the History window (and History menu) showed only its pages, and Clear History cleared only it.)
- [x] Windows: a window belongs to one profile, saved in session.json (`profile` on the window) and restored into it.
  With more than one profile the toolbar shows the window's profile (symbol and name). File > New Window opens in the
  front window's profile; File > New Window in Profile ▸ lists them. A tab never moves between windows of different
  profiles (drops are refused; Move Group to New Window keeps the profile). (Checked: badge, relaunch back into the
  profile; 2026-10-15: New Window in Profile. Not exercised: a refused drop of a tab onto another profile's
  window.)
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
    blue tint measured at its 25 % blend. 2026-10-15: a pin and a group inside a second space, through Next/Previous
    Space and a relaunch. A space tint can't reach the cap: it blends at a fixed 25 %, and the worst preset (yellow on
    the dark default look) keeps the selected title at 5.71:1. Not exercised: an extension activating a tab in
    another space.)
- [ ] Wave 7b, control bridge (Walker, 2026-10-15; before Split view): a local MCP server so Claude sessions can
  read and drive Paddle directly, instead of screenshots and synthetic clicks (which stop when the screen locks, can't
  press Return in the background, and miss menu rows). Off by default.
  - [x] Transport: Paddle listens on a Unix socket in its support folder's own `bridge/` folder (0700; the socket
    0600; the support folder's mode is left alone), never a TCP port, so no
    web page can reach it (no localhost/DNS-rebinding surface). A small `paddle-mcp` helper inside the app
    (Contents/Helpers, signed with it) speaks MCP over stdio and relays to the socket. Setup is one command, shown
    with a Copy button in Settings: `claude mcp add paddle -- /Applications/Paddle.app/Contents/Helpers/paddle-mcp`.
    MCP itself (initialize, tools/list, tools/call, ping) is hand-written in PaddleCore and unit-tested; no new
    dependency.
  - [x] Switch: `controlBridge` (false) in config.json and Settings > Advanced. On: the socket opens; off: it closes
    and connected clients are dropped. While a client is connected the toolbar shows "Claude connected" (text and
    symbol, not color), clickable to disconnect. (Checked: off by default, on and off live through Reload Config,
    the label in a window snapshot; 2026-10-15: Disconnect asks first and drops the session, which sees end-of-file,
    while an idle session stays connected past 75 s; the Settings section shows both switches, the setup command,
    the session count and the recent calls.)
  - [x] Read tools: `paddle_state` (windows with profile and spaces, tabs with id, title, URL, pinned, group, asleep,
    selected; app build; config warnings), `page_text` (a tab's visible text), `page_snapshot` (a tab's PNG through
    WebKit's own snapshot: no Screen Recording permission, works in the background or with the screen locked),
    `window_snapshot` (the window's own drawing, best effort), `read_config`, `logs` (Paddle's own log entries since a
    time, read in-process, which `log show` from a shell can't).
  - [x] Act tools: `open_url`, `select_tab`, `close_tab`, `reload_tab`, `wait_for_load`, `menu_action` (any menu
    command by its action name, with the menu's own validation: covers spaces, profiles, vertical tabs, Develop),
    `set_config` (through the same conflict-checked writer as Settings), and `run_js` (in an isolated content world,
    not the page's, returning JSON; http(s) pages only). menu_action refuses quit, the clipboard and file
    commands; set_config refuses controlBridge, the extension and search keys.
  - [x] Limits: private windows are invisible to the bridge (not listed, not reachable). No tool reads cookies,
    passwords, the keychain, downloads or files outside Paddle's support folder. Page text and script results are
    labelled as untrusted page content in tool results. Every call is logged; Settings shows the last 50.
    (Build review 2026-10-15: `run_js` can't meet "no cookies or passwords" with a JS guard alone; a script reaches
    what page scripts can. Walker's call: `run_js` sits behind its own switch, `controlBridgeScripts` (Allow page
    scripts), off by default and changeable only in Settings or config.json; it keeps the guard and the redaction.
    Checked 2026-10-15 with a private window in front: paddle_state listed only the normal window, open_url opened
    there, and window_snapshot drew it.)
  - Done when: from a Claude Code session, with Paddle in the background and the screen locked, the tools list
    tabs, snapshot a page, read its text, run a menu command and a config change, and read Paddle's logs; with the
    switch off there is no socket; `lsof` shows Paddle on no TCP port; private windows never appear. (Checked with a
    stdio MCP client through `paddle-mcp`, Paddle in the background: all of it, plus file:/javascript: URLs refused,
    document.cookie blocked and a cookie-equal value redacted. Not checked with the screen locked.)
- [ ] Wave 8, Split view: two tabs side by side in one window, with a draggable divider (Chrome, Arc, Zen, Edge).
  Specified 2026-10-15:
  - [x] A split pairs two adjacent tabs of the same space (never pinned; both in the same group or none). Selecting
    either shows both, left and right of a divider. The selected tab is the focused side: the address field, toolbar,
    find bar, zoom, Develop menu, Responsive Design Mode and the bridge's "selected" all follow it unchanged; clicking
    into the other side focuses it. The focused side has a two-tone edge while split (2 pt dark outside, 1 pt light
    inside, so it shows on light and dark pages; brightness, not hue). (Checked: clicking the right pane moved the
    bridge's "selected" to it; the dark edge measured 115 against the white page's 255. Not distinguished: the address
    field, since both probe pages share a host.)
  - [ ] Both sides count as visible: neither sleeps or freezes as a background tab, and both report as visible to
    extensions (the focused one is the active tab). (Checked: both stay awake through Sleep Background Tabs and a
    relaunch. Not checked: what extensions see.)
  - [x] Divider: a 6 pt gap in the chrome colour with a grip. Drag to resize (each side at least 25 % and 320 pt),
    double-click for 50/50; the ratio is kept per split. Narrower than 640 pt the window shows only the focused side
    until it is wide enough again. (Checked: a drag to 1120 / 602 pt, a double-click back to 861 / 861; a drag hard
    left stops the left side at 317 pt (320 less half the divider); with 560 pt of content only the focused side
    shows, 559 pt wide.)
  - [x] Making and ending one: Tabs > Split View (`toggleSplitView`, ⌃⌘\): with one tab it splits with the next tab
    in the strip (or a new New Tab when there is none); in a split it ends the split and keeps the focused tab.
    A tab's right-click menu: "Split with Current Tab" (pairs it with the selected tab) and "End Split". Tabs > Swap
    Sides (`swapSplitSides`) and Focus Other Side (`focusOtherSplitSide`, no default key). Closing,
    pinning, moving to another window or space, or grouping apart one side ends the split. (Checked through the
    bridge: Split View makes one, Swap Sides swaps pages and strip order and keeps focus, closing one side ends it.
    2026-10-15: Focus Other Side, and ending by pin, by Move Tab to Space and by grouping one side apart; with the
    last tab focused, Split View makes a New Tab for the right side; the tab right-click Split with Current Tab and
    End Split. Swapping moves both web views to new hosts, so each page sees one brief 0 × 0 resize.)
  - [x] Strip and sidebar: the two tabs sit together with a split symbol (rectangle.split.2x1) on the pair and a
    shared bracket underline; both look selected when the split shows, the focused one with the stronger edge.
    (Checked in the strip and, 2026-10-15, the sidebar. Fixed then: switching layout during a split left both panes
    blank, since the outgoing panes took the pages with them; both sides now take them back once the switch settles,
    measured lit through three switches.)
  - [x] Saved in session.json with each space's tabs (pair and ratio); older files have no splits. (Checked: a
    relaunch keeps the pair with both sides awake; unit tests cover old files and bad entries.)
  - Done when: a split shows two pages side by side with the divider dragging and resetting, focus moves the address
    field between sides, both sides stay awake, the split survives a relaunch, and closing one side ends it.
- [ ] Wave 9, Link preview: ⌥-click shows a link in a floating preview over the page, which can then become a tab
  (Arc Peek, Zen Glance). Specified 2026-10-15:
  - [x] Opening: a real ⌥-click on a link (any frame, including target=_blank links) opens it in a preview instead of
    following it; the page underneath stays where it is. Only real clicks count (`_isUserInitiated`, as for ⌘-click),
    so a page can't open previews by faking one. The page's right-click menu on a link gains "Preview Link", added
    through WebKit's private `_webView:getContextMenuFromProposedMenu:…` with the link WebKit hit-tested for that menu
    (a WKWebView subclass's `willOpenMenu` sees a right-mouse-up and only the last hovered link). A page that handles
    ⌥-click itself keeps its behaviour (most routers leave modified clicks to the browser). `linkPreview` (true) in
    config.json and Settings > Tabs & Memory; off, ⌥-click follows the link as it does today. (Checked: a real ⌥-click
    and Preview Link open it with the page underneath unmoved; a script's ⌥-click only navigates; off, ⌥-click
    follows the link; the Settings toggle shows under Tabs & Memory > Link preview.)
  - [x] The preview: one per window, a card over the content area (over both sides of a split), inset 5 % (at least
    16 pt) with rounded corners and a shadow, the page behind darkened (brightness, not hue). A header in the chrome
    colours shows the page's icon, its host (always, first: the address field shows the tab underneath, and a page
    can title itself anything) and title, a progress line, and buttons: Open as Tab, Open in Split View, Copy Link,
    Close. The address field and toolbar keep showing the tab underneath. The keyboard goes to the preview while it
    shows and back to the tab when it closes. The link status bubble shows the preview's links inside the card; the
    tab's own is hidden meanwhile, since the page underneath still gets mouse moves through the card. (Checked:
    backdrop 152 over a white page, the 40 % expected 153; the card edge steps from 255 to about 125; Escape went to
    the preview; 2026-10-15: over both sides of a split, the progress line on a slow page, Copy Link.)
  - [ ] Inside it: links navigate the preview; a ⌥-click there navigates it too (no preview in a preview); ⌘-click
    and popups open tabs after the tab underneath; swipe back works as in a tab; downloads go to Downloads, and a
    preview that only downloaded closes. (Checked: ⌥-click navigates the preview; ⌘-click opens a background tab
    beside the tab underneath; 2026-10-15: a popup opens as a tab right after the tab underneath, a download link
    saves to Downloads with the preview kept, and previewing a file's URL downloads it and closes the preview. Not
    checked: swipe. A popup from a preview is selected, which closes the preview, so a sign-in popup loses its
    opener page.)
  - [ ] Becoming a tab: Open as Tab (`openLinkPreviewAsTab`, ⇧⌘Return) puts the preview's own web view in a new tab
    after the one underneath and selects it, with no reload (scroll, form input, history kept). Open in Split View
    does the same and splits it with the tab underneath (preview on the right); the button hides when that tab is
    pinned or already split. (Checked with the buttons: the page's load time unchanged and full width; the split
    861 / 861 with the preview on the right and focused. Fixed on the way: the fading card took the page back.
    2026-10-15: the button is hidden over a pinned tab and over a split. Open bug: a real ⇧⌘Return with Paddle in
    front makes the tab but leaves its page out of the window (viewport stays the card's 900 x 619, the pane blank);
    the same command through the bridge's menu_action, Paddle in the background, works. Mechanism not found yet.)
  - [x] Closing: Escape (when the page doesn't use it; it reaches Paddle as cancelOperation, not a menu key, so site
    dialogs keep their Escape), the Close button or `closeLinkPreview` (no default key), a click on the darkened
    page, selecting another tab or space, or closing the tab underneath. A closed preview drops its web view and goes
    nowhere (not Reopen Closed Tab). (Checked: Escape closes it, and a page that takes Escape keeps it open; Close,
    the backdrop and closeLinkPreview each close it, one WebContent process fewer each time; 2026-10-15: selecting
    another tab and switching space each close it.)
  - [x] Data: the preview uses its window's profile and data store; private windows' previews stay private and record
    nothing. In normal windows its pages go into history like any visit. Content blocking, user scripts and
    extensions' content scripts run in it; extensions' tab APIs see it only once it is a tab. Not saved in the
    session. (Checked: a private window's preview left no history row, normal previews did; the probe's ad script
    blocked in the preview; an open preview absent from session.json and sessions/ after quitting; 2026-10-15: in a
    second profile the preview read that profile's cookie and storage and its page went into that profile's history.
    Not checked: extensions.)
  - [x] Control bridge: `paddle_state` reports each window's preview (URL, title); `window_snapshot` draws it over the
    page; `open_url` gains `"in": "preview"` (refused while `linkPreview` is off); `openLinkPreviewAsTab` and
    `closeLinkPreview` run through `menu_action`. (Checked: all of them; the snapshot draws the backdrop and page but
    not the card's header, which the backdrop covers.)
  - Done when: a real ⌥-click opens a preview and the page underneath stays put; Open as Tab keeps the page without
    reloading (the probe page's load time unchanged); Open in Split View makes a split; Escape, the backdrop and Close
    each close it, and the WebContent process count returns to what it was; a script's fake ⌥-click opens nothing;
    with `linkPreview` off ⌥-click follows the link; a private window's preview adds no history row; the darkened
    backdrop and card edge are measured, not judged by eye.

Not chosen for now: command palette (⌘K), reader mode, auto-archive, per-site boosts, full-page screenshots, sidebar
web panels.
