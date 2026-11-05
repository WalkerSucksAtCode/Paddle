# Paddle

Personal macOS browser on the system WebKit (`WKWebView`). Config is plain files. Idle background tabs freeze, then sleep.

It identifies as the installed Safari. EasyList and EasyPrivacy compile to WebKit content-blocker lists. Long-form docs: [`docs/passkeys.md`](docs/passkeys.md), [`docs/measurements.md`](docs/measurements.md).

Config, filters, userscripts and themes live in `~/Library/Application Support/Paddle/` (Paddle > Open Config Folder). Edit, then Paddle > Reload Config (⌥⌘,). Settings (⌘,) writes `config.json`.

## Features

- **Sleep.** A background tab freezes after 2 idle minutes (JS stops, page stays in RAM) and sleeps after 5, or when more than 8 tabs are awake, or under memory pressure. Sound, camera, mic and Picture in Picture keep a tab awake; muted sound still counts, silent autoplay video does not. Restored sessions wake only the visible tab. The toolbar memory button lists tabs and the rest of the process (extensions, GPU, Networking, helpers).
- **Compatibility.** Popups and sign-in windows open as tabs with `window.opener`. Downloads, uploads, camera/mic, HTTP login, full screen and Web Inspector work. Responsive Design Mode (⌃⌘R) is 1:1 per tab, not saved. A click-opened window becomes a tab; a script-opened one is held unseen (file to Downloads, page offered as Pop-up blocked). `mailto:` and `zoommtg:` open the app; a page that starts one without a click is asked first.
- **Tabs.** Side buttons go back/forward. Rename from the tab menu or by double-click. Chrome-style groups (collapse, nine colors, drag in/out; pins cannot join). Vertical tabs move the strip into a sidebar. Spaces are named tab sets per window (⌃1–⌃9). Mosaic tiles several tabs of a space; Freeform lets panes overlap. Pinned tabs cannot join a Mosaic. Mute from the speaker on the tab (⌃⌘M). Picture in Picture (⌃⌘P) uses the system window; DRM or a cross-origin iframe player may refuse. Print, Save as `.webarchive`, View Source (current DOM).
- **Chrome.** Settings > Appearance: light/dark/system, text size of Paddle's UI, themes, accent, tint (capped for contrast), high-contrast selected tab, page zoom, minimum font size, reduce motion/transparency.
- **Profiles.** Separate cookies, history, extensions and notifications. Shared bookmarks, pinned New Tab sites and block lists. A tab cannot move between profiles.
- **New Tab.** Up to 24 pinned tiles, optional frequently-visited row from history (never in private windows), optional News feeds and a notifications inbox. `paddle://settings` opens Settings in a tab; a page cannot.
- **Files.** Paddle > Settings… edits `config.json`. `user.css`, `user-filters.txt`, `userscripts/*.js` and `themes/*.json` apply on Reload Config.

## Install

`scripts/release.sh` builds a Developer ID Release (hardened runtime, secure timestamp), then `codesign --verify --deep --strict`. It refuses a build with `get-task-allow`. Each step prints PASS, FAIL or SKIP. The marketing version is `project.yml`'s `0.1` prefix plus the commit count (`0.1.156`); the build number is that same count, floored at **157** so it cannot collide with the last old-history notarized build (156). Debug Xcode builds keep `0.1.0` / `1`.

- no flags: zip to `dist/Paddle-<version>-<build>-unnotarized.zip`
- `--notarize`: `notarytool` with `$NOTARY_PROFILE`, staple, `spctl`, then write `dist/Paddle-<version>-<build>.zip`
- `--install`: quit a running Paddle, swap `/Applications/Paddle.app` (restore the old copy if that fails)

`SIGN_IDENTITY` picks a certificate by SHA-1 when more than one Developer ID matches. Make Default Browser only works for the copy in `/Applications`.

## Build

```bash
xcodegen generate && xcodebuild -project Paddle.xcodeproj -scheme Paddle -configuration Debug -derivedDataPath build/DerivedData.noindex -allowProvisioningUpdates build
```

