# Paddle

A light, hackable Mac browser on Apple's WebKit, the engine Safari uses.

- **Light:** background tabs go to sleep (their web process exits) after 30 minutes idle, when more than 10 are awake, or right away under memory pressure. Tabs playing media or using the camera or mic stay awake. Restored sessions start with only the visible tab awake. The memory button in the toolbar shows this tab · all tabs; click it for a per-tab list.
- **Compatible:** identifies as the installed Safari version. Popups and sign-in windows open as tabs with `window.opener` intact, and closing one returns to the page that opened it. Downloads, uploads, camera/mic prompts, HTTP logins, full screen and Web Inspector (right-click > Inspect Element) work. Links to other apps (`mailto:`, `zoommtg:`) open them; when a page rather than a click starts one, Paddle asks first. A frame from another site that starts a download also asks first (once per site per session).
- **Blocks ads and trackers:** EasyList and EasyPrivacy are converted into WebKit's native content blocker, so blocking costs no extension process.
- **Customizable:** everything lives in plain files in `~/Library/Application Support/Paddle/` (Paddle > Open Config Folder). Edit, then Paddle > Reload Config (⌥⌘,).

## config.json

Only include the keys you change.

| Key | Default | Meaning |
|---|---|---|
| `homepage` | `about:blank` | Page for a new window (`about:blank` = empty, address bar focused) |
| `newTabPage` | `about:blank` | Page for a new tab |
| `searchTemplate` | `https://duckduckgo.com/?q=%s` | Search URL, `%s` = query |
| `searchSuggestTemplate` | `https://duckduckgo.com/ac/?q=%s&type=list` | Address-bar search suggestions (OpenSearch or DuckDuckGo JSON). Only search words typed key by key are sent, never addresses, paths or pastes; `""` = off |
| `historyDays` | `365` | Days of history kept in `history.sqlite` (0 = no history) |
| `tabSleepAfterMinutes` | `30` | Idle minutes before a background tab sleeps (0 = never) |
| `maxAwakeTabs` | `10` | Most tabs awake at once (0 = no cap) |
| `sleepPinnedTabs` | `false` | Let pinned tabs sleep too |
| `contentBlocking` | `true` | Ad and tracker blocking |
| `filterLists` | EasyList, EasyPrivacy | Adblock Plus lists fetched by Paddle > Update Filter Lists |
| `userAgentSuffix` | `""` | Replaces `Version/… Safari/…` (empty = match installed Safari) |
| `siteUserAgents` | `{}` | Full user agent per site, e.g. `{"example.com": "Mozilla/5.0 …"}` |
| `showTabMemory` | `true` | Memory readout in the toolbar |
| `developerTools` | `true` | Inspect Element in the context menu |
| `shortcuts` | `{}` | Rebind menu commands, e.g. `{"nextTab": "cmd+option+right", "closeTab": "none"}` |

Shortcut action names: `settings`, `openConfigFolder`, `reloadConfig`, `updateFilterLists`, `hide`, `hideOthers`, `quit`, `newTab`, `newWindow`, `openLocation`, `closeTab`, `closeWindow`, `reopenClosedTab`, `undo`, `redo`, `cut`, `copy`, `paste`, `pasteAndMatchStyle`, `selectAll`, `find`, `findNext`, `findPrevious`, `reload`, `hardReload`, `stop`, `zoomIn`, `zoomOut`, `actualSize`, `webInspector`, `fullScreen`, `back`, `forward`, `showHistory`, `clearHistory`, `addBookmark`, `showBookmarks`, `toggleBookmarksBar`, `importBookmarks`, `exportBookmarks`, `nextTab`, `previousTab`, `togglePin`, `duplicateTab`, `sleepBackgroundTabs`, `tab1` … `tab9`, `minimize`.

Modifiers: `cmd`, `shift`, `option`/`alt`, `ctrl`. Named keys: `left right up down tab return escape delete space home end pageup pagedown f1`–`f12`.

## Other files

- `history.sqlite`: browsing history (History > Show All History, ⌘Y). The address bar suggests open tabs, history and search phrases as you type and completes known hosts inline.
- `bookmarks.json`: bookmarks, as `{"bar": [...], "menu": [...]}` of `{"title": …, "url": …}`; folders have `children` instead of `url`. Paddle adds an `id` to each entry; hand-written entries can leave it out. Edit by hand and Reload Config (an in-app edit also picks up hand edits first), or use Bookmarks > Show Bookmarks (⌥⌘B). ⌘D or the star bookmarks the page to the bar; Edit > Undo reverses bookmark edits. Import/Export Bookmarks… read and write the HTML file Safari, Firefox and Chrome use.
- `favicons/`: site icons, one 32 px PNG per site, refetched weekly. WebKit fetches them (512 KB cap) only from hosts the page itself loaded from, otherwise `/favicon.ico`; SVG icons are skipped. Clear History removes them except for bookmarked sites, and with history off only bookmarked sites' icons are kept. Safe to delete.
- `user.css`: applied to every page.
- `user-filters.txt`: your own Adblock Plus rules (`||host^`, `site.com##.selector`, `@@||site^$document` to allowlist a site).
- `userscripts/*.js`: Greasemonkey-style scripts (`@match`, `@include`, `@exclude`, `@run-at`, `@noframes`, `@inject-into content`). A file without a header runs everywhere. `GM_*` APIs are not provided.

## Build

```bash
xcodegen generate && xcodebuild -project Paddle.xcodeproj -scheme Paddle -configuration Debug -derivedDataPath build/DerivedData -allowProvisioningUpdates build
```
