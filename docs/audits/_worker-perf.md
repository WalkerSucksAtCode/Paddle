# Performance / memory audit (read-only)

**Tree:** `main` @ `015dc73` (Track B lightness port). **Shipped reference:** `/Applications/Paddle.app` 0.1.157 (not exercised this pass).  
**Method this memo:** code and docs only — no `footprint` run, no new processes started (live daily-driver session preserved).  
**S0:** **None.** No crash, data-loss, security, or notarize-path blocker identified in RAM/observer/injection scope.

---

## Executive summary

Paddle’s RAM story is mostly **system WebKit process accounting** (tabs, extensions, service workers, BFCache/prewarm “other”) plus **policy knobs** (sleep/freeze, on-demand extensions, orphan-worker termination). `AppModel` couples a **60 s sleep sweep** (freeze → sleep, extension parking, orphan workers) with an **optional 5 s memory sampler** gated on visibility and `showTabMemory` / Activity readouts. Several large MB claims live only in **code comments** or a **Debug** on-demand measurement; `docs/measurements.md` (2026-11-05) honestly states the **2026-10-15 footprint gate was not re-run** after Track B. Apple engine layout / BFCache / per-registration worker stop remain **out of scope** (`docs/lightness-track-b.md` P9–P11, P12–P13).

---

## Sleep / freeze policy vs memory sampling (`AppModel`)

| Mechanism | Interval / trigger | What it does | Perf note |
|---|---|---|---|
| `sweepTimer` | 60 s (+10 s tolerance) | `sweepSleepingTabs()`, history prune, filter check, extension update check | Each sweep may `await tab.isBusy()` per awake tab (WebKit JS round trip). CPU sleep sampling runs inside sweep when any profile has `cpuSleepPercent > 0`. |
| `DispatchSourceMemoryPressure` | warning / critical | Sleep all eligible tabs, `trimWebKitMemory()`, `malloc_zone_pressure_relief` | Aggressive discard; freeze stage skipped when `memoryPressure: true`. |
| `stopOrphanServiceWorkers` | Every sweep | After **30 s** grace (`orphanWorkerGrace`), `_terminateServiceWorkers` on shared pools | Grace shortened Track B (was 45 s in older baseline comments). |
| `parkIdleExtensions` | Every sweep | Unloads on-demand extensions idle **5 min** off their sites (`ExtensionHost.onDemandIdle`) | Savings **MEASURED** under `docs/measurements.md` §2026-10-19 (Debug build). |
| `sampleTimer` | 5 s (+1 s tolerance) | `measureMemory()` | Only while `NSApp.isActive` and (`memoryReaders > 0` or `showTabMemory` + visible window). |
| `samplerObservers` | activation / occlusion | `updateSampler()` | Stops 5 s timer when app inactive or readout hidden — avoids idle sampling cost. |
| `powerObservers` | Low Power / thermal | Tightens `TabSleepPolicy.adjusted(for:)`; may sweep + trim immediately | User `0` timers stay off. |
| `appResignedActive` | resign active | `WebKitLowMemory.post()` → `notify_post("org.WebKit.lowMemory")` | **Global WebKit signal** (other apps’ web views too). Gmail trim **MEASURED** in comment on `ProcessMemory.swift` / `WebKitLowMemory` (2026-11-04 one-off, not a `measurements.md` section). |

**Policy source:** `TabSleepPolicy` (`Sources/PaddleCore/TabSleepPolicy.swift`) — freeze before sleep, mosaic grouping, CPU sustain **3 min**, memory-pressure sleep by largest `footprint` first. **`staysLive`** (`keepNotifyingSitesLive` + notification permission + per-site `freeze: auto|never`) keeps tabs from idle freeze/sleep; product tradeoff (P6 copy), not a separate perf defect unless it prevents sleep on hot paths.

**Sampling vs sleep:** `measureMemory()` always builds `ProcessBreakdown` when invoked, but `sampleMemory()` no-ops unless `showTabMemory || memoryReaders > 0`. Sleep sweep ends with `sampleMemory()` after sleeping tabs — updates UI only when readout enabled. Per-tab bytes are **not** written when `showTabMemory` is off (avoids `@Observable` churn).

**Attribution:** `ProcessBreakdown` (`Sources/PaddleCore/ProcessBreakdown.swift`) splits WebContent into tabs / extensions / serviceWorkers / other (BFCache, prewarm, exiting) / helpers. **Engine-retained “other” RAM is not a closable Paddle bug** — see lightness P9–P11.

---

## Service workers

