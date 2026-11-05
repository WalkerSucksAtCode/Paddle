# Tabs / mosaic / navigation audit (read-only)

**Tree:** `main` @ `015dc73`. **Shipped reference:** `/Applications/Paddle.app` (not launched this pass; live session PID conflict).  
**Method:** code and docs only — no Paddle launch, no new RAM measurements (numbers from `docs/measurements.md` cited only as **unverified-this-session** where used).  
**S0:** **None.** No crash-only path, session corruption, or security defect identified in scoped subsystems.

**Already green (parent):** Track B `ScrollRestoreScript` + 900 ms back/forward deferral for `applySiteZoom`; service-worker orphan grace **30 s**; README **Instant Back vs RAM** trade accepted; `resumeMediaOnSelect` default **off** with tests.

---

## Executive summary

Awake **single-pane** tab switches are engineered as **opacity flips** over a small mounted set (`BrowserModel.mountedWebTabs` → `MountedWebPages`), with optional **`_doAfterNextPresentationUpdate:`** wait (300 ms cap). **`BrowserModel.activate`** always **`Tab.wake()`** / **`Tab.unfreeze()`** and clears the previous tab’s BFCache via **`PrivateAPI.callVoid("_clearBackForwardCache", on:)`**. Background tabs **freeze** (`Tab.freeze()` → `_suspendPage:`) then **sleep** (`Tab.sleep()` drops `WKWebView`) under **`AppModel.sweepSleepingTabs`** and **`TabSleepPolicy`**. **Mosaic** panes use per-pane **`WebContainer`** (all panes stay in the window); sleep policy treats mosaic panes as one unit (`TabSnapshot.mosaic`). **Back/forward scroll** is page-world **`ScrollRestoreScript`**; per-site zoom after BF navigations is deferred in **`Tab.applySiteSettingsAfterCommit`**. **PiP** is **`PictureInPictureScript`** + **`PictureInPictureMonitor`** → **`Tab.isInPictureInPicture`** (busy / no sleep). **Downloads** are **`DownloadStore`** / **`DownloadDelegate`** (in-memory list). **Find** is **`BrowserModel.find`** + **`FindBar`** / menu **`paddleFind*`**. **Spaces/groups** live in **`BrowserModel`** stashes + **`SessionRecord`**.

Main **instant-switch** risk: a tab can stay **mounted but frozen** (not selected) and pay **unfreeze + presentation wait** on return. **Instant Back** is intentionally weakened when leaving a tab (BFCache clear on select and on freeze).

---

## Mechanism map

| Concern | Primary calls / types | Notes |
|--------|------------------------|-------|
| Select tab | `BrowserModel.select` → `activate` → `Tab.wake`, mosaic `others` wake | `SwitchTrace.activated` logs `live` / `frozen: resumed` / `cold: page created` |
| Mount / show page | `mountedWebTabs`, `MountedWebPages`, `WebContainer` | Opacity not `isHidden`; detached tabs throttled |
| Freeze | `AppModel.sweepSleepingTabs` → `TabSleepPolicy.decide` → `Tab.freeze` | Also `_clearBackForwardCache` inside `freeze()` |
| Sleep | `Tab.sleep` | Saves `interactionState`, drops view, `exitPictureInPictureIfNeeded` |
| BF scroll + zoom | `ScrollRestoreScript`, `Tab.pageCommitted` → `applySiteSettingsAfterCommit` | BF: 900 ms delay before `applySiteZoom` |
| Mosaic layout | `MultiPanes`, `PaneLayout`, `MosaicBar` | `mosaicStaysReady` expands mounted set to all panes of previous mosaic |
| PiP | `Tab.togglePictureInPicture`, `PictureInPictureMonitor` | Toggle must not be wrapped in `Task` (user activation) |
| Downloads | `DownloadStore.track`, `DownloadDelegate.decideDestinationUsing` | No resume; retry via `webView.startDownload` |
| Find | `BrowserModel.showFind` / `find`, `FindBar` | Settings tab → `settingsSearchFocusRequest` |
| Spaces | `switchToSpace`, `stashes`, `SessionRecord.space` | Inactive space tabs stashed with views until policy sleeps them |
| Groups | `TabGroup`, `group(of:)`, collapsed skip in `selectNeighbor` | `activate` uncollapses group of selected tab |

---

## Findings

