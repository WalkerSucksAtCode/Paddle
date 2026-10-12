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
| `developerTools` | `true` | Inspect Element in the context menu and Safari's Develop menu. Open pages keep the setting they loaded with; extension popups and pages pick up a change after a relaunch |
| `extensions` | `{}` | Turn an extension off by its folder name, e.g. `{"protonpass": false}`. Folders not listed are on |
| `shortcuts` | `{}` | Rebind menu commands, e.g. `{"nextTab": "cmd+option+right", "closeTab": "none"}` |

Shortcut action names: `settings`, `openConfigFolder`, `reloadConfig`, `updateFilterLists`, `hide`, `hideOthers`, `quit`, `newTab`, `newWindow`, `openLocation`, `closeTab`, `closeWindow`, `reopenClosedTab`, `undo`, `redo`, `cut`, `copy`, `paste`, `pasteAndMatchStyle`, `selectAll`, `find`, `findNext`, `findPrevious`, `reload`, `hardReload`, `stop`, `zoomIn`, `zoomOut`, `actualSize`, `webInspector`, `fullScreen`, `back`, `forward`, `showHistory`, `clearHistory`, `addBookmark`, `showBookmarks`, `toggleBookmarksBar`, `importBookmarks`, `exportBookmarks`, `nextTab`, `previousTab`, `togglePin`, `duplicateTab`, `sleepBackgroundTabs`, `tab1` … `tab9`, `openExtensionsFolder`, `reloadExtensions`, `minimize`.

Modifiers: `cmd`, `shift`, `option`/`alt`, `ctrl`. Named keys: `left right up down tab return escape delete space home end pageup pagedown f1`–`f12`.

## Extensions

Paddle runs WebExtensions (the Chrome and Firefox add-on format) on WebKit's own extension support, the same engine Safari uses for web extensions. Manifest V3 and whatever V2 support WebKit provides.

- **Installing:** put each unpacked extension in its own folder in `extensions/` (Extensions > Open Extensions Folder): a folder with `manifest.json` at its root, or a folder holding exactly one such folder (the usual unzip layout). Zips and `.crx` files must be unzipped first; a folder without a manifest gets a status line, not a load. Paddle > Reload Config picks up added, removed, enabled and disabled folders; Extensions > Reload Extensions reloads everything, edited files included.
- **Permissions:** before an extension first runs, Paddle lists what it wants and offers **Allow** (everything it asks for), **Only When I Click** (its APIs, but no site until you click its button, which grants that tab for that click) or **Don't Allow**. A running extension asking for more gets the same prompt. Answers are kept in `extension-permissions.json` (per folder name, hand-editable; `"click"` marks a site left to Only When I Click); delete an entry, or use the extension's "Ask About Permissions Again", to change them. If the file is corrupt, no extension loads until it is fixed or deleted.
- **Using them:** each extension with a toolbar action gets a button right of the address bar with its badge; click it for its popup (sign in to a password manager there) and again to close it, right-click for Options, permissions and the extension's own items. A popup opens only from a click, a menu item or a command; an extension can't pop it up on its own. The Extensions menu lists every running extension with its commands, options page, problems and, with `developerTools` on, Inspect Background Page; the load status of every folder is at the bottom. Keyboard shortcuts from an extension's manifest work in browser windows and run before the page sees the key, as in Chrome, except a key one of Paddle's menu items uses, which stays Paddle's. Extension pages open as tabs; sleeping tabs look like Chrome's discarded tabs to them. Failures at startup show in a banner in the window.
- **What extensions can see:** extensions are third-party code. "Allow" usually means every site, signed-in pages included, until you change it. With `tabs`, they see every tab's address and title, sleeping tabs included. They share the browsing cookie store, so `cookies` sees your site cookies. They get no history, bookmarks or downloads API, and Paddle never launches a native app for them (`nativeMessaging` is always refused). Anything that can write to Application Support can pre-approve an extension: the same trust level as `config.json`. An extension and the built-in blocker can both block, so turn one off to compare.
- **Files:** `extensions/` (the folders), `extension-permissions.json` (your answers), `extension-id-salt` (per-install ids; deleting it changes every extension's id and orphans its storage and restored extension tabs). Extension storage lives in `~/Library/WebKit/com.walker.Paddle/WebExtensions/`; deleting an extension's folder keeps its storage and permission entry.
- **Not supported:** native messaging, page context-menu items, private windows, moving tabs between windows, muting, store installs and updates.

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
