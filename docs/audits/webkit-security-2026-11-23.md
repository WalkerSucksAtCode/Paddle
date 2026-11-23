# Paddle WebKit / navigation / downloads security audit — 2026-11-23

**Tree:** `f3d20559f0d1cdbeab77de60bed2bdf141ed65ad` (`cursor/at-rest-security-agent-77d6`)  
**Method:** Source review only (no live WebKit / no Release run). Focus: WebKit integration, navigation, downloads, userscripts, local files, feeds/filters, autofill, permissions, `Process`/`ditto`.  
**S0 / RCE from web content:** none validated.

Severity: **S1** exploitable chrome/UXSS or arbitrary file write; **S2** local-network SSRF / policy hole with realistic path; **S3** defense-in-depth / spoofing / race; **S4** accepted / by design / blocked elsewhere.

---

## Validated findings

### PAD-WEB-01 — Feed document fetch has no private/local host or redirect guard (S2)

**Where:** `App/Paddle/UI/NewTabFeeds.swift` `download` / `fetch` / `resolve` (~172–187, 135–155); contrast `FeedImagePolicy` + `FeedImageRedirectGuard` (~45–51, 195–197) and `Sources/PaddleCore/DownloadCap.swift` `FeedImagePolicy` (26–90).

**Attack path:**
1. Attacker gets a feed URL into `newTabFeeds` (social engineering in Settings, malicious shared `config.json`, or an http feed the user already trusts).
2. `FeedStore.download` uses ephemeral `URLSession` with **default redirect following** and **no** `FeedImagePolicy` / private-host check.
3. Initial URL or a `302` lands on `http://127.0.0.1:…`, `http://192.168.x.x/`, link-local metadata, etc.
4. Up to 2 MB of the response is parsed; titles/links surface on New Tab (and in `feeds-cache.json`).

**Impact:** App-level SSRF / local-network reconnaissance and content leakage into the New Tab UI. Feed **images** are guarded; **documents** are not.

**Notes:** `PrivateHost` comments admit DNS→private cannot be seen from the hostname alone; feed images share that DNS-rebinding residual (PAD-WEB-02).

---

### PAD-WEB-02 — Feed image policy is hostname-only (DNS rebinding residual) (S3)

**Where:** `Sources/PaddleCore/DownloadCap.swift` `FeedImagePolicy.allows` (29–49); `NewTabFeeds.swift` `FeedImageRedirectGuard` (45–51).

**Attack path:** Feed item image URL is `https://rebinder.attacker/` that resolves (or rebinds) to `127.0.0.1` / RFC1918. Hostname looks public → `allows` returns true → request hits the local service; body capped at 3 MB and decoded as an image.

**Impact:** Local port/service probing and occasional pixel leakage; lower than document SSRF because ImageIO thumbnailing limits useful exfil.

---

### PAD-WEB-03 — Main-frame `file:` allowed from non-file pages on real user gesture; scripted `file:` free once already on `file:` (S2/S3)

**Where:** `App/Paddle/Web/TabWebDelegate.swift` (178–191).

```178:191:App/Paddle/Web/TabWebDelegate.swift
        // Main-frame file:/data:/blob: from page script (no user gesture) must not escape the web sandbox.
        if isMainFrame {
            switch url.scheme?.lowercased() ?? "" {
            case "file":
                let onFilePage = webView.url?.scheme?.lowercased() == "file"
                if (!mainFrameStartedByUser || Self.isRedirect(navigationAction)) && !onFilePage { return (.cancel, preferences) }
            case "data", "blob":
                if !mainFrameStartedByUser || Self.isRedirect(navigationAction) { return (.cancel, preferences) }
```

**Attack paths:**
1. **Web → file (user click):** `https://evil` serves `<a href="file:///Users/…/secret.html">`. Paddle **allows** when `_isUserInitiated` and not a redirect. Chrome/Safari cancel web→file at the browser policy layer; Paddle does not. Residual: WebKit may still refuse the load (unverified this session — no live WebKit). **Defense-in-depth gap** if WebKit’s refusal ever weakens; app is **not** App Sandboxed (`Paddle.entitlements` has no `app-sandbox`).
2. **File → file (no gesture):** After the user opens a local HTML (`OpenableURL` / address bar / Finder), `onFilePage` is true → **scripted** main-frame navigations to other `file:` URLs are allowed. Combined with WebKit’s directory read scope for file documents, a malicious download in `~/Downloads` can often read **sibling** files in that folder.

