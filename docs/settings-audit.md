# Settings UI audit (2026-11-05)

**App:** `/Applications/Paddle.app` **0.1.157 (157)** (notarized build from `015dc73`).  
**Repo baseline:** `origin/main` @ `015dc73`.  
**Evidence:** [`docs/evidence/settings-audit-2026-11-05/`](evidence/settings-audit-2026-11-05/) (one full-window PNG per pane).  
**Method:** Code inventory (`SettingsPane`, `*Pane.swift`, `PaddleConfig`, README `config.json` table); live UI via ⌘, and `paddle://settings/<pane>` navigation; config cross-check via control-bridge `read_config` through `Contents/Helpers/paddle-mcp` (Cursor’s `paddle` MCP namespace did not attach in the cloud agent session; the socket was on and the helper worked).

Walker's live `config.json` was used for value checks (not factory defaults). Spot-checks below call out when the UI correctly reflected that file.

## Sidebar inventory (code = live)

| # | Pane | URL alias | Screenshot |
|---|------|-----------|------------|
| 1 | General | `paddle://settings/general` | [general.png](evidence/settings-audit-2026-11-05/general.png) |
| 2 | Appearance | `…/appearance` | [appearance.png](evidence/settings-audit-2026-11-05/appearance.png) |
| 3 | Profiles | `…/profiles` | [profiles.png](evidence/settings-audit-2026-11-05/profiles.png) |
| 4 | Tabs & Memory | `…/tabsMemory` (`tabs`, `memory`) | [tabsMemory.png](evidence/settings-audit-2026-11-05/tabsMemory.png) |
| 5 | Mosaic | `…/mosaic` | [mosaic.png](evidence/settings-audit-2026-11-05/mosaic.png) |
| 6 | Privacy & Blocking | `…/privacy` (`blocking`) | [privacy.png](evidence/settings-audit-2026-11-05/privacy.png) |
| 7 | Sites | `…/sites` | [sites.png](evidence/settings-audit-2026-11-05/sites.png) |
| 8 | Extensions | `…/extensions` | [extensions.png](evidence/settings-audit-2026-11-05/extensions.png) |
| 9 | Shortcuts | `…/shortcuts` | [shortcuts.png](evidence/settings-audit-2026-11-05/shortcuts.png) |
| 10 | Advanced | `…/advanced` | [advanced.png](evidence/settings-audit-2026-11-05/advanced.png) |

All ten panes opened without crash or blank content. Search sidebar and ⌘1–⌘9 hint match `SettingsTabView`.

## Findings

Severity: **P0** crash/data loss · **P1** wrong behavior or doc lies · **P2** missing UI for documented keys · **P3** UX/a11y · **Info** intentional file-only keys.

