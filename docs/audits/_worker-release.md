# Build / sign / release audit (read-only)

**Tree:** `main` @ `015dc73` (`git rev-list --count HEAD` → **157**).  
**Method this memo:** read `scripts/release.sh`, `project.yml`, entitlements, Info.plist, README/AGENTS/passkeys docs; optional `codesign -d` on the already-installed app. **Did not** run `scripts/release.sh`, `notarytool`, `xcodegen generate`, or Release `xcodebuild`. **This session did not notarize anything.**

**Shipped reference (read-only):** `/Applications/Paddle.app` **0.1.157 (157)**, Developer ID **VB3UP263YT**, hardened runtime, timestamp **Nov 5, 2026**, notarization ticket **stapled** (`codesign -dv`).

**S0:** **None.** Developer ID release gates in `release.sh` are coherent; installed entitlements match the stripped passkeys source; no signing-identity or get-task-allow blocker found in tree.

---

## XcodeGen (`project.yml`) vs `Paddle.xcodeproj`

| Item | `project.yml` | Generated `project.pbxproj` (checked @ 015dc73) | Notes |
|---|---|---|---|
| Source of truth | Yes (`README.md`, `AGENTS.md`) | Generated; do not hand-edit | Regenerate with `xcodegen generate` after `project.yml` edits. |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `0.1.0` / `1` (Debug defaults) | Same on project + target configs | **Release shipping** overrides on `xcodebuild` CLI only (`release.sh`). |
| `DEVELOPMENT_TEAM` | VB3UP263YT | VB3UP263YT | |
| `ENABLE_HARDENED_RUNTIME` | YES | YES | Required for notarization path. |
| `CODE_SIGN_STYLE` | Automatic | Automatic | |
| `CODE_SIGN_IDENTITY[sdk=macosx*]` | Apple Development (app + paddle-mcp) | Apple Development | **Release** uses Manual + `Developer ID Application` via `release.sh` only. |
| `CODE_SIGN_ENTITLEMENTS` | `App/Paddle/Paddle.entitlements` | Same | |
| App Swift flags / isolation | `-disable-dynamic-actor-isolation`, MainActor | Same on Paddle target | |
| `Package.swift` platforms | macOS 27.0 | N/A (SPM) | Aligns with `MACOSX_DEPLOYMENT_TARGET` 27.0. |
| `options.xcodeVersion` | 27.0 | Not mirrored as a single pbxproj key | XcodeGen metadata only. |

**Drift warning:** At this commit, audited signing/version/hardened-runtime fields **match** between `project.yml` and `Paddle.xcodeproj`. Any future `project.yml` change without `xcodegen generate` leaves the checked-in pbxproj stale (Xcode Debug builds would diverge from intent). There is **no** GitHub Actions job to catch drift (`CONTRIBUTING.md`: do not add Actions unless the PR is about CI).

---

## Versioning (`MIN_BUILD`, Debug vs Release)

**Formula (`scripts/release.sh` build step):**

1. `BUILD_NUMBER="$(git rev-list --count HEAD)"`, then floor: `MIN_BUILD_NUMBER=157` if count &lt; 157 (avoids reusing old private-history notarized build **156**).
2. `MARKETING_PREFIX` = first `MARKETING_VERSION` string in `project.yml` (`0.1.0`), strip last `.`-segment → **`0.1`**.
3. `MARKETING_VERSION="${MARKETING_PREFIX}.${BUILD_NUMBER}"` → **`0.1.157`** at HEAD.
4. `CURRENT_PROJECT_VERSION="$BUILD_NUMBER"` → **`157`** (same integer as marketing patch for Release).

**Debug / plain Xcode:** Uses pbxproj defaults **`0.1.0` / `1`** unchanged.

**README / AGENTS:** Document prefix + commit count and MIN **157**; examples still cite `0.1.156` in places — illustrative, not current HEAD count.

**Installed app:** PlistBuddy on `/Applications/Paddle.app` → **0.1.157 / 157**, consistent with formula at commit count 157.

---