1. **Stuck main-frame load:** `ServiceWorkerWatchdog` (`Sources/PaddleCore/ServiceWorkerWatchdog.swift`) — **6 s** patience, **30 s** cooldown; `StuckServiceWorkers` calls pool-wide `_terminateServiceWorkers`. Correctness/latency fix; side effect: **all sites’ workers in that pool restart on next request**.
2. **Orphan processes:** `AppModel.stopOrphanServiceWorkers` — worker-only WebContent (no views) for **≥ 30 s** → terminate workers. Comment cites **218 MB / 647 MB** retention — **UNVERIFIED** (listed under “Numbers in code comments without a record here” in `docs/measurements.md`, not a dated section).
3. **Research gap:** Per-registration worker stop and BFCache without extra WebContent — **P12–P13 not done** (`lightness-track-b.md`).

---

## On-demand extensions (`extensionsOnDemand`)

- Qualification: `OnDemandExtension.sitePatterns` — site-scoped content scripts, no always-on permissions (`Sources/PaddleCore/OnDemandExtension.swift`).
- Parking: `ExtensionHost.parkIdleExtensions` from sleep sweep; reload on tab navigation via `loadOnDemand`.
- **MEASURED:** `docs/measurements.md` §**2026-10-19** — New Tab + 5 sites, loaded vs parked extensions row (**58 MB / 193 MB** saved in table; **Debug** build, `paddle_state` sampling). Code comment “~330 MB” without method — doc now calls that out.
- **UNVERIFIED on Release / current extension set:** re-gate before marketing numbers.

---

## Shared `WKUserContentController` script injection (`WebEnvironment.reloadUserScripts`)

Order after `removeAllUserScripts()` (`App/Paddle/Web/WebEnvironment.swift`):

| # | Script / handler | World | Frames | When |
|---|---|---|---|---|
| 1 | `PageWorkScript` + `PageWorkMonitor` | page | all | If any profile `keepPageWorkRunning` |
| 2 | `xrayBridgeScript` (page bridge) | page | all | Always |
| 3 | `ScrollRestoreScript` | page | main only | Always (Track B P1) |
| 4 | `PictureInPictureScript` + monitor | page | main | Always |
| 5 | `ContactAutofillScript` + handler | isolated | main https | `contactAutofill` |
| 6 | `SitePersonaScript` | page | all | Non-empty personas |
| 7 | `user.css` style injection | defaultClient | all | Non-empty `user.css` |
| 8 | underline links CSS | defaultClient | all | `underlineLinks` |
| 9 | `DarkModeScript` | defaultClient | all | Always (large generated script from sites + defaults) |
| 10 | `userscripts/*.js` via `UserScript.wrappedSource` | page or defaultClient | per header | Each file |
| 11 | Filter **scriptlets** (`scriptletScripts`) | per `Scriptlets` build | per rule | `config.scriptlets` + list reload |

**Injection cost:** Scriptlet split **~+6 MB vs +46 MB** per process — **UNVERIFIED** (comment `Scriptlets.swift`, comment-only table). First-load **58 ms vs ~310 ms** with scriptlets — **UNVERIFIED** (`Tab.swift` comment). Extension Latin-1 scripts **15–31 MB** per WebContent — **UNVERIFIED** (`ScriptLatin1.swift` comment). `PageWorkScript` patches `fetch` / XHR / `beforeunload` on every frame when enabled — functional guard for sleep, not measured here.

**Content blocking:** separate `WKContentRuleList` paths (not user scripts); compiled-list size **74 vs 43 MB** claim — **UNVERIFIED** (`FilterListConverter.swift` comment).

---

## Debug vs Release knobs

| Knob | Debug | Release |
|---|---|---|
| `OTHER_SWIFT_FLAGS` `-disable-dynamic-actor-isolation` | Yes (`project.yml` app target **base**) | Same — not Debug-only |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` MainActor (app) | Yes | Yes |
| `PaddleSimulatePower` UserDefaults (`lowPower` / `serious` / `critical`) | `AppModel.readPowerConditions` `#if DEBUG` | Absent |
| Extension / notification `verifySelectors()` | `#if DEBUG` in `ExtensionHost`, `WebsiteNotifications`, `ExtensionControllerDelegate` | Absent |
| Optimizations | Debug DerivedData typical dev build | `build/ReleaseDerivedData.noindex` for 2026-10-15 baseline |

No separate Release-only RAM features found in audited files; **2026-10-15 footprint baseline was Release**; **2026-10-19 on-demand numbers were Debug** — compare like with like before regression claims.

---

## Honesty of `docs/measurements.md` (main tree)

