# Track B lightness (ported to public `main`)

Reference for what landed from the old private-history branch `cursor/paddle-lightness-track-b-7085` (tip `5097385c`), ported onto public [WalkerSucksAtCode/Paddle](https://github.com/WalkerSucksAtCode/Paddle) without merging unrelated histories.

**Shipped (product, system WebKit):**

| ID | Item | Notes |
|---|---|---|
| P1 | SPA Back scroll on timeline sites | `ScrollRestoreScript` + deferred zoom on back/forward commits (~900 ms). |
| P5 | Orphan service-worker grace | **30 s** (`AppModel.orphanWorkerGrace`). |
| P6 | Notify/freeze cost copy | Settings + README; defaults unchanged. |
| P1 ext | Extension `tabs` mute | `tabs.update({ muted })` / `tab.mutedInfo` wired to Paddle mute. |
| Passkeys | Coordinator + docs | `BrowserPasskeyCoordinator`; entitlement gated until Apple Request ID **84Z8XFC523**. |
| P2 | Memory re-baseline | **Blocked** — see `docs/measurements.md` 2026-11-05 note. |
| P4 | Tab-switch profiler | **No chrome collider found** on installed build without Instruments attach. |
| P3 | Threaded scroll-driven transform | Test HTML loads; busy-loop orange vs blue not re-run in app. |
| P7 | `mosaicStaysReady` default | Unchanged (unmeasured). |
| P8 | Scriptlet split | Already optimized; left as-is. |

**Not done (explicitly out of scope):**

- **P9–P11** — MiniBrowser/WebKit fork, upstream layout thread, embedding WebKit in Paddle, DYLD / library-validation weakening.
- **P12–P13** — BFCache without extra WebContent; per-registration service-worker stop (research only).

Engine layout-smooth-while-JS-busy remains a WebKit/Safari concern, not a Paddle chrome knob.