## `scripts/release.sh` gates (Developer ID path)

| Step | When | Gate |
|---|---|---|
| **build** | Always | Release `xcodebuild` with `CODE_SIGN_STYLE=Manual`, `DEVELOPMENT_TEAM=VB3UP263YT`, `OTHER_CODE_SIGN_FLAGS=--timestamp`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, overridden `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`; output under `build/ReleaseDerivedData.noindex`. |
| **verify** | Always | `codesign --verify --deep --strict`; Authority Developer ID + team; `CodeDirectory` **runtime** flag; **Timestamp**; same for embedded **`Contents/Helpers/paddle-mcp`**. |
| **entitlements** | Always | XML entitlements readable; **FAIL** if `get-task-allow` present; **PASS** with note if browser passkey entitlement absent or present. |
| **zip** | Always | `dist/Paddle-<version>-<build>-unnotarized.zip` unless `--notarize` (scratch unnotarized zip until staple). |
| **notarize** | `--notarize` | `notarytool` profile `$NOTARY_PROFILE` (default `walker-notary`); must reach **Accepted**; logs on failure. |
| **staple** | `--notarize` | Stapler on app; final `dist/Paddle-<version>-<build>.zip`. |
| **gatekeeper** | `--notarize` | `spctl -a -vv` on **build tree** app (not run on default unnotarized-only flow). |
| **install** | `--install` | Quit Paddle if `pgrep -x Paddle`; stage to `/Applications/.Paddle.app.installing`; verify (and stapler if notarized); atomic swap to `/Applications/Paddle.app`; restore on failure; optional spctl note (unnotarized install warns GK). |

**Env:** `SIGN_IDENTITY` (SHA-1 when multiple Developer ID certs), `NOTARY_PROFILE`.

**Operator risk (`--install`, not a code defect):** `pgrep -x Paddle` matches **any** process whose name is exactly `Paddle`, including a Debug build under `build/…/Debug/Paddle.app`, so `--install` may quit the wrong instance; script comments err toward waiting rather than clobbering a live app (`release.sh` ~211–235).

---

## Entitlements (`App/Paddle/Paddle.entitlements`)

**Active keys (XML):**

- `com.apple.security.device.camera` = true  
- `com.apple.security.device.audio-input` = true  
- `com.apple.security.personal-information.location` = true  
- `com.apple.security.personal-information.addressbook` = true  

**Stripped for notarization (commented in plist source):**

- `com.apple.developer.web-browser.public-key-credential` — pending Apple capability **Request ID 84Z8XFC523** (`docs/passkeys.md` Release note; build **156** history notarized without it).

**Absent (expected for current product):**

- `com.apple.security.get-task-allow` — blocked by release **entitlements** step; mitigated at sign time by `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`.  
- `com.apple.security.app-sandbox` — **not** declared (Developer ID browser model, not Mac App Store sandbox profile).

**Installed app (`codesign -d --entitlements - --xml /Applications/Paddle.app`):** Same four keys as source; **`web-browser.public-key-credential` not present**; **get-task-allow not present**.

**Overlap with privacy audit:** This worker owns **signing/notarize consequence** of passkey strip (`FA-REL-*`). Runtime WebAuthn behavior when entitlement returns belongs under **`FA-SEC-*`**, not duplicated here.

---

## Mac App Store (MAS) readiness

Paddle is engineered for **Developer ID + notarization**, not MAS submission.

| MAS topic | Tree state | Severity |
|---|---|---|
| **App Sandbox** | Not in entitlements | **S4 — Needs Walker** if MAS is ever a goal (separate entitlements, container, networking, extensions). |
| **`LSApplicationCategoryType`** | `public.app-category.productivity` in `Info.plist` | Present; not a blocker by itself. |
| **Distribution** | Manual Developer ID in `release.sh`; Automatic dev signing in Xcode project | No App Store Connect / MAS provisioning in repo. |
| **Private WebKit / personal-use APIs** | `AGENTS.md` allows private API with graceful degradation | Likely **App Review** friction for MAS; out of scope for Developer ID path. |
| **Control bridge Unix socket, extensions, AMO sideload** | Product features under Application Support | MAS policy and sandbox redesign would be required. |
| **CI** | No workflows | No automated MAS/TestFlight pipeline. |

