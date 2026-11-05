# Measurements

Memory baselines, one section per measured release, newest first. Compare a new build against the latest section
with the same method; the regression threshold is 10 % or 50 MB per scenario, whichever is larger.

## 2026-11-05: Release 0.1.161 (161), notarized `/Applications/Paddle.app` @ a99bc4f

Machine: Mac16,7 (Apple M4 Pro, 48 GB), macOS 27.2 (26B123).

Build: Developer ID notarized Paddle **0.1.161 (161)** at `/Applications/Paddle.app`, commit **a99bc4f** on `main`.
Walker's live `config.json` (content blocking, installed extensions, `controlBridge: true`, New Tab feeds, `darkMode:
always`, `extensionsOnDemand: true` by default). Other non-private browser windows stayed open during **FA-PERF-01**
runs, so `memoryMB.total` and the footprint sum below are **whole-app** totals, not an isolated single-window session
like §2026-10-15 (`controlBridge` was off there). Site #8 uses `https://example.com` instead of the 2026-10-15 local
static file; the rest match §2026-10-15's eight URLs.

### FA-PERF-01 — footprint protocol (idle / 8-site loaded)

Method: dedicated measurement window via the control bridge; **75 s** settle; sum of `footprint -f bytes` over every pid
macOS holds Paddle responsible for (`responsibility_get_pid_responsible_for_pid`), cross-checked against
`paddle_state` → `memoryMB.total` (matched within 1 MB every sample). Fresh launches were not forced between idle
runs (live session). **Restored** (8-tab session restore, one tab awake) was not run — would require replacing the
user's `session.json` during a live profile.

| Scenario | Median MB | Range MB | WebContent processes (approx.) |
|---|---|---|---|
| Idle (2 runs, one blank tab in measure window) | 141 | 141–141 | 3 |
| Loaded (8 sites awake in measure window, 3 runs) | 573 | 569–1021 | 8–9 |

Per-run totals (MB): idle **141**, **141**; loaded **1021**, **569**, **573**. The first loaded run (**1021**) looked
like a compile/warm-up outlier (filter compile or cold WebContent); later runs clustered ~570 MB. Do **not** treat this
as a clean regression gate against §2026-10-15 Release **587** MB without a quit-isolated rerun with `controlBridge`
off and one window.

### FA-PERF-02 — orphan service worker (bounded)

Method: new window, load `https://www.reddit.com/r/popular/`, wait 30 s, close tab, sample `paddle_state` and footprint
sum every 15–60 s for 4 min (`orphanWorkerGrace` is **30 s** in `AppModel`).

| Seconds after close | Total MB | `memoryMB.serviceWorkers` |
|---|---|---|
| 0 | 465 | 0 |
| 15 | 195 | 0 |
| 30 | 126 | 0 |
| 45–240 | 124–126 | 0 |

Total memory fell ~340 MB within 30 s of closing the tab; the **`serviceWorkers` breakdown stayed 0** (WebKit did not
attribute orphan worker RAM to that bucket in this run). The **218 MB / 647 MB** figures in `AppModel.swift` comments
remain **UNVERIFIED** — this session did not reproduce those magnitudes on the worker row.

### FA-PERF-06 — on-demand extensions on Release

Method: toggle `extensionsOnDemand` in `config.json` (not bridge-settable), relaunch Paddle between scenarios, open sites
in a fresh measure window, **75 s** settle, then six `paddle_state` samples every 10 s (drop the first high sample;
median of the rest). Same five awake URLs as §2026-10-19 when noted.

| Scenario | `memoryMB.extensions` loaded / parked | `memoryMB.total` loaded / parked | Saved by parking |
|---|---|---|---|
| New Tab only | 41 / 14 | 207 / 147 | 60 MB |
| New Tab + 5 sites | 41 / 14 | 551 / 456 | 95 MB |

Release parity with §2026-10-19 Debug is **directionally similar** for New Tab only (~60 MB); savings with five sites are
**lower here (95 MB vs 193 MB)**, likely extension set / always-loaded vs on-demand mix (Walker's config disables several
store extensions) and the live multi-window totals above.

Raw probe output (not committed): `build/fa-perf-full.log`, `build/fa-perf-06.json` under a local checkout.

## 2026-11-05: Track B product pass (no full `footprint` protocol)