`project.yml` is the source of truth; do not hand-edit `Paddle.xcodeproj`. Core tests: `swift test`. Run the debug app with `open build/DerivedData.noindex/Build/Products/Debug/Paddle.app`. Build folders end in `.noindex` so Launch Services does not steal the `/Applications` copy.

## config.json

Only write keys you change. A new install is `{}`. Settings writes the file and applies at once. A save touches only keys you changed; unknown top-level keys stay byte-for-byte. Editing one entry of an object key (`sites`, `shortcuts`, `siteUserAgents`, …) rewrites that whole key. A value set back to its default drops the key. If the file changed at that key since Settings read it, Settings offers Use the File's Value or Save Mine instead of overwriting. Invalid JSON keeps the last good settings. A wrong type falls back to the default (one object entry or list item) and the rest still applies. Settings > Advanced lists ignored keys, value problems, and Tidy… (keys that only repeat defaults). A `sites` entry stays, even as `{}`, until Remove Site.

| Key | Default | Meaning |
|---|---|---|
| `homepage` | `about:blank` | New window. `about:blank` is empty, address bar focused |
| `newTabPage` | `about:blank` | New tab URL |
| `searchTemplate` | `https://duckduckgo.com/?q=%s` | Search URL. `%s` is the query |
| `searchSuggestTemplate` | `https://duckduckgo.com/ac/?q=%s&type=list` | Typed search words only, never addresses or pastes. `""` is off |
| `historyDays` | `365` | Days kept in `history.sqlite`. 0 stops recording (file stays until you clear it). Settings asks before a shorter value deletes visits |
| `tabFreezeAfterMinutes` | `2` | Idle minutes before a background tab freezes (0 = never). JS/timers stop; the page stays in memory. Switching away also drops WebKit's Back-cache pages. Needs `_suspendPage:`; without it nothing freezes. Never the visible tab, sound/camera/mic, pins unless `sleepPinnedTabs`, uploads, or `keepNotifyingSitesLive` / `sites.<host>.freeze` |
| `tabSleepAfterMinutes` | `5` | Idle minutes before the web process exits (0 = never). Return reloads |
| `maxAwakeTabs` | `8` | Cap across windows, most recently used (0 = no cap). Memory pressure sleeps every eligible tab. Low Power / hot: at most 5 min and half the cap (min 2); very hot: 1 min and 2 tabs |
| `sleepPinnedTabs` | `false` | Let pinned tabs sleep |
| `keepPageWorkRunning` | `true` | A background upload (64 KB+ `fetch`/`XHR` or a stream) never freezes or sleeps until it ends, except under memory pressure. A page with `beforeunload` after you typed may freeze but not idle-sleep; the cap and pressure still apply |
| `keepNotifyingSitesLive` | `true` | A site allowed to notify never freezes and does not idle-sleep. CPU rule, cap and pressure still apply. Off in private windows. `sites.<host>.freeze` wins |
| `cpuSleepPercent` | `30` | Sleep a background tab whose process holds this percent of one core for 3 minutes (0 = off). Skips shared processes, the visible tab, sound/camera/mic, and pins unless `sleepPinnedTabs` |
| `sessionHistoryTabs` | `30` | How many tabs keep back/forward state in `sessions/` (plus every pin). 0 = pins only |
| `resumeMediaOnSelect` | `false` | Switching tabs resumes audio on the one you open and pauses the one you left. Off, a switch leaves playback alone |
| `linkPreview` | `true` | Real ⌥-click (or Preview Link) opens an overlay instead of following. ⇧⌘Return makes it a tab. Off, ⌥-click follows. Page scripts cannot open one |
| `speculativeLoading` | `true` | Warm DNS/connection for the address bar's top hit and hovered links. Off in private windows |
| `contentBlocking` | `true` | Ad and tracker blocking |
| `filterLists` | EasyList, EasyPrivacy | HTTPS list URLs, fetched into `filters/` (`easylist.txt`, `easyprivacy.txt`, others `<name>-<urlhash>.txt`). Only these, built-in `paddle-filters`, and `user-filters.txt` block. Remove a URL here and it stops at Reload Config; Remove Unused List Files trashes leftover files. Activity shows compile stats (unsupported lines, style rules, invalid selectors) |
| `filterUpdateDays` | `7` | Days between fetches, checked at launch and hourly. 0 = manual, except a missing file |
| `scriptlets` | `true` | Run `##+js(…)` from the lists above. Fixed names only (`set-constant`, `abort-on-property-read`, `json-prune`, …). `contentBlocking: false` on a site turns them off there too |
| `trustedLists` | `[]` | `filterLists` URLs allowed to use `trusted-*` scriptlets. None implemented yet |
| `userAgentSuffix` | `""` | Replaces `Version/… Safari/…`. Empty matches installed Safari |
| `siteUserAgents` | `{}` | Full UA per host. Built-in: Firefox UA for `account.proton.me` and `pass.proton.me` unless this key or `sitePersonas` covers the host. `""` sends WebKit's own |
| `sites` | `{}` | Per-host settings, longest suffix wins (see fields below) |
| `sitePersonas` | `{}` | `"chrome"` or `"firefox"` per host suffix. JS identity follows; no `Sec-CH-UA` headers. `siteUserAgents` wins the UA string |
| `showTabMemory` | `true` | Toolbar memory readout. Off, no sampling unless Settings is showing it |
| `httpsOnly` | `true` | Upgrade `http://` to `https://`. On failure, a notice: Go Back, Continue to HTTP (until quit), Always Allow HTTP (`sites.<host>.httpsOnly: false`, not in private). Local names and private IPs are exempt |
| `newTabFrequentSites` | `true` | Frequently visited row on New Tab, from history |
| `showFullAddress` | `false` | Show the whole URL while not editing. Off, site only (`accounts.google.com`, no `www.`) |
| `askWhereToDownload` | `false` | Sheet for each download, starting in `downloadFolder` |
| `downloadFolder` | `""` | Save location (`~` allowed). Empty or missing: ~/Downloads |
| `underlineLinks` | `false` | Underline links on pages |
| `alwaysShowTabCloseButtons` | `false` | Show × on every tab without hover |
| `showHomeButton` | `false` | Home button to `homepage` |
| `alwaysShowDownloadsButton` | `false` | Downloads button even when idle |
| `onLaunch` | `"restore"` | `"restore"` last windows, or `"newWindow"` (saved session replaced at first save) |
| `externalLinks` | `"newTab"` | Links from other apps: `"newTab"`, `"newWindow"`, `"currentTab"`. http/https/about only. `file:` only for html/xhtml/webarchive. Never into a private window |
| `askBeforeQuitting` | `false` | ⌘Q asks while a window is open. Running downloads always ask |
| `askBeforeClosingWindow` | `false` | Ask when closing a window with more than one tab |
| `newTabPosition` | `"end"` | `"end"` or `"afterCurrent"`. Links still open next to the tab they came from |
| `afterClosingTab` | `"right"` | `"right"`, `"left"` or `"lastUsed"`. A popup you have not left still returns to its opener |
| `openLinksInBackground` | `true` | ⌘-click / middle-click background; ⌘⇧-click front. `false` swaps them |
| `swipeNavigation` | `true` | Two-finger swipe back/forward |
| `pinchZoom` | `true` | Pinch zooms the page |
| `tabKeyHighlightsLinks` | `false` | Tab key walks links, not only fields |
| `soundEffects` | `false` | macOS alert when a key is unused. Off so arrow-key video seek does not beep |
| `fraudWarnings` | `true` | WebKit Safe Browsing |
| `contactAutofill` | `false` | Overlay button fills name/email/phone/address from Keychain (Settings or Contacts My Card). HTTPS only, never frames, never passwords or cards. The page cannot see the button |
| `newTabExtension` | `""` | Extension folder whose `chrome_url_overrides.newtab` replaces Paddle's New Tab |
| `newTabFeeds` | `[]` | RSS/Atom URLs for New Tab News (up to 12, no cookies, skip local-network images). Cached in `feeds-cache.json` |
| `newTabNotifications` | `false` | List this session's website notifications on New Tab. Memory only; per profile; none from private windows. No Web Push: the tab has to be open |
| `newTabSections` | `["pinned", "frequent", "notifications", "news"]` | Section order. Unknown names ignored; omitted sections go last |
| `newTabHiddenNotifications` | `[]` | Hosts omitted from that section. Banners still follow `sites.<host>.notifications` |
| `mosaicMaxPanes` | `4` | Panes per Mosaic, 2–6 (older files: `multiViewMaxPanes`) |
| `mosaicPaneBars` | `"always"` | Pane toolbar `"always"` or `"hover"` |
| `mosaicGap` | `6` | Points between panes, 2–16 |
| `mosaicMinimumPaneWidth` | `260` | Below this, only the focused pane shows (100–800) |
| `mosaicMinimumPaneHeight` | `160` | Same for height (100–800) |
| `mosaicStaysReady` | `true` | Mosaic you just left keeps all panes attached. `false` keeps only the focused pane |
| `mosaicFreezeAfterMinutes` | (left out) | Unused Mosaic freeze; omitted follows `tabFreezeAfterMinutes`. 0 = never |
| `mosaicSleepAfterMinutes` | (left out) | Same for sleep / `tabSleepAfterMinutes` |
| `mosaicAnimation` | `"system"` | `"system"`, `"full"`, `"reduced"` or `"off"` |
| `mosaicAnimationSpeed` | `"smooth"` | `"snappy"`, `"smooth"` or `"relaxed"` |
| `mosaicLiveDragPreview` | `true` | Panes move aside while you drag. `false` is highlight only |
| `mosaicDividerGrips` | `"always"` | `"always"`, `"hover"` or `"hidden"` (still resizes) |
| `mosaicDividerSnapping` | `false` | Snap a divider to halves/thirds |
| `mosaicDividerDoubleClick` | `"divider"` | Even `"divider"`, `"all"`, or `"nothing"` |
| `mosaicPaneCorners` | `"rounded"` | `"rounded"` or `"square"` |
| `mosaicFocusMarker` | `"ring"` | `"ring"`, `"dim"` (`mosaicDimAmount`) or `"none"` |
| `mosaicDimAmount` | `0.25` | Dim strength, 0.05–0.7 |
| `mosaicToolbarSize` | `"regular"` | `"regular"` (30 pt) or `"compact"` (24 pt) |
| `mosaicToolbarButtons` | `["back", "forward", "reload", "close"]` | Extra pane-toolbar buttons |
| `mosaicPaneGrab` | `"icon"` | Pick up by `"icon"`, `"grip"` or `"toolbar"` |
| `mosaicModifierDrag` | `true` | ⌥⌘-drag the page to move the pane |
| `mosaicWindowDrag` | `true` | Empty Mosaic toolbar drags the window |
| `mosaicNewTab` | `"tab"` | ⌘T is a `"tab"` or a `"pane"` while there is room |
| `mosaicLinks` | `"tab"` | New-tab links as `"tab"` or `"pane"`. Script windows stay tabs |
| `mosaicNewPanePlacement` | `"largest"` | Split `"largest"`, `"focused"` or `"last"` |
| `mosaicDefaultLayout` | `"asDropped"` | `"asDropped"`, `"columns"`, `"rows"`, `"grid"` or `"mainAndStack"` |
| `mosaicAutoArrange` | `false` | Retile to `mosaicDefaultLayout` when panes join or leave |
| `mosaicDarkMode` | `"site"` | ⇧⌘D: `"site"` (saved), `"unified"` or `"perPane"` (last two not saved) |
| `mosaicZoom` | `"focused"` | ⌘+/−/0 on `"focused"` or `"all"` |
| `mosaicFocusFollowsPointer` | `false` | Pointer-over focuses a pane (not while editing an address) |
| `mosaicSound` | `"all"` | `"all"` panes, or `"focused"` only |
| `mosaicCloseKey` | `"closeTab"` | ⌘W `"closeTab"` or `"removePane"` |
| `mosaicStripIcon` | `"icon"` | Strip item shows `"icon"` or pane `"favicons"` |
| `mosaicStripName` | `"focused"` | Unnamed Mosaic: focused site, or `"all"` sites |
| `mosaicStripShading` | `true` | Distinct shading on Mosaic strip/sidebar items |
| `mosaicStripColor` | `"accent"` | `"accent"`, `"icon"`, a color name or `#rrggbb` |
| `mosaicStripStrength` | `16` | Shading 4–60 (percent) |
| `mosaicStripStyle` | `"both"` | `"fill"`, `"outline"` or `"both"` |
| `tabLayout` | `"horizontal"` | `"vertical"` for a sidebar. View > Vertical Tabs |
| `appearance` | `"system"` | `"light"` or `"dark"` forces windows and `prefers-color-scheme` |
| `darkMode` | `"off"` | Page dark mode: `"off"`, `"system"`, `"smart"` or `"native"` (`"always"` in an old config still loads as smart). Per-site override in `sites` |
| `invertTextImages` | `false` | Invert dark-text-on-light images when dark mode is on |
| `theme` | `"default"` | Chrome colors: `"default"`, built-in (`graphite`, `ocean`, `forest`, `dusk`, `sand`, `high-contrast`) or a `themes/` file name |
| `accentColor` | `"system"` | `"system"`, a color name or `#rrggbb` |
| `chromeTint` | `"none"` | Blend a color over strip and toolbar |
| `chromeTintStrength` | `25` | 0–100, lowered automatically to keep 4.5:1 text contrast |
| `highContrastTabs` | `false` | Stronger selected-tab fill and edge |
| `interfaceTextSize` | `"default"` | Chrome text: `"small"` 90%, `"default"`, `"large"` 115%, `"larger"` 130% |
| `defaultZoom` | `1` | Page zoom with no site override (0.3–3) |
| `minimumFontSize` | `0` | Page minimum in points. 0 is off; else 9–24 |
| `reduceMotion` | `"system"` | `"always"` reduces chrome motion even if macOS does not |
| `reduceTransparency` | `"system"` | `"always"` makes chrome opaque even if macOS does not |
| `controlBridge` | `false` | Local MCP socket for an AI client. Owner-only, never a TCP port. Private windows invisible |
| `controlBridgeScripts` | `false` | Allow `run_js`. Off separately: a script can reach what the page can, passwords included |
| `developerTools` | `true` | Inspect Element, Safari Develop menu, Paddle Develop menu. Open pages keep the setting they loaded with |
| `extensions` | `{}` | `{"folder": false}` to turn one off. Unlisted folders are on |
| `extensionToolbar` | `{}` | Button placement per folder: `"pinned"` (default), `"menu"`, `"hidden"` |
| `extensionCompat` | `{}` | Per folder: `persona` (`chrome` / `firefox` / `native` / `none`), `shims`, `publicID`, `private`. Changing `persona` or `publicID` issues a new id and moves storage |
| `extensionUpdates` | `true` | Daily store-update check for Chrome Web Store and addons.mozilla.org installs |
| `extensionsOnDemand` | `true` | Site-specific extensions unload after 5 minutes off those sites (~60 MB with one tab, ~190 MB with six; `docs/measurements.md`) |
| `extensionsInPrivate` | `false` | Run extensions in private windows. `extensionCompat.<folder>.private` overrides |
| `shortcuts` | `{}` | `{"nextTab": "cmd+option+right", "closeTab": "none"}`. Shifted keys as the base key plus `shift` (`cmd+shift+[`). Needs `cmd` or `ctrl` unless it is an F key |