No **Info.plist**-only MAS hard blocker identified beyond the strategic choice to ship unsandboxed Developer ID builds.

---

## Findings

### FA-REL-01 — Passkeys entitlement omitted so notarization succeeds
- **Severity:** S4  
- **Area:** Entitlements / notarization  
- **Mechanism:** `com.apple.developer.web-browser.public-key-credential` commented in `App/Paddle/Paddle.entitlements`; `release.sh` entitlements step treats absence as expected (`release.sh`:151–155); `docs/passkeys.md` Release note.  
- **Evidence:** Paddle.entitlements:13–16; passkeys.md:18–19, 64; installed app entitlements XML (no passkey key).  
- **User impact:** WebAuthn for arbitrary RPs stays off until Apple grants Team VB3UP263YT capability; not a notarize failure.  
- **Disposition:** By design (pending Request **84Z8XFC523**)  
- **Suggested fix shape:** After Apple approval, uncomment entitlement, rebuild with `scripts/release.sh --notarize --install` (Walker-operated).  
- **Tree:** main  

### FA-REL-02 — get-task-allow refused at release
- **Severity:** S4  
- **Area:** Hardened runtime / notarization  
- **Mechanism:** `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` on Release build; entitlements step **FAIL** if `get-task-allow` in signed app (`release.sh`:109, 148–150).  
- **Evidence:** release.sh; README Install §.  
- **User impact:** Debug attach entitlements cannot ship in Release zip; correct for notarization.  
- **Disposition:** OK  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-REL-03 — Build number floor MIN 157
- **Severity:** S4  
- **Area:** Versioning  
- **Mechanism:** `MIN_BUILD_NUMBER=157` when `git rev-list --count HEAD` &lt; 157 (`release.sh`:91–95).  
- **Evidence:** release.sh; README Install §; HEAD count 157 → floor inactive but documented.  
- **User impact:** Prevents CFBundleVersion collision with old notarized **156** from private history.  
- **Disposition:** OK  
- **Suggested fix shape:** None while old build remains relevant.  
- **Tree:** main  

### FA-REL-04 — Release marketing version tracks commit count
- **Severity:** S4  
- **Area:** Versioning  
- **Mechanism:** Prefix from `project.yml` `0.1.0` → `0.1` + `BUILD_NUMBER` → `0.1.N`; `CURRENT_PROJECT_VERSION` = same N on Release CLI.  
- **Evidence:** release.sh:96–111; AGENTS.md Commands; installed app **0.1.157 (157)**.  
- **User impact:** Shipped version monotonic with commits; Debug stays **0.1.0 / 1**.  
- **Disposition:** OK  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-REL-05 — Checked-in pbxproj matches project.yml (regenerate discipline)
- **Severity:** S3  
- **Area:** XcodeGen / project hygiene  
- **Mechanism:** Signing, version defaults, hardened runtime, entitlements path, Swift flags aligned at 015dc73; stale pbxproj possible after yml-only edits without `xcodegen generate`.  
- **Evidence:** `project.yml` vs `Paddle.xcodeproj/project.pbxproj` (MARKETING_VERSION, CURRENT_PROJECT_VERSION, CODE_SIGN_*, ENABLE_HARDENED_RUNTIME, OTHER_SWIFT_FLAGS).  
- **User impact:** Stale pbxproj misleads Debug builds and reviewers; Release still correct if only `release.sh` runs.  
- **Disposition:** Open (process)  
- **Suggested fix shape:** Run `xcodegen generate` after every `project.yml` change before merge; optional local diff habit.  
- **Tree:** main  