**Impact:** Local-file XSS / sibling-file read after the user opens attacker HTML; possible web→file if WebKit does not cancel.

---

### PAD-WEB-04 — Subframe `file:` / `data:` / `blob:` never hit the sandbox scheme gate (S3)

**Where:** Same block is wrapped in `if isMainFrame` (`TabWebDelegate.swift` 179). Non-main-frame navigations fall through to `.allow` (197).

**Attack path:** Page embeds `<iframe src="file://…">` or `data:text/html,…`. Paddle policy does not cancel. WebKit normally blocks cross-origin file iframes; `data:` iframes are commonly allowed (opaque). 

**Impact:** Defense-in-depth only for `file:`; `data:` iframes are expected. No chrome UXSS validated.

---

### PAD-WEB-05 — Save panel uses unsanitized `suggestedFilename` (bidi / spoof) (S3)

**Where:** `App/Paddle/Web/Downloads.swift` (290–292). Auto-save path uses `DownloadFilename.sanitized` via `uniqueDestination` (222–224); Ask path sets `panel.nameFieldStringValue = suggestedFilename` **raw**.

**Attack path:** Site triggers download with a name containing bidi overrides / controls (`DownloadFilename` documents the “exe.txt” trick). With `askWhereToDownload`, the panel can show a misleading name; user confirms.

**Impact:** Filename spoofing / social engineering, not path traversal (panel chooses the directory; quarantine flag still applies via `LSFileQuarantineEnabled`).

---

### PAD-WEB-06 — Contact autofill chip not cleared on hide; fill trusts current `https` URL (S3)

**Where:** `App/Paddle/Web/ContactAutofill.swift` `hideContactChip` (192–194) only `removeFromSuperview`; `fillFromContactChip` (230–238) checks scheme `https` but **not** that the host/origin still matches the page that offered the chip. `Tab` URL/`isLoading` observers call `hideContactChip` (1157–1165) but leave `contactChip` and its `groups` intact.

**Attack path:** Chip shown on `https://bank`. Navigation to `https://evil` begins; chip view is removed on URL/`isLoading` change, but an in-flight click on `onFill` (or a chip that was not fully torn down) can still call `__paddleFill` against the new https document with the previously offered groups.

**Impact:** Contact card fields (not passwords) can land on the wrong https origin under a narrow race. Fill still requires a real chip click and isolated world.

---

### PAD-WEB-07 — Userscripts default-match / `<all_urls>` include `file:` (S3 / accepted for power users)

**Where:** `Sources/PaddleCore/UserScript.swift` (45: empty includes → `".*"`; 105: `<all_urls>` → `^(https?|file)://`); injected on the **shared** `WKUserContentController` (`WebEnvironment.reloadUserScripts` 513–522). Extension pages intentionally use a separate controller without userscripts (267–269).

**Attack path:** User installs a headerless script or `@match <all_urls>`. Opens attacker `file:` HTML (or any matching URL). Script runs in page or isolated world per `@inject-into`.

**Impact:** By design for Greasemonkey-style tools; elevates risk of PAD-WEB-03 when combined with local HTML. Not remote UXSS into Settings (SwiftUI) or extension UI.

---

### PAD-WEB-08 — Filter updates use `URLSession.shared` (S4 / privacy)

**Where:** `WebEnvironment.updateFilterLists` (~994–995). Feeds correctly use ephemeral sessions.

**Impact:** Shared cookie jar / cache for https filter hosts. Not WebKit cookies. Low practical impact; prefer ephemeral session for parity with feeds/store downloads.

---

## Rejected candidates (with reasons)