### FA-TAB-01 — Mounted-but-frozen tab can miss “instant” switch
- **Severity:** S2  
- **Area:** tabs  
- **Mechanism:** `AppModel.sweepSleepingTabs` → `TabSleepPolicy.tabsToFreeze` (not `isSelected`) → `Tab.freeze()` while tab remains in `BrowserModel.mountedWebTabs` (`previousSelectedID`, hover successor, `mosaicStaysReady` panes). Reselect: `BrowserModel.activate` → `Tab.wake()` → `Tab.unfreeze()`; `MountedWebPages.Coordinator.wait(for:)` may hold outgoing page up to **`presentationLimit` 300 ms** when presentation callback deferred on suspended page (`Tab.whenLive`).  
- **Evidence:** `BrowserModel.swift` `mountedWebTabs`, `activate`; `Tab.swift` `freeze`/`unfreeze`/`isSuspendedInWebKit`; `WebContainer.swift` `MountedWebPages` `attached`/`wait`; `TabSleepPolicy.swift` `tabsToFreeze` filter `!isSelected`; `AppModel.swift` sweep freeze loop.  
- **User impact:** Switch back to a tab that was still “warm” in the mount set can show the previous page briefly or feel sluggish after idle freeze, despite AGENTS “awake tabs switch instantly” (tab is awake + frozen, not asleep).  
- **Disposition:** Fixed-on-PR  
- **Suggested fix shape:** Exclude `mountedWebTabs` ids from freeze while still mounted, or unfreeze + pre-present on mount set membership change before user selects; measure with `SwitchTrace` category `switch`.  
- **Tree:** `main` @ `015dc73` only (no PR diff).

