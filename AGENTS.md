# Paddle

Personal macOS web browser built on the system WebKit (`WKWebView`). Goals: resource-light, broad site compatibility, customizable through plain files. macOS 27 target, Swift 6 (strict concurrency complete), hardened runtime, team VB3UP263YT. Personal use: private WebKit API is allowed but must degrade gracefully (`responds(to:)` checks).

## Layout
- `Sources/PaddleCore/`: UI-free logic, unit-tested: address parsing, `config.json` model, tab sleep policy, user-script headers and URL matching, Adblock Plus → WebKit content-rule-list converter, session and shortcut models.
- `Tests/PaddleCoreTests/`: package tests (`swift test`). `FilterListConverterTests.webKitCompilesOutput` compiles converter output with real WebKit.
- `App/Paddle/`: AppKit app with SwiftUI chrome. Default actor isolation is MainActor.
  - `AppModel.swift`: config, windows, session save/restore, memory sampling, tab sleeping, memory-pressure handling.
  - `Browser/`: `Tab` (owns or drops its `WKWebView`), `BrowserModel` (one window's tabs), `BrowserWindowController` (menu actions via the responder chain).
  - `Web/`: shared WebKit configuration and block lists (`WebEnvironment`), per-tab WebKit delegate, downloads.
  - `Bridge/`: the control bridge: the owner-only Unix socket server (`BridgeSocketServer`), the MCP tools (`ControlBridge+Tools`), the toolbar indicator and Settings section.
  - `UI/`: SwiftUI tab strip, toolbar, find bar, activity and downloads popovers.
  - `MainMenu.swift`: menu bar; every item has an action name that `config.json` `shortcuts` can rebind.
- `App/PaddleMCP/main.swift`: `paddle-mcp`, the Foundation-only stdio-to-socket relay for the control bridge, embedded at `Contents/Helpers`. MCP itself is `Sources/PaddleCore/MCP.swift`.
- `project.yml` is the XcodeGen source of truth; `Paddle.xcodeproj` is generated (`xcodegen generate`), do not hand-edit it.

## User data
`~/Library/Application Support/Paddle/`: `config.json`, `user.css`, `user-filters.txt`, `userscripts/*.js`, `themes/*.json` (chrome color themes), `filters/*.txt` (downloaded lists), `compiled-rules/` (WebKit cache, about 50 MB), `session.json`, `bridge/control.sock` (control bridge socket in its own owner-only folder, only while `controlBridge` is on), `newtab.json` (pinned New Tab sites and hidden frequent hosts), `feeds-cache.json` (New Tab's last News stories), `profiles.json` (profiles; the default keeps `history.sqlite`), `profiles/<id>/history.sqlite` (other profiles' history; their cookies and storage live in WebKit's data store named by the id), `profiles/<id>/extension-permissions.json` (other profiles' extension answers; their extension storage is WebKit's, under `~/Library/WebKit/com.walker.Paddle/WebExtensions/<id>`).

## Commands
- Core tests: `swift test`
- Ad-blocking oracle (opt-in, ~2.5 min): `PADDLE_ORACLE=1 swift test --filter AdblockOracle` compares the converter with uBlock Origin on 221k real requests and writes `build/oracle/report.txt`. Needs `ublock-matches.tsv` and the `regression-testing` `easylist.txt` / `easyprivacy.txt` from github.com/brave/adblock-rust (`data/`) in `build/oracle/`.
- Regenerate project after editing `project.yml`: `xcodegen generate`
- App build: `xcodebuild -project Paddle.xcodeproj -scheme Paddle -configuration Debug -derivedDataPath build/DerivedData.noindex -allowProvisioningUpdates build`
- Run: `open build/DerivedData.noindex/Build/Products/Debug/Paddle.app`
- Build folders end in `.noindex` (`build/DerivedData.noindex`, `build/ReleaseDerivedData.noindex`): Spotlight and Launch Services then skip the build copies, so only `/Applications/Paddle.app` shows up as Paddle and handles links and notification clicks.
- Logs: `log show --predicate 'subsystem == "com.walker.Paddle"' --last 5m --info`

## Rules
- A passing `swift test` proves the core only. Do not say the app builds or a feature works unless `xcodebuild` ran and the feature was exercised in the running app this session.
- Resource claims need a measurement (process footprint, WebContent process count), not reasoning from code.
- Keep `README.md`'s config keys and shortcut action names in sync with `PaddleConfig` and `MainMenu`.

## Learned User Preferences
- Before calling browser work done, build a Release Developer ID app, notarize when shipping, and install to `/Applications/Paddle.app`; Walker runs that copy, not `build/DerivedData.noindex/.../Debug/Paddle.app`.
- Awake tabs that are not sleeping should switch instantly; laggy tab changes are bugs regardless of site.
- `resumeMediaOnSelect` must stay off by default; switching tabs must not hijack audio unless the user turns that on.

## Learned Workspace Facts
- Shipped installs: `scripts/release.sh --notarize --install` (see README for flags and Gatekeeper checks).
- Control-bridge MCP for Cursor uses `/Applications/Paddle.app/Contents/Helpers/paddle-mcp`, not Claude Code’s `mcp add`.
- `ScrollRestoreScript` (page world, document start) records inner-column scroll before SPA navigations and restores it after Back on timeline-style sites such as X.
- Reapplying per-site zoom on each document commit (`applySiteZoom` from `pageCommitted`) can reset scroll position during back/forward restoration.