| Section | Status |
|---|---|
| **2026-11-05 Track B** | Explicit **not a regression gate**; idle/8-site `footprint` protocol **not re-run** (would quit live session). Orphan/BFCache MB called **comment-only until re-run**. **Accurate.** |
| **2026-10-19 on-demand** | Full method + table. Labels Debug build. **Accurate** for that scenario. |
| **Comment-only table** | Lists orphan SW, malloc zone, Tab Reddit→Wiki, prewarm, scriptlets, tab-switch ms, etc. **Accurate** that they lack sections. |
| **2026-10-15 baseline** | Release `footprint -f bytes`, 75 s settle, 8-site loaded **587 MB** median main — **MEASURED**; predates scriptlets/Latin-1/on-demand/SW grace — doc warns re-run before gate. |

**Gap (documented, not hidden):** Post–Track B shipped build **153/157** has **no fresh idle/loaded/restored footprint** row. README historical “330 MB” extension claim — superseded by measurements narrative.

---

## Observers and timers (memory-adjacent)

- **Always-on after launch:** 60 s sweep, memory pressure source, accessibility display observer, config file watchers (`ConfigWatcher` — not expanded here).
- **Conditional:** 5 s memory sampler; helper PID rescan **`proc_listallpids` at most every 30 s**, forced when Activity readout open (`ProcessMemory.responsibleFootprints`).
- **Per-tab:** KVO + window notifications on `Tab` for find/sleep UI (separate from AppModel sampler).
- **`resumeMediaOnSelect`:** default off — product rule; skipped unless it added processes (it does not in audited code).

---

## Findings

### FA-PERF-01 — Post–Track B RAM baseline not re-measured
- **Severity:** S2  
- **Area:** Measurements / regression gate  
- **Mechanism:** `docs/measurements.md` §2026-11-05 Release 0.1.161  
- **Evidence:** measurements.md (idle/loaded rows); commit a99bc4f @ `/Applications/Paddle.app`  
- **User impact:** Release footprint row exists; comparison to §2026-10-15 is still confounded by live multi-window session and `controlBridge` on.  
- **Disposition:** Closed (row added; isolated regression gate still optional follow-up)  
- **Tree:** main  

### FA-PERF-02 — Orphan service-worker RAM claims unverified
- **Severity:** S2  
- **Area:** Service workers / WebContent processes  
- **Mechanism:** `AppModel.stopOrphanServiceWorkers` + `orphanWorkerGrace` 30 s; comments at AppModel.swift:1731–1733  
- **Evidence:** measurements.md §2026-11-05 FA-PERF-02 table; AppModel.swift:1708 comment row still comment-only  
- **User impact:** Bounded Reddit close shows ~340 MB total drop by 30 s; **`serviceWorkers` row stayed 0**; 218/647 MB comment magnitudes **UNVERIFIED**.  
- **Disposition:** Open (comment magnitudes only)  
- **Suggested fix shape:** Optional: instrument worker-attributed MB or reproduce comment scenario on a throwaway profile.  
- **Tree:** main  

### FA-PERF-03 — Pool-wide `_terminateServiceWorkers` is coarse
- **Severity:** S4  
- **Area:** Service workers  
- **Mechanism:** `StuckServiceWorkers.release`, `stopOrphanServiceWorkers` — private API on entire `WKProcessPool`  
- **Evidence:** StuckServiceWorkers.swift:21–28; AppModel.swift:1747–1748  
- **User impact:** Brief worker restart on unrelated sites in shared pool; traded for freeing stuck/orphan RAM.  
- **Disposition:** Accepted risk (WebKit API limit; P12–P13 research only)  
- **Suggested fix shape:** None in Paddle until WebKit exposes finer control.  
- **Tree:** main  

### FA-PERF-04 — WebKit “other” / BFCache / prewarm RAM not Paddle-fixable
- **Severity:** S4  
- **Area:** Process model  
- **Mechanism:** `ProcessBreakdown.other`; WebKit retains processes without views/workers  
- **Evidence:** ProcessBreakdown.swift:40–42; lightness-track-b.md P9–P11, P12–P13  
- **User impact:** Activity row “Other” can stay high after navigation; not closed by tab sleep alone.  
- **Disposition:** Out-of-scope (Apple / WebKit engine)  
- **Suggested fix shape:** N/A in app code; fork/embed track rejected.  
- **Tree:** main  