### FA-REL-06 — Dual signing model (Automatic dev vs Manual Developer ID)
- **Severity:** S4  
- **Area:** Code signing  
- **Mechanism:** `project.yml` / pbxproj: Automatic + Apple Development; `release.sh`: Manual + `Developer ID Application` on command line only (`release.sh`:19–20, 102–111).  
- **Evidence:** project.yml:18, 55; release.sh header comment.  
- **User impact:** Correct separation: day-to-day Xcode vs shipping script.  
- **Disposition:** By design  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-REL-07 — Release verify covers app + paddle-mcp helper
- **Severity:** S4  
- **Area:** Embedded tool signing  
- **Mechanism:** `verify` step requires Developer ID, runtime flag, and timestamp on `Contents/Helpers/paddle-mcp` (`release.sh`:133–138).  
- **Evidence:** release.sh; `project.yml` embed paddle-mcp with `codeSign: true`.  
- **User impact:** MCP relay cannot ship with weaker signature than main executable.  
- **Disposition:** OK  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-REL-08 — Gatekeeper (`spctl`) only on notarized path
- **Severity:** S4  
- **Area:** Release workflow  
- **Mechanism:** `spctl` in **gatekeeper** step when `--notarize`; default zip is `-unnotarized`; `--install` without notarize documents GK rejection but local open without quarantine (`release.sh`:206–208, 275–292).  
- **Evidence:** release.sh; README Install bullets.  
- **User impact:** Operators must pass `--notarize` for distribution-grade GK; local `--install` alone is intentional dev shortcut.  
- **Disposition:** By design  
- **Suggested fix shape:** None.  
- **Tree:** main  

### FA-REL-09 — `--install` quit uses process name `Paddle`
- **Severity:** S4  
- **Area:** Operator / install step  
- **Mechanism:** `pgrep -x Paddle` + AppleScript quit by bundle id; 30 s wait (`release.sh`:214–235).  
- **Evidence:** release.sh comments ~211–213.  
- **User impact:** May quit a Debug `Paddle` process, not only `/Applications` copy; reduces risk of replacing app while wrong instance runs.  
- **Disposition:** By design (documented operator risk)  
- **Suggested fix shape:** Optional future: match bundle path or main executable path before quit.  
- **Tree:** main  

### FA-REL-10 — MAS not a current shipping target
- **Severity:** S4  
- **Area:** Mac App Store readiness  
- **Mechanism:** No app sandbox entitlement; Developer ID + private features (extensions, control bridge, optional private WebKit); no MAS provisioning in project.  
- **Evidence:** Paddle.entitlements; Info.plist category only; AGENTS.md personal-use WebKit note.  
- **User impact:** None for Developer ID users; MAS would need Walker-led sandbox/capability redesign.  
- **Disposition:** Needs Walker (if MAS desired)  
- **Suggested fix shape:** Separate MAS entitlements profile, sandbox plan, and review strategy — not started in tree.  
- **Tree:** main  

### FA-REL-11 — No automated release CI
- **Severity:** S4  
- **Area:** Release automation  
- **Mechanism:** Release is local `scripts/release.sh`; zero `.github/workflows`; CONTRIBUTING forbids Actions unless CI-focused PR.  
- **Evidence:** Glob workflows; CONTRIBUTING.md:14.  
- **User impact:** Signing/notarize correctness depends on operator machine and keychain profile.  
- **Disposition:** By design (personal project)  
- **Suggested fix shape:** None unless product policy changes.  
- **Tree:** main  

### FA-REL-12 — Installed shipping app matches stripped entitlements policy
- **Severity:** S4  
- **Area:** Shipped artifact consistency  
- **Mechanism:** Read-only `codesign -d --entitlements` on `/Applications/Paddle.app` matches four active source keys; no passkeys; stapled notarization ticket.  
- **Evidence:** codesign session (Nov 5, 2026 timestamp); version 0.1.157.  
- **User impact:** Confirms production copy reflects notarize-friendly entitlements; passkeys still off.  
- **Disposition:** OK  
- **Suggested fix shape:** Re-check after uncommenting passkeys post-approval.  
- **Tree:** main (installed artifact)  

---

## Finding index

`FA-REL-01` … `FA-REL-12`. **No S0** in this worker scope.
