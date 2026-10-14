# Paddle

Personal macOS web browser built on the system WebKit (`WKWebView`). Goals: resource-light, broad site compatibility, customizable through plain files. macOS 27 target, Swift 6 (strict concurrency complete), hardened runtime, team VB3UP263YT. Personal use: private WebKit API is allowed but must degrade gracefully (`responds(to:)` checks).

## Layout
- `Sources/PaddleCore/`: UI-free logic, unit-tested: address parsing, `config.json` model, tab sleep policy, user-script headers and URL matching, Adblock Plus → WebKit content-rule-list converter, session and shortcut models.
- `Tests/PaddleCoreTests/`: package tests (`swift test`). `FilterListConverterTests.webKitCompilesOutput` compiles converter output with real WebKit.
- `App/Paddle/`: AppKit app with SwiftUI chrome. Default actor isolation is MainActor.
  - `AppModel.swift`: config, windows, session save/restore, memory sampling, tab sleeping, memory-pressure handling.
  - `Browser/`: `Tab` (owns or drops its `WKWebView`), `BrowserModel` (one window's tabs), `BrowserWindowController` (menu actions via the responder chain).
  - `Web/`: shared WebKit configuration and block lists (`WebEnvironment`), per-tab WebKit delegate, downloads.
  - `UI/`: SwiftUI tab strip, toolbar, find bar, activity and downloads popovers.
  - `MainMenu.swift`: menu bar; every item has an action name that `config.json` `shortcuts` can rebind.
- `project.yml` is the XcodeGen source of truth; `Paddle.xcodeproj` is generated (`xcodegen generate`), do not hand-edit it.

## User data
`~/Library/Application Support/Paddle/`: `config.json`, `user.css`, `user-filters.txt`, `userscripts/*.js`, `filters/*.txt` (downloaded lists), `compiled-rules/` (WebKit cache, about 50 MB), `session.json`.

## Commands
- Core tests: `swift test`
- Ad-blocking oracle (opt-in, ~2.5 min): `PADDLE_ORACLE=1 swift test --filter AdblockOracle` compares the converter with uBlock Origin on 221k real requests and writes `build/oracle/report.txt`. Needs `ublock-matches.tsv` and the `regression-testing` `easylist.txt` / `easyprivacy.txt` from github.com/brave/adblock-rust (`data/`) in `build/oracle/`.
- Regenerate project after editing `project.yml`: `xcodegen generate`
- App build: `xcodebuild -project Paddle.xcodeproj -scheme Paddle -configuration Debug -derivedDataPath build/DerivedData -allowProvisioningUpdates build`
- Run: `open build/DerivedData/Build/Products/Debug/Paddle.app`
- Logs: `log show --predicate 'subsystem == "com.walker.Paddle"' --last 5m --info`

## Rules
- A passing `swift test` proves the core only. Do not say the app builds or a feature works unless `xcodebuild` ran and the feature was exercised in the running app this session.
- Resource claims need a measurement (process footprint, WebContent process count), not reasoning from code.
- Keep `README.md`'s config keys and shortcut action names in sync with `PaddleConfig` and `MainMenu`.