### FA-PERF-05 — Global `org.WebKit.lowMemory` on background
- **Severity:** S3  
- **Area:** Memory trim  
- **Mechanism:** `WebKitLowMemory.post()` from `appResignedActive` — `notify_post` system-wide  
- **Evidence:** ProcessMemory.swift:7–18; AppModel.swift:1757–1759  
- **User impact:** Paddle backgrounding trims **all** running WebKit apps’ caches; frozen Paddle pages ignore signal (comment). Cross-app side effect.  
- **Disposition:** Accepted risk  
- **Suggested fix shape:** Document in Settings/README if users report odd other-browser behavior.  
- **Tree:** main  

### FA-PERF-06 — On-demand extension savings measured on Debug only
- **Severity:** S2  
- **Area:** Extensions  
- **Mechanism:** `ExtensionHost.parkIdleExtensions`; measurements §2026-10-19 Debug DerivedData  
- **Evidence:** measurements.md §2026-11-05 FA-PERF-06 table (Release 0.1.161)  
- **User impact:** **60 MB** New Tab / **95 MB** with five sites on Release (vs **193 MB** Debug with different extension mix).  
- **Disposition:** Closed (Release re-measured)  
- **Tree:** main  

### FA-PERF-07 — Per-page script stack always includes dark mode + scroll restore
- **Severity:** S3  
- **Area:** Script injection  
- **Mechanism:** `WebEnvironment.reloadUserScripts` — `DarkModeScript` + `ScrollRestoreScript` on every navigation context  
- **Evidence:** WebEnvironment.swift:437–503  
- **User impact:** JS parse/eval cost every document start; dark script is large; scroll restore main-frame only. CPU/RAM **UNVERIFIED** (no section).  
- **Disposition:** Accepted risk (product features)  
- **Suggested fix shape:** Optional disable per site only if measured win justifies config surface.  
- **Tree:** main  

### FA-PERF-08 — Comment-only MB/ms claims still drive engineering intuition
- **Severity:** S3  
- **Area:** Documentation  
- **Mechanism:** measurements.md “Numbers in code comments without a record here” (10 rows)  
- **Evidence:** measurements.md:34–49  
- **User impact:** Developers may treat Scriptlets/Tab/WebEnvironment comments as gospel without re-measure.  
- **Disposition:** Open (hygiene — parent measurements owner)  
- **Suggested fix shape:** Promote or delete each comment row when re-run.  
- **Tree:** main  

### FA-PERF-09 — Sleep sweep JS `isBusy()` every minute per awake tab
- **Severity:** S3  
- **Area:** Timers / observers  
- **Mechanism:** `sweepSleepingTabs` Task loop `await tab.isBusy()`  
- **Evidence:** AppModel.swift:1608–1614  
- **User impact:** Background CPU wakeups scale with awake tab count; not RAM but couples to App Nap / power.  
- **Disposition:** Accepted risk  
- **Suggested fix shape:** Coalesce or sample subset if profiling shows cost (Instruments — P4 no collider on shipped build).  
- **Tree:** main  

### FA-PERF-10 — Spare WebContent prewarm (~7 MB) suppressed under power/pressure
- **Severity:** S4  
- **Area:** WebKit process warm  
- **Mechanism:** `WebEnvironment.scheduleProcessWarm` — `_warmInitialProcess` after 800 ms unless constrained/ recent pressure  
- **Evidence:** WebEnvironment.swift:171–188  
- **User impact:** **~7 MB** idle process **UNVERIFIED** (comment); traded for tab-wake latency.  
- **Disposition:** Accepted risk  
- **Suggested fix shape:** None unless footprint proves material at idle.  
- **Tree:** main  

### FA-PERF-11 — `malloc_zone_pressure_relief` on memory pressure
- **Severity:** S4  
- **Area:** App process heap  
- **Mechanism:** AppModel memory pressure handler after tab sleep  
- **Evidence:** AppModel.swift:1438–1439; comment ~24 MB default zone **UNVERIFIED**  
- **User impact:** Small app-process trim; not WebContent RAM.  
- **Disposition:** Accepted risk  
- **Suggested fix shape:** N/A  
- **Tree:** main  

### FA-PERF-12 — Memory sampler uses private WebKit process list with graceful fallback
- **Severity:** S4  
- **Area:** Instrumentation  
- **Mechanism:** `ProcessMemory.snapshot()` `_webContentProcessInfo` etc.  
- **Evidence:** ProcessMemory.swift:40–75  
- **User impact:** Without private API, breakdown degrades (GPU/Networking under helpers); sleep/orphan paths no-op terminate.  
- **Disposition:** Accepted risk (documented graceful degradation)  
- **Suggested fix shape:** N/A  
- **Tree:** main  

---

## IDs issued

`FA-PERF-01` … `FA-PERF-12`. **No S0** in this worker scope.