### FA-TAB-02 — Leaving a tab clears BFCache (Instant Back trade)
- **Severity:** S4  
- **Area:** tabs / back-forward  
- **Mechanism:** `BrowserModel.activate` calls `PrivateAPI.callVoid("_clearBackForwardCache", on: leftView)` when leaving a live previous tab; `Tab.freeze()` clears again before `_suspendPage:`.  
- **Evidence:** `BrowserModel.swift` ~332–336; `Tab.swift` `freeze()` ~603–606; `README.md` “Instant Back vs RAM”.  
- **User impact:** Back to a site left via tab switch may **reload** instead of WebKit in-process BFCache instant restore; scroll may still be restored via `ScrollRestoreScript` after reload.  
- **Disposition:** Accepted product limit  
- **Suggested fix shape:** None unless RAM policy changes; document in release notes only.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-03 — Back/forward: zoom defer vs scroll restore window
- **Severity:** S3  
- **Area:** tabs / back-forward  
- **Mechanism:** `TabWebDelegate` → `Tab.pageCommitted()` sets `applySiteSettingsAfterCommit(backForward: true)` → **900 ms** `Task.sleep` then `applySiteZoom()` / `applySiteDarkMode`. `ScrollRestoreScript` `schedule()` reapplies scroll at 0–5500 ms and ignores untrusted layout scroll from zoom reflow (comment in script). Residual race if zoom applies after restore window or site resets column after 900 ms.  
- **Evidence:** `Tab.swift` `pageCommitted`, `applySiteSettingsAfterCommit`; `ScrollRestoreScript.swift` `schedule` / `pagehide`/`pageshow`; `AGENTS.md` deferral note.  
- **User impact:** On zoomed timeline sites, Back may still jump scroll if site mutates DOM after Paddle’s restore pass.  
- **Disposition:** Monitor (Track B mitigation in place)  
- **Suggested fix shape:** Tie zoom apply to restore token from page script message, or extend deferral when `worth(snap)` active.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-04 — Cold (sleeping) tab switch is not instant by design
- **Severity:** S4  
- **Area:** tabs  
- **Mechanism:** `Tab.wake()` creates `WKWebView`, `attach`, `showWakeCover` until snapshot shows content or **3 s** cap; restores `interactionState` or loads URL. Not covered by “awake tab” rule.  
- **Evidence:** `Tab.swift` `wake`, `showWakeCover`, `watchWakeCover`; `SwitchTrace` state `cold: page created`.  
- **User impact:** First select after sleep shows backdrop until paint; history restored but not BFCache-instant.  
- **Disposition:** Accepted  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-05 — Mosaic: all panes stay window-attached (no MountedWebPages detach)
- **Severity:** S3  
- **Area:** tabs / mosaic  
- **Mechanism:** `BrowserView.splitOrSingle` uses `MultiPanes` → `WebContainer` per pane; all `visibleTabs` panes live in hierarchy (opacity 0 when zoomed/narrow). `BrowserModel.activate` wakes every `others(of:)` pane. Sleep policy groups mosaic in `TabSleepPolicy.decide` / `asOne`.  
- **Evidence:** `BrowserView.swift` `splitOrSingle`; `BrowserModel.swift` `visibleTabs`, `activate` loop; `MultiPanes.swift`; `TabSleepPolicy.swift` mosaic `lastActive` sync.  
- **User impact:** Multi-pane layouts keep more WebContent work alive than single-tab mount policy; pane focus switch is fast but RAM/CPU higher (no measurement this session).  
- **Disposition:** Accepted trade for mosaic UX  
- **Suggested fix shape:** Optional mount-only-focused-pane mode (product decision).  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-06 — `mosaicStaysReady` keeps full mosaic mounted when leaving
- **Severity:** S3  
- **Area:** mosaic  
- **Mechanism:** `mountedWebTabs` includes all tab ids in previous tab’s split when `config.mosaicStaysReady` and `previousSelectedID` in mosaic — avoids WebKit “hidden” on X-style timelines.  
- **Evidence:** `BrowserModel.swift` `mountedWebTabs` `readyMosaic`; comment re X refresh.  
- **User impact:** Higher mount count when bouncing between mosaic and other tabs; pairs with FA-TAB-01 freeze on mounted panes.  
- **Disposition:** Monitor  
- **Suggested fix shape:** Configurable or tie to `mosaicFreezeAfterMinutes` only when not mounted.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-07 — PiP keeps tab awake; sleep tears down PiP
- **Severity:** S4  
- **Area:** tabs / PiP  
- **Mechanism:** `PictureInPictureMonitor` sets `Tab.isInPictureInPicture`; `Tab.isBusy()` returns true; sweep skips sleep. `Tab.sleep` → `exitPictureInPictureIfNeeded` (`PictureInPictureScript.exit`); `processTerminated` clears flag. `Tab.togglePictureInPicture` requires same-turn JS (`PictureInPictureScript.toggle`).  
- **Evidence:** `PictureInPictureMonitor.swift`; `Tab.swift` `isBusy`, `sleep`, `togglePictureInPicture`; `PictureInPictureScript.swift`.  
- **User impact:** Expected: PiP tab stays loaded; sleeping tab exits PiP.  
- **Disposition:** Accepted  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-08 — Downloads: in-memory list, frozen-tab retry gap
- **Severity:** S3  
- **Area:** downloads  
- **Mechanism:** `DownloadStore.track`; list not persisted (`Downloads.swift` comment). `DownloadStore.retry` skips `Tab.owning` web views with `isSuspendedInWebKit` when picking `startDownload` webView.  
- **Evidence:** `Downloads.swift` `track`, `retry`, `DownloadDelegate.decideDestinationUsing`; `Tab.swift` suspend guards.  
- **User impact:** Failed download retry may no-op if only frozen tabs remain in window until user selects a live tab.  
- **Disposition:** Fix candidate (edge)  
- **Suggested fix shape:** `unfreeze()` on chosen tab before `startDownload`, or queue retry.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-09 — Find-in-page: live web view only; per-keystroke search
- **Severity:** S4  
- **Area:** find-in-page  
- **Mechanism:** `BrowserModel.find` → `WKWebView.find(_:configuration:)`; `FindBar` `onChange(of: model.findText) { model.find() }`. Settings tab: `showFind` bumps `settingsSearchFocusRequest`. Menu: `BrowserWindowController.paddleFind` / `findStep`.  
- **Evidence:** `BrowserModel.swift` find section; `BrowserView.swift` `FindBar`; `BrowserWindowController.swift` find selectors.  
- **User impact:** Heavy pages may stutter while typing find string; asleep tab find runs after wake creates view (empty until loaded).  
- **Disposition:** Accepted / polish backlog  
- **Suggested fix shape:** Debounce find 100–150 ms.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-10 — Spaces: stashed tabs retain web views until sleep sweep
- **Severity:** S3  
- **Area:** spaces  
- **Mechanism:** `switchToSpace` stashes active space tabs in `stashes` (comment: keep web views per sleep policy); only active space `activate` runs. Hidden-space tabs still in `AppModel.allTabs` for sweep.  
- **Evidence:** `BrowserModel.swift` `switchToSpace`, `stashes`; `Session.swift` `SpaceRecord`; `AppModel.swift` `allTabs` / sweep.  
- **User impact:** Many spaces with awake background tabs consume RAM until idle sleep (policy timers); not a functional bug. RAM **unverified-this-session** (`docs/measurements.md`).  
- **Disposition:** Accepted with policy knobs  
- **Suggested fix shape:** Optional “sleep tabs in inactive spaces immediately”.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-11 — Tab groups: collapsed groups skipped in keyboard neighbor select
- **Severity:** S4  
- **Area:** spaces / groups  
- **Mechanism:** `BrowserModel.selectNeighbor` skips tabs whose `group(of:)?.isCollapsed`; selecting a tab in collapsed group sets `group.isCollapsed = false` in `activate`. Session stores `TabGroupRecord`.  
- **Evidence:** `BrowserModel.swift` `selectNeighbor`, `activate`; `Session.swift` groups on `WindowRecord`.  
- **User impact:** Expected navigation semantics; no defect.  
- **Disposition:** Accepted  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73`.

### FA-TAB-12 — `resumeMediaOnSelect` default off (AGENTS compliant)
- **Severity:** S4  
- **Area:** tabs  
- **Mechanism:** `PaddleConfig.resumeMediaOnSelect` default `false`; `MountedWebPages.updateMedia` only suspends/resumes when true; `BrowserView` passes `model.config.resumeMediaOnSelect`.  
- **Evidence:** `PaddleConfig.swift`; `WebContainer.swift` `MountedWebPages`; `ConfigTests.resumeMediaOnSelectDefaultsToOff`.  
- **User impact:** Tab switch does not start/stop media unless user enables setting.  
- **Disposition:** Accepted (requirement met)  
- **Suggested fix shape:** N/A.  
- **Tree:** `main` @ `015dc73`.

---

## Out of scope (per brief)

Content blockers, extensions, Settings panes (except Settings-tab find redirect).

---

## Verify artifact

See `_worker-tabs.verify.txt`.
