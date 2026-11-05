# Evidence index — full read-only audit 2026-11-05

**Integrated report:** [`docs/audits/full-readonly-2026-11-05.md`](../../audits/full-readonly-2026-11-05.md)

**Trees:** main `015dc73` (`cursor/full-audit-readonly-9af1`); PR #2 `73d02c6`; PR #3 `aa33b81`.
**Shipped:** `/Applications/Paddle.app` 0.1.157 (157) — not launched, not replaced this pass.

## Live UI (this session)

**None taken.** Settings-audit Debug Paddle was already running (PID 7716, bundle id `com.walker.Paddle`). Launching another Debug or Release copy would steal that instance. `paddle` MCP namespace failed tool discovery, so `window_snapshot` / `page_snapshot` were unavailable.

Do not treat SwiftUI as visual proof. Findings that need a shot are labeled **UNVERIFIED visually** or cite prior-art PNGs below.

## Prior-art shots (read-only cite; not copied into this folder)

### PR #2 Settings (`/Users/Walker/Code/Projects/Paddle-wt/settings-audit/docs/evidence/`)

- `settings-ux-audit-2026-11-05/` — general, appearance, profiles, tabsMemory, mosaic, privacy, sites, extensions, shortcuts, advanced, search-hints
- `settings-audit-2026-11-05/` — after / `before/` / `before-round-2/` pane PNGs
- `extension-update-ux-2026-11-05/extensions-after-check.png`

### PR #3 Smart dark (`/Users/Walker/Code/Projects/Paddle-wt/smart-dark-mode/docs/evidence/smart-dark-mode-2026-11-05/`)

- `probes.txt`, `code-editor.png`, `map-canvas.png`, `light-article.png`, `native-dark.png`

## Worker memos

`docs/audits/_worker-*.md` plus `_worker-*.verify.txt` (not screenshots).

## Parent independent checks (not screenshots)

- Installed entitlements: camera, audio-input, location, addressbook only (`codesign -d --entitlements` on `/Applications/Paddle.app`)
- Installed version 0.1.157 / 157
- `httpsOnly` default `true` (`PaddleConfig.swift:489`) — corrects FA-SEC-12