`sites` fields, all optional (unset = Paddle default): `zoom`, `javaScript`, `autoplay` (`allow` / `muted` / `block`; last two need a private WebKit setting), `contentBlocking`, `location` and `notifications` (`ask` / `allow` / `deny`; these match the entry's own host only, not subdomains), `httpsOnly`, `popups`, `darkMode` (`auto` / `light` / `dark` / `native`; unset means auto), `freeze` (`auto` / `never` / `always`). Host suffix: `"example.com"` covers `www.example.com`. `"contentBlocking": false` excepts the host and its subdomains in every list. Private windows write nothing here.

Older Mosaic names still read: `multiViewMaxPanes`, `toggleSplitView`, `swapSplitSides`, `focusOtherSplitSide`, `removeFromView`.

Shortcut action names: `settings`, `openConfigFolder`, `reloadConfig`, `updateFilterLists`, `makeDefaultBrowser`, `hide`, `hideOthers`, `quit`, `newTab`, `newWindow`, `newPrivateWindow`, `openLocation`, `closeTab`, `closeWindow`, `reopenClosedTab`, `savePage`, `exportPDF`, `openInPreview`, `createQRCode`, `print`, `sharePage`, `importFromBrowser`, `undo`, `redo`, `cut`, `copy`, `copyLinkToHighlight`, `paste`, `pasteAndMatchStyle`, `selectAll`, `find`, `findNext`, `findPrevious`, `useSelectionForFind`, `jumpToSelection`, `searchSelectedText`, `reload`, `hardReload`, `stop`, `zoomIn`, `zoomOut`, `actualSize`, `toggleVerticalTabs`, `toggleSidebarCollapsed`, `showDownloads`, `viewSource`, `toggleReaderMode`, `siteDarkModeAuto`, `siteDarkModeLight`, `siteDarkModeDark`, `siteDarkModeNative`, `keepPageLight`, `toggleDarkMode`, `toggleInvertTextImages`, `togglePictureInPicture`, `translatePage`, `fullScreen`, `back`, `forward`, `showHistory`, `clearHistory`, `addBookmark`, `addToNewTabPage`, `showBookmarks`, `toggleBookmarksBar`, `importBookmarks`, `exportBookmarks`, `webInspector`, `javaScriptConsole`, `elementSelection`, `reloadWithoutContentBlockers`, `emptyCaches`, `responsiveDesignMode`, `nextTab`, `previousTab`, `togglePin`, `duplicateTab`, `closeOtherTabs`, `closeTabsToTheRight`, `renameTab`, `addTabToNewGroup`, `removeTabFromGroup`, `space1` … `space9`, `nextSpace`, `previousSpace`, `newSpace`, `editSpace`, `deleteSpace`, `toggleMosaic`, `arrangeColumns`, `arrangeRows`, `arrangeGrid`, `arrangeMainAndStack`, `toggleFreeform`, `tidyUp`, `evenOutPanes`, `rotatePanes`, `swapMosaicPanes`, `zoomPane`, `movePaneLeft`, `movePaneRight`, `movePaneUp`, `movePaneDown`, `muteOtherPanes`, `addPane`, `reloadAllPanes`, `focusNextPane`, `focusPaneLeft`, `focusPaneRight`, `focusPaneUp`, `focusPaneDown`, `removeFromMosaic`, `openLinkPreviewAsTab`, `closeLinkPreview`, `moveTabLeft`, `moveTabRight`, `toggleMute`, `muteOtherTabs`, `searchTabs`, `sleepBackgroundTabs`, `tab1` … `tab9`, `installExtensionFromLink`, `checkExtensionUpdates`, `openExtensionsFolder`, `reloadExtensions`, `minimize`.

Modifiers: `cmd`, `shift`, `option`/`alt`, `ctrl`. Named keys: `left right up down tab return escape delete space home end pageup pagedown f1`–`f12`.

## Private windows

File > New Private Window (⇧⌘N). Address field labelled Private. Window title is always "Private Window" (other apps can read titles).

Shared temporary store, thrown away when the last private window closes. No history, favicons, `session.json`, or Reopen Closed Tab. Downloads still write files; the list is not kept. Zoom and Dark Mode last for the session. Lock-popover permission switches are disabled. Content blocking, `user.css` and userscripts still run. Suggestions can read normal history; nothing typed is recorded. Extensions off unless `extensionsInPrivate` or the folder's `"private"` is true. App links open in a normal window.

## Moving from another browser

File > Import from Browser… reads Safari, Chrome-family and Firefox profiles (a copy of the DB; the old profile is not modified). Checkboxes per thing that profile has. Never Keychain, passwords or cookies.

- **Settings:** search engine (only engines Settings offers), home page, bookmarks bar. Hand-edited keys are not overwritten.
- **History:** newest 200k http(s) visits; skips ones already in Paddle and ones older than `historyDays`.
- **Bookmarks:** Chrome JSON, Firefox `places.sqlite`, Safari `Bookmarks.plist`. Bar to the bar, rest into "Imported from \<profile\>". Undo Import Bookmarks takes the whole import out. HTML export still works via Bookmarks > Import Bookmarks….
- **Open tabs:** off by default. Chrome Sessions / Firefox recovery; not Safari. Web pages only, cap 500, asleep until shown.
- **Site settings:** fills empty `sites` fields only (zoom, notifications, location, JS off, autoplay).
- **Passwords / cookies:** not imported. Export from the old browser into a password-manager extension, then delete the export file.
- **Extensions:** ticked Chrome Web Store / AMO items reinstall through Paddle's store installer after Done. Unpacked, Edge, and Safari-app extensions are listed as not installable.

Chrome, Edge, Firefox and Safari data folders are TCC-protected. Without Full Disk Access those rows say so. Paddle never asks for the permission itself.

## Extensions

WebExtensions on WebKit (MV3, plus whatever MV2 WebKit still runs). Folder with `manifest.json` in `extensions/`, or a Chrome Web Store / addons.mozilla.org link. Store packages are signature-checked (Google's key; Mozilla's AMO root in `Resources/AMO`). 100 MB cap.

Updates daily while `extensionUpdates` is on. Extra permissions wait for Allow. Hand-installed Firefox add-ons can be adopted for updates (asked once).

First run: Allow, Only When I Click, or Don't Allow. Answers in `extension-permissions.json`, tied to the extension's identity so a reused folder name asks again. `webRequestBlocking` without declarative rules does not block here (WebKit ignores blocking answers); uBlock Origin MV2 is in that boat. Paddle's own lists still run.

Native messaging only to Paddle's compat channel (`com.walker.paddle.compat`). No history/bookmarks/downloads APIs. Personas: Firefox build → `moz-extension://`, else Chrome-like, Safari-only untouched. Overlay in `extension-overlays/` (`paddle-prelude.js`, `paddle-content.js`). **`tabs.update({ muted })` / `tab.mutedInfo`** use the same mute path as Tabs > Mute Tab. Proton Pass: no site logos, HTTP auth fill, clipboard auto-clear, or desktop-app unlock; sign-in, vault, autofill, save prompt and extension passkeys do not need those. **Website** passkeys in tabs need Apple's browser entitlement (`docs/passkeys.md`).

`extension-id-salt` derives per-install ids; unreadable means no extension loads. Storage is under `~/Library/WebKit/com.walker.Paddle/WebExtensions/`.

## Other files

Support folder, profiles, `sessions/`, `favicons/` and the log folder are 0700. History DBs, `session.json`, `bookmarks.json`, `feeds-cache.json`, `newtab.json`, `profiles.json` and `exceptions.log` are 0600.

- `history.sqlite`, `bookmarks.json`, `newtab.json`, `feeds-cache.json`, `profiles.json` as named above.
- `bridge/control.sock`: control-bridge socket, only while `controlBridge` is on (0600, parent 0700). Very long home path: `<temp>/paddle-<uid>/control.sock`.
- `user.css`, `user-filters.txt`, `userscripts/*.js`, `themes/*.json`, `filters/*.txt`.
- `favicons/`: 32 px PNG per site, 128 px in `favicons/large/` for New Tab tiles. Safe to delete.
- First launch copies bundled EasyList / EasyPrivacy snapshots (version 202610121715) so blocking starts offline.

Filter syntax Paddle turns into WebKit rules: `||host^`, `|anchor|`, `*`, `^`, `third-party`, `domain=`, resource types, `match-case`, `important`, `$document` on `@@`, `##` / `#@#`, and `/regex/` when the rewrite matches the same URLs. `##+js`, `redirect`, `csp`, `removeparam`, `replace=`, `header=` are counted, not approximated. Your `@@` and `#@#` lines are appended to each downloaded list. A tab's first page waits up to 3 s for lists; a page that loaded during a slow compile reloads once unless it posted a form, is playing media, or you typed into it.

`profiles.json` `settings` may override: `homepage`, `newTabPage`, `searchTemplate`, `searchSuggestTemplate`, `newTabFrequentSites`, `historyDays`, `askWhereToDownload`, `downloadFolder`, `theme`, `accentColor`, `chromeTint`, `chromeTintStrength`, `tabFreezeAfterMinutes`, `tabSleepAfterMinutes`, `sleepPinnedTabs`, `cpuSleepPercent`, `keepPageWorkRunning`, `keepNotifyingSitesLive`, `linkPreview`, `resumeMediaOnSelect`, and `sites` fields `zoom`, `javaScript`, `autoplay`, `location`, `notifications`, `popups`, `httpsOnly`, `freeze`. Everything else is shared (block lists, appearance, shortcuts, bridge, `maxAwakeTabs`).

## Control bridge

Off by default. Owner-only Unix socket, relayed by `/Applications/Paddle.app/Contents/Helpers/paddle-mcp`. Not a network port.

```bash
claude mcp add paddle -- /Applications/Paddle.app/Contents/Helpers/paddle-mcp
```

Tools: `paddle_state`, `page_text`, `page_snapshot`, `window_snapshot`, `read_config`, `logs` (private values redacted), `open_url`, `select_tab`, `close_tab`, `reload_tab`, `wait_for_load`, `menu_action` (allow-listed navigation/tabs/view only), `set_config` (allow-listed display/behaviour keys only; not homepage, search, sites, blocking, downloads, bridge switches, or anything new until it is added to `bridgeSettableConfigKeys`), `run_js` (needs `controlBridgeScripts`). Titles, URLs and page text are wrapped as untrusted page content.

Once per session, as a sheet: `run_js` per site; `open_url` to a local-network host. Don't Allow is remembered until quit.

Peer must be this user's signed `paddle-mcp` (identifier `paddle-mcp`, same Developer ID team as the app). Cap 8 clients, 16 in-flight calls, 5 s to read a reply, 1 MB per line. Toolbar shows "Claude connected". Private windows are invisible. No tool reads Keychain, clipboard, downloads, or files outside the support folder.

## Not supported (yet)

- **Web Push** — notifications while Paddle is quit or the tab is closed. Needs Apple's push entitlement; **Walker has requested it.** Until granted, Paddle supports the page notification API only while a tab is open (`sites.<host>.notifications`, `keepNotifyingSitesLive`).
- **Apple Pay and Payment Request** — not available without Apple's payment entitlements.
- **Browser passkeys (WebAuthn for arbitrary sites)** — needs Apple's managed entitlement on Team VB3UP263YT. Passkeys form **submitted (Request ID `84Z8XFC523`, pending Apple)**; `BrowserPasskeyCoordinator` and docs are in the repo, but Release signing keeps the entitlement commented out until Apple approves. See [`docs/passkeys.md`](docs/passkeys.md).

## Limits

- **SPA Back scroll** — `ScrollRestoreScript` retries restore for about **5 s**; back/forward commits defer per-site zoom ~900 ms. A site can still miss if it moves scroll later or replaces the scroll container.
- **Instant Back vs RAM** — freezing or leaving a tab drops WebKit's in-process back/forward cache on purpose. History and scroll restore still apply; Back may reload instead of an instant cached page.

## Contributing

Fork and open a pull request against `main`. Walker merges or closes. See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go to [private advisories](SECURITY.md), not issues.