| Candidate | Reason |
|---|---|
| UXSS via `WKScriptMessageHandler` | `ContactAutofillHandler` never returns card data; fill only after native click in isolated world. `PageWorkMonitor` / `PictureInPictureMonitor` only flip tab sleep flags. `PageScriptBridge` loads only WAR `.js` from disk under extension root (path traversal rejected in `ExtensionWebAccess.relativePath` / `read`). |
| Page → extension private pages | Main-frame navigation to another extension id cancelled (`TabWebDelegate` 107–116); popups blocked similarly (723–726). |
| Download path traversal / overwrite of `~/Library/...` | `DownloadFilename.sanitized` strips `/\\:`; destinations under configured Downloads folder or user-chosen save panel; WebKit refuses existing paths; quarantine enabled. |
| Filter / cosmetic CSS injection | `FilterListConverter.classifySelector` drops `{…}` / `:style(`; scriptlets args only via `JSONSerialization` (`ScriptletLibrary.jsonArray`). |
| Autofill → passwords/cards | Classifier rejects password/cc tokens; card stored in Keychain; handler replies `nil`. |
| Favicon SSRF | Candidates limited to hosts the page already loaded; fetch via WebKit sandboxed image loader (`FaviconStore`). |
| Bridge socket takeover | `0600` socket in `0700` folder; `PeerRequirement` requires same-uid signed `paddle-mcp` (team VB3UP263YT). |
| Support dir world-readable secrets | `Paths.tightenExisting` sets support `0700`; contents inherit directory protection. Individual file modes may be 0644 but are not reachable by other users. |
| `StoreInstall` command injection | `Process` runs `/usr/bin/ditto` with argv paths only, empty env, no shell (`StoreInstall.runDitto`). |
| Hardcoded secrets / weak crypto | Extension id salt is random local; CRX3/AMO use proper verify paths; no API keys in tree. |
| `javascript:` address bar | Not in `AddressResolver` passthrough; becomes search (`AddressResolverTests`). |
| `OpenableURL` external `file:` PDFs / arbitrary files | Only listed HTML/webarchive extensions; non-localhost hosts rejected. |
| Reader HTML XSS → chrome | Extractor strips scripts/iframes/attrs; reader web view `allowsContentJavaScript = false`; link navigations cancelled and handed to tab. |
| Error-page HTML injection | `errorPage` escapes title/message/URL; loads in failing origin (userscripts may run — expected). |
| MCP `open_url` silent LAN open | Prompts via `PrivateHost` + `BridgeConsent` (DNS residual same as feeds). |

---

## Attack-surface summary (healthy controls)

| Surface | Control |
|---|---|
| External opens | `OpenableURL` |
| HTTPS-only | Default on; local/onion exempt; loop detection |
| Downloads | Sanitize + unique names + quarantine + scripted-download prompt |
| Userscripts on extension pages | Separate configuration / no shared content controller |
| Cosmetic filters | Style injection skipped; WebKit selector validation path |
| Store packages | Signature + `ZipSafety` + `ditto` + permission normalize |
| Contact autofill | HTTPS main frame, isolated world, native chip, Keychain |
| Control bridge | Off by default; peer code-sign; owner-only socket |

---

## Suggested fix shapes (not implemented this run)

1. **PAD-WEB-01:** Apply `FeedImagePolicy` (or stricter) to feed **document** URLs and attach a redirect guard like images; refuse private/literal LAN after redirect.
2. **PAD-WEB-02:** Optional: resolve and check addresses, or fetch feed images through a non-following client that validates connected endpoints (hard on Apple platforms).
3. **PAD-WEB-03/04:** Cancel **all** `file:` navigations whose source origin is not `file:` (main and subframes); keep `onFilePage` only for same-directory policy if product needs it; never honor user-gesture alone for web→file.
4. **PAD-WEB-05:** `panel.nameFieldStringValue = DownloadFilename.sanitized(suggestedFilename)`.
5. **PAD-WEB-06:** `contactChip = nil` on hide; bind fill to `securityOrigin` / host captured at show time; refuse fill if origin changed.
6. **PAD-WEB-07:** Document that headerless scripts run on `file:`; optional `@match` default to `http/https` only.
7. **PAD-WEB-08:** Ephemeral `URLSession` for filter downloads.

---

## Disposition vs prior audit

Prior privacy pass (`docs/audits/full-readonly-2026-11-05.md`) closed file-mode and autofill design as OK. This pass **adds** feed-document SSRF and navigation policy gaps that were outside that slice. No contradiction with FA-SEC-08/10.