| Pane | Control / area | Config key(s) | Status | Sev | Notes |
|------|----------------|---------------|--------|-----|-------|
| General | When Paddle opens | `onLaunch` | OK | Info | UI showed **Open a new window**; matches live config (`newWindow`), not README default `restore`. |
| General | Search engine / suggestions | `searchTemplate`, `searchSuggestTemplate` | OK | Info | UI **Google** + suggestions on; matches live config. |
| General | New Tab section order | `newTabSections` | OK | Info | UI order matched live config (differs from README default). |
| General | Show bookmarks bar | *(not in config.json)* | OK | Info | Toggle persists outside `config.json` (not in README table — intentional). |
| General | Downloads folder / ask | `downloadFolder`, `askWhereToDownload` | OK | Info | Matched live config (`askWhereToDownload: true`). |
| Appearance | Theme / tint / chrome | `theme`, `accentColor`, `chromeTint`, `chromeTintStrength`, `appearance`, `darkMode`, `highContrastTabs`, toolbar toggles | OK | Info | **Forest Custom**, green tint **4%**, dark appearance, dark mode **Always**, high-contrast tabs and always-show downloads/close buttons matched `read_config`. |
| Tabs & Memory | Put background tabs to sleep | `tabSleepAfterMinutes` | OK | Info | UI **30 minutes**; live config `30` (README default `5`). |
| Tabs & Memory | Freeze after | `tabFreezeAfterMinutes` | OK | Info | UI **2 minutes**; matches config and README default. |
| Mosaic | All mosaic keys in README table | `mosaic*` | OK | Info | Dense scrollable form; controls map to `MosaicPane` `saveKey` bindings. Optional `mosaicFreezeAfterMinutes` / `mosaicSleepAfterMinutes` use “Same as tabs” pickers. |
| Privacy | HTTPS / speculative / blocking / scriptlets / lists | `httpsOnly`, `speculativeLoading`, `contentBlocking`, `scriptlets`, `filterLists`, `filterUpdateDays` | OK | Info | **Weekly** picker = `7` days per code; lists and toggles rendered. |
| Privacy | Contact autofill | `contactAutofill` | OK | Info | Toggle + Keychain card; off in live config. |
| Privacy | History | `historyDays` | OK | Info | **1 year** = 365; matches README default label. |
| Sites | Table columns | `sites`, `siteUserAgents` | OK | Info | Rows match config hosts; Proton hosts show **Custom** UA from `siteUserAgents`. |
| Sites | Pane subtitle (header) | — | **Fixed in PR** | P1 | Previously claimed per-site **camera**; camera/mic are **This session** only (footer). Copy updated in `SettingsViews.swift`. |
| Sites | Settings search keywords | `sitePersonas` | Gap | P2 | Search finds Sites for “persona” but no control writes `sitePersonas` (personas are file-only except built-in Proton UA). |
| Extensions | Per-folder switches / toolbar / private | `extensions`, `extensionToolbar`, `extensionsInPrivate`, `extensionCompat.*` | OK | Info | Matches config extension map. |
| Extensions | Store updates | `extensionUpdates` | OK | Info | Toggle present on default profile. |
| Extensions | On-demand unloading | `extensionsOnDemand` | Gap | P2 | Documented in README (`true` default); **no Settings control**. Must edit `config.json`. README row clarified in this PR. |
| Advanced | Developer / UA / bridge | `developerTools`, `userAgentSuffix`, `controlBridge`, `controlBridgeScripts` | OK | Info | Matched live config (bridge + scripts on). Problems section empty. |
| Advanced | Tidy / unknown keys | — | OK | Info | “8 keys repeat their default” with Tidy… available. |
| Privacy / Advanced | Trusted filter lists | `trustedLists` | Gap | Info | README documents `[]`; no UI (no `trusted-*` scriptlets yet). File-only is reasonable. |
| Shortcuts | Keyboard map | `shortcuts` | OK | Info | Edits `shortcuts` object; live file `{}`. |
| Profiles | Overrides | `profiles.json` | OK | Info | Not `config.json`; UI explains shared vs per-profile keys. |
| Mosaic / Tabs | Scroll length | — | UX | P3 | Mosaic especially long; single scroll region works but hunt-heavy (no trap observed). |
| Privacy | Speculative loading | `speculativeLoading` | UX | P3 | No in-UI note that private windows ignore it (README states it). |

### config.json keys with no Settings control (expected vs gap)

| Key | README | Settings UI | Verdict |
|-----|--------|-------------|---------|
| `shortcuts` | Yes | Shortcuts pane | OK |
| `trustedLists` | Yes | None | Info (feature not implemented) |
| `sitePersonas` | Yes | None (search keyword only) | P2 — add UI or drop from search keywords |
| `extensionsOnDemand` | Yes | None | P2 — add Extensions toggle or keep README “file only” |
| `extensionCompat` | Yes | Extension Details (partial) | OK |
| Profile-only overrides | README § profiles | Profiles pane | OK |

All other keys in the README `config.json` table have a corresponding control in General, Appearance, Tabs & Memory, Mosaic, Privacy, Sites, Extensions, Shortcuts, or Advanced (including nested `sites.*` fields in the Sites table).

## Live vs defaults (not bugs)

These differ from README defaults but matched `read_config` and the UI on 2026-11-05: `onLaunch`, `searchTemplate` / `searchSuggestTemplate`, `tabSleepAfterMinutes`, `newTabSections`, `newTabFeeds`, `theme`, `chromeTint*`, `darkMode`, `appearance`, `alwaysShowTabCloseButtons`, `alwaysShowDownloadsButton`, `askWhereToDownload`, `controlBridge*`, rich `sites` / `extensions` / `extensionToolbar`.

## Prioritized fix list

1. **P1 (done in PR):** Sites pane header subtitle must not imply per-site camera control.  
2. **P2:** Add Settings control for `extensionsOnDemand` (Extensions > memory/on-demand) or keep README file-only note (partial fix in PR).  
3. **P2:** Either add `sitePersonas` editor (Sites or Advanced) or remove `sitePersonas` from Settings search keywords until UI exists.  
4. **P3:** Short helper text on Privacy speculative-loading toggle: disabled in private windows.  
5. **P3:** Consider Mosaic pane section jump links or collapsible sections (length only).  
6. **Info:** Document that bookmarks bar is session/UI state, not a `config.json` key (README already omits it).

## Verification notes

- No Settings toggles were changed during the audit (read-only navigation).  
- `paddle_state` reported app **0.1.157 (157)** with Settings tab on `paddle://settings/advanced`.  
- Code fix in this PR: `SettingsViews` Sites summary only; `swift test` run on branch.