Shipped on branch `cursor/paddle-lightness-track-b-7085` (Developer ID build **153** at `/Applications/Paddle.app`): `ScrollRestoreScript` Back/SPA scroll restore for timeline sites, orphan service-worker grace **30 s** (was 45 s in code comments' baseline), and Settings/README copy for `keepNotifyingSitesLive` / per-site `freeze` RAM vs missed in-tab notifications.

**Not a regression gate:** a fresh idle / 8-site loaded / restored session using the 2026-10-15 method (`footprint -f bytes`, 75 s settle) was not run — it would have required quitting the user's live session during the pass. Re-run that protocol before comparing to 2026-10-15/19. Orphan-worker and BFCache MB claims below remain comment-only until then.

See also `docs/lightness-track-b.md` for PR #1 scope and out-of-scope engine work (P9–P11 not done).

## 2026-10-19: on-demand extensions (`extensionsOnDemand`), audit branch

Machine: Mac16,7, macOS 27.0.1 (26A434). Paddle 0.1.0 Debug build from `build/DerivedData.noindex` (main at 2fb59f9 plus
the audit's uncommitted fixes), Walker's config and extensions: ClearURLs, Downie and Proton Pass always loaded;
Reddit Enhancement Suite, Enhancer for YouTube and Return YouTube Dislike on demand. One window, no YouTube or Reddit tab.

Method: `paddle_state` through the control bridge every 10 s, six samples, after the numbers settled (the first sample
after a launch or a load runs high and is dropped). "Loaded" is `extensionsOnDemand: false` (every extension started);
"parked" is the default, relaunched so the three start parked. The five tabs: en.wikipedia.org/wiki/WebKit,
news.ycombinator.com, apple.com, developer.apple.com/documentation/webkit, example.com, opened together and all awake.

| Scenario | `memoryMB.extensions` loaded / parked | `memoryMB.total` loaded / parked | Saved by parking |
|---|---|---|---|
| New Tab only | 65 / 14 | 233 / 175 | 58 MB |
| New Tab + 5 sites | 290 / 232 | 935 / 742 | 193 MB |

The saving grows with open pages (about 22 MB per extra web process here: each WebContent process carries the
extensions' content scripts), so it is about 60 MB with one tab and passes 300 MB only at a dozen or so. The earlier
"330 MB" in README and `ExtensionHost.parkIdleExtensions` had no recorded method or tab count.

### Numbers in code comments without a record here

These came from one-off checks named in the comment (tool and date where given); none has a section with its method.
Re-measure before relying on one, and add a section when you do.

| Claim | Where |
|---|---|
| ~+6 MB per process for 6,600 scriptlet user scripts vs +46 MB for one combined script | `App/Paddle/Web/Scriptlets.swift:10` |
| Extension content scripts 15-31 MB per WebContent process, mostly Return YouTube Dislike's 4.3 MB script | `Sources/PaddleCore/ScriptLatin1.swift:6` |
| malloc default zone held ~24 MB unused (vmmap, 2026-10-16) | `App/Paddle/AppModel.swift:1414` |
| Service worker: 218 MB still up 3.5 min after closing Reddit; 647 MB a minute after the benchmark closed its tabs | `App/Paddle/AppModel.swift:1708` |
| 291 MB kept by a WebContent process after Reddit -> Wikipedia | `App/Paddle/Browser/Tab.swift:589` |
| One extra prewarmed WebContent process of about 7 MB; a cold wake's process start 20-40 ms | `App/Paddle/Web/WebEnvironment.swift:171-178` |
| Compiled lists 74 MB instead of 43 MB and ~250 ms with the `(separator.*)?$` tail | `Sources/PaddleCore/FilterListConverter.swift:556` |
| First page load waits 58 ms before scriptlets, ~310 ms with them (warm cache) | `App/Paddle/Browser/Tab.swift:306` |
| ~350 ms per tab switch (TabStrip), 33-118 ms to show a tab (BrowserModel) | `App/Paddle/UI/Tabs/TabStrip.swift:212`, `App/Paddle/Browser/BrowserModel.swift:39` |

The 2026-10-15 baseline below predates later changes (scriptlets, Latin-1 scripts, the service-worker grace period,
on-demand extensions) and its steps are prose, not a script: re-run it before using it as a regression gate.

## 2026-10-15: main (263b85a) against build 49, Safari, Chrome and Firefox

Machine: Mac16,7 (M4 Pro, 48 GB), macOS 27.0.1 (26A434).

Browsers:

| Browser | Version | Setup |
|---|---|---|
| Paddle main | 0.1.0, commit 263b85a, Release build run from `build/ReleaseDerivedData.noindex` | Walker's config with extensions and the control bridge off; content blocking on, as shipped |
| Paddle build 49 | 0.1.0 (49), the installed app, commit 8ef8350 | Same config |
| Safari | 27.0.1 (22625.1.29.11.28) | A separate profile, "Measure", with no extensions |
| Chrome | 155.0.8059.82 | A throwaway profile with no extensions; first-run screens off; window 1280 x 900 |
| Firefox | 158.0 (build 20261007201254) | A throwaway profile with no extensions; first-run screens off; a separate instance (`-no-remote`) |

No browser had extensions, so these numbers don't answer how Paddle compares with Chrome or Firefox as people
actually run them, with extensions.

### Results

Memory is in MB (MiB): the median over runs, with the range in brackets.

| Browser | Idle | Loaded (8 sites) | Loaded - Idle | Processes, idle / loaded (page processes) |
|---|---|---|---|---|
| Paddle main | 64 (62-66) | 587 (578-593) | 523 | 2-3 / 11 (0 / 8) |
| Paddle build 49 | 60 (60-61) | 589 (584-612) | 529 | 2 / 11 (0 / 8) |
| Safari | 306 (one run) | 845 (793-854) | 540 | 10 / 18 (4 / 12) |
| Chrome | 367 (364-369) | 846 (843-847) | 479 | 8 / 19 (4 / 14) |
| Firefox | 839 (837-842) | 1659 (1610-1678) | 819 | 11 / 20 (9 / 18) |

Paddle only, with the 8 sites restored from a saved session (only the selected tab awake): main 208 (207-210),
build 49 200 (194-206).

- **Regression gate: passed.** Main against build 49 is +4 MB idle, -2 MB loaded and +8 MB restored, all far
  inside the threshold.
- **Against the others:** with the 8 sites loaded, Paddle used about 31 % less memory than Chrome or Safari and about
  65 % less than Firefox.
- **Where the gap comes from:** almost all of it is the base cost. Idle, Paddle is 64 MB against 306-839 MB. The
  8 sites themselves cost Paddle 523 MB, more than Chrome's 479 MB (Chrome has no content blocker here and Paddle's
  is on) and less than Safari's 540 MB or Firefox's 819 MB.
- **Safari after closing tabs:** 45 seconds after the 8 tabs closed, Safari still held 625-704 MB, with 9 page
  processes alive (fresh idle: 306 MB, 4). It keeps closed tabs' processes for a while. The other browsers weren't
  measured after closing tabs.

Per-run values (MB), for comparing later runs:

| Browser | Idle | Loaded | Restored |
|---|---|---|---|
| Paddle main | 66, 62 | 593, 578, 587 | 207, 210 |
| Paddle build 49 | 61, 60 | 589, 584, 612 | 206, 194 |
| Safari | 306 (fresh); 625, 681, 704 (after closing tabs) | 793, 845, 854 | - |
| Chrome | 364, 369 | 846, 847, 843 | - |
| Firefox | 837, 842 | 1659, 1610, 1678 | - |

### Method

- One browser ran at a time, launched in the background; nothing else heavy ran meanwhile (no builds).
- Each reading was taken 75 seconds after launch (80 for Chrome and Firefox) with `footprint -f bytes`. It is the sum
  of each counted process's phys_footprint, so memory shared between a browser's processes is counted in each of them.
  footprint's de-duplicated total is 0-23 MB lower.
- Scenarios:
  - Idle: one window with one empty tab. For Chrome and Firefox that was `about:blank`; for Paddle, a new tab; for
    Safari, the profile's Start Page.
  - Loaded: the 8 sites as tabs, all awake.
  - Restored: Paddle only. The 8 sites came from a written `session.json`.
- Sites: Wikipedia's WebKit article, github.com/WebKit/WebKit, MDN's HTML page, BBC News, Hacker News, apple.com,
  Wikipedia's list of web browsers, and a local static page. None of them plays video or sound.
- Runs:
  - Each Paddle build, Chrome and Firefox: Idle twice, Loaded three times, each a fresh launch.
  - Each Paddle build: Restored twice.
  - Chrome and Firefox: one warm-up run each, not counted. Chrome updated itself from 155.0.8059.39 to .82 during its
    warm-up.
  - Safari: one session in the Measure window. Idle once, then three rounds of adding the 8 sites as tabs (by
    AppleScript), reading, closing them and reading again.
- Which processes count:
  - Paddle: the app and every WebKit WebContent, Networking and GPU process that appeared after its launch.
  - Chrome and Firefox: the main process and all its descendants.
  - Safari: the app, plus the processes macOS holds Safari responsible for (`responsibility_get_pid_responsible_for_pid`),
    restricted to `com.apple.WebKit.*` and `com.apple.Safari.*`. Safari's other windows share these processes and
    can't be separated. A window from Safari's "Personal" profile, showing its Start Page, was open throughout, so
    Safari's idle and loaded figures include it; Loaded - Idle doesn't.
- Not counted for any browser: system services the browser caused (Metal shader compiler, ImageIO, video decoders,
  audio helpers, Quick Look, the open panel). For Safari, the only browser where they were recorded, they came to
  140-164 MB. Also not counted: Safari's launchd agents (`com.apple.Safari.History`, `SafariNotificationAgent`).
- Paddle's first idle run of main counted an extra 5 MB Networking process. It appeared after launch, but it may
  belong to another app.
- Window sizes weren't equalized: Paddle and Safari used their default windows, and Chrome used 1280 x 900.
