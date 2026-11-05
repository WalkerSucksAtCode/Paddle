# Full audit — repo hygiene (read-only)

**Commit:** `main` @ `015dc73a2c04beeb7308c3e77e3148dc075f680b`  
**Shipped reference (not launched):** `/Applications/Paddle.app` **0.1.157** (157)

## Method (5 lines)

1. Read-only pass over contributor docs, GitHub metadata, release script, and agent docs at the pinned commit.
2. No Paddle launch/quit, no notarize, no product Swift/plist/yml edits.
3. Re-checked README `config.json` keys vs `PaddleConfig.CodingKeys` (test + table parse) and shortcut action names vs `MainMenu.swift` (regex + manual diff).
4. Cross-checked measured/shipped claims against `docs/measurements.md`, `scripts/release.sh`, and installed app `Info.plist` via `plutil`.
5. PR trees `settings-audit` / `smart-dark-mode` cited only where README diverges on unmerged work.

## Files read

| Path | Role |
|---|---|
| `README.md` | User/config/shortcut canon |
| `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE` | Contribution and legal |
| `AGENTS.md` | Agent/build rules |
| `Package.swift`, `project.yml` | Package and XcodeGen source |
| `.github/CODEOWNERS`, `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/config.yml` | GitHub hygiene (no `workflows/`) |
| `scripts/release.sh`, `scripts/bench.py` | Release and bench tooling |
| `docs/passkeys.md`, `docs/measurements.md`, `docs/lightness-track-b.md` | Long-form claims |
| `Sources/PaddleCore/PaddleConfig.swift` | CodingKeys, init defaults, legacy mosaic keys |
| `App/Paddle/MainMenu.swift` | Menu shortcut action names |
| `Tests/PaddleCoreTests/SiteSettingsTests.swift` | `readmeTableMatchesCodingKeys` |
| `Tests/PaddleCoreTests/MCPTests.swift` | MainMenu action regex (bridge allow-list) |
| `App/Paddle/Extensions/ExtensionHost.swift` | On-demand extension RAM comment |
| `docs/evidence/full-audit-2026-11-05/INDEX.md` | Audit session index |
| `/Applications/Paddle.app/Contents/Info.plist` | Shipped version (read-only) |

**Directory listings:** `.github/` → `CODEOWNERS`, `pull_request_template.md`, `ISSUE_TEMPLATE/config.yml` (no `workflows/`). `scripts/` → `release.sh`, `bench.py`.

**Verify commands run:** `git rev-parse HEAD`, `git rev-list --count HEAD`, `swift test --filter readmeTableMatchesCodingKeys`, Python diff README shortcuts vs `MainMenu` `add(...)` names (119 = 119).

## S0 summary

**No S0 hygiene findings** (nothing that blocks safe fork/PR workflow or misstates a security boundary in the files above).

---

### FA-HYG-01 — No GitHub Actions CI on public main

- Severity: S2
- Area: hygiene
- Mechanism: `.github/` has no `workflows/` directory; `CONTRIBUTING.md:14` forbids adding Actions unless the PR is CI-specific
- Evidence: `ls .github/` at audit time; `CONTRIBUTING.md:14`
- User impact: Fork contributors get no automated `swift test` / build signal on PRs; regressions rely on local runs and Walker's merge review.
- Disposition: Needs Walker
- Suggested fix shape: Add a minimal macOS workflow (or document that CI is intentionally absent and require `swift test` in PR template checklist).
- Tree: main

### FA-HYG-02 — CONTRIBUTING overstates README shortcut test coverage

- Severity: S3
- Area: hygiene
- Mechanism: `CONTRIBUTING.md:16` says README config table **and shortcut action names** are checked by tests; only key parity is automated in `SiteSettingsTests.readmeTableMatchesCodingKeys`
- Evidence: `CONTRIBUTING.md:16`; `Tests/PaddleCoreTests/SiteSettingsTests.swift:146-162`; `rg 'Shortcut action|readme.*shortcut' Tests/` → no test; manual diff at audit (119 menu actions = 119 README names)
- User impact: Shortcut rename drift can ship until someone notices; keys are guarded, action names are not.
- Disposition: Open
- Suggested fix shape: Add a test mirroring `readmeTableMatchesCodingKeys` that parses the README shortcut paragraph and compares to `MainMenu` regex set (same pattern as `MCPTests.mainMenuActionNames`), or narrow CONTRIBUTING wording to "config keys."
- Tree: main

### FA-HYG-03 — README version example lags current commit count

- Severity: S4
- Area: hygiene
- Mechanism: Install section parenthetical uses `0.1.156` while `git rev-list --count HEAD` at `015dc73` is **157** and `scripts/release.sh` floors at `MIN_BUILD_NUMBER=157`
- Evidence: `README.md:21`; `scripts/release.sh:90-95`; `git rev-list --count HEAD` → 157
- User impact: Minor confusion when comparing zip names to the live formula; mechanism text (prefix + count + floor) is still correct.
- Disposition: Open
- Suggested fix shape: Use `0.1.157` or a neutral placeholder (`0.1.<count>`) in the parenthetical.
- Tree: main | shipped 0.1.157

### FA-HYG-04 — AGENTS.md repeats stale Release version example

- Severity: S4
- Area: hygiene
- Mechanism: Agent doc example maps `project.yml` `0.1.0` → `0.1.156` while current main count is 157
- Evidence: `AGENTS.md:34`; `git rev-list --count HEAD` → 157
- User impact: Agents may cite wrong build number in release notes; rule ("do not leave shipped at 0.1.0") remains valid.
- Disposition: Open
- Suggested fix shape: Align example with README/release.sh narrative (`0.1.157` or `<prefix>.<count>`).
- Tree: main

### FA-HYG-05 — measurements.md still claims "330 MB in README"

- Severity: S3
- Area: hygiene
- Mechanism: Historical cleanup note was not updated after README copy changed to measured ~60 / ~190 MB with `docs/measurements.md` cite
- Evidence: `docs/measurements.md:30-32` ("330 MB in README"); `README.md:155` (measured wording, no "330"); `ExtensionHost.swift:1295-1296` points at measurements
- User impact: Readers of measurements.md may think main README still advertises an unmeasured 330 MB figure.
- Disposition: Open
- Suggested fix shape: Reword the 2026-10-19 section to say the old README/comment claim was retired on public main.
- Tree: main

### FA-HYG-06 — `scripts/bench.py` undocumented outside its header

- Severity: S3
- Area: hygiene
- Mechanism: Bench driver exists for bridge-based resource comparison but is not mentioned in `README.md`, `AGENTS.md`, or `CONTRIBUTING.md` (only `scripts/release.sh` is documented for operators)
- Evidence: `scripts/bench.py:1-10`; `rg 'bench\\.py' README.md AGENTS.md CONTRIBUTING.md` → no matches
- User impact: Contributors duplicating measurement methodology or missing the canonical bench entry point.
- Disposition: Open
- Suggested fix shape: One line in `AGENTS.md` Commands and/or `docs/measurements.md` pointing to `scripts/bench.py` prerequisites (`controlBridge`).
- Tree: main

### FA-HYG-07 — Public blank issues enabled alongside security advisory path

- Severity: S4
- Area: hygiene
- Mechanism: `ISSUE_TEMPLATE/config.yml:1` sets `blank_issues_enabled: true`; `SECURITY.md` routes vulns to private advisories
- Evidence: `.github/ISSUE_TEMPLATE/config.yml:1-5`; `SECURITY.md:5-7`
- User impact: Low-severity public issues remain easy to open; security-sensitive reports may still land in public issues unless reporters read SECURITY.md.
- Disposition: Accepted risk
- Suggested fix shape: Optional `config.yml` issue forms for bug/feature; keep security contact link prominent in README (already present).
- Tree: main

### FA-HYG-08 — README vs code sync checks are partial by design

- Severity: S4
- Area: hygiene
- Mechanism: `readmeTableMatchesCodingKeys` passes at `015dc73`; no automated README default-column vs `PaddleConfig.init` parity test (defaults live in Swift only)
- Evidence: `swift test --filter readmeTableMatchesCodingKeys` PASS; `Tests/PaddleCoreTests/ConfigFileTests.swift:295-296` checks `ConfigFile.defaults` keys, not README prose defaults
- User impact: Wrong default in README table could persist until manual review; keys and shortcuts were verified this pass.
- Disposition: Accepted risk
- Suggested fix shape: Optional table-driven test comparing README default column to `PaddleConfig()` for scalar keys.
- Tree: main

### FA-HYG-09 — PR #3 README documents unmerged smart dark mode

- Severity: S4
- Area: hygiene
- Mechanism: `smart-dark-mode` branch README adds `darkMode` values `"smart"` / `"native"` and different `sites.darkMode` field docs vs main `"off"` / `"system"` / `"always"`
- Evidence: `/Users/Walker/Code/Projects/Paddle-wt/smart-dark-mode/README.md:136,159` vs `full-audit-readonly/README.md:136-137,159`
- User impact: None on main; fork readers on PR #3 may assume smart mode is shipped.
- Disposition: Fixed-on-PR
- Suggested fix shape: Merge or rebase PR #3 and reconcile README before public merge.
- Tree: PR #3

### FA-HYG-10 — Oracle ad-block regression harness absent from user README

- Severity: S4
- Area: hygiene
- Mechanism: `AGENTS.md:23` documents opt-in `PADDLE_ORACLE=1 swift test --filter AdblockOracle`; user-facing `README.md` does not mention it
- Evidence: `AGENTS.md:23`; `README.md` (no oracle mention)
- User impact: Intentional split (operator/agent vs end user); contributors may miss the oracle unless they read AGENTS.
- Disposition: Accepted risk
- Suggested fix shape: Optional CONTRIBUTING footnote linking to AGENTS oracle command and data prerequisites.
- Tree: main

### FA-HYG-11 — CODEOWNERS single-owner

- Severity: S4
- Area: hygiene
- Mechanism: `.github/CODEOWNERS:1` assigns `* @WalkerSucksAtCode`
- Evidence: `.github/CODEOWNERS:1`
- User impact: Expected for personal repo; no co-owner review routing on GitHub.
- Disposition: Accepted risk
- Suggested fix shape: None unless Walker adds collaborators (AGENTS forbids write collaborators).
- Tree: main

---

## Re-verification notes (not rubber-stamped)

| Check | Result |
|---|---|
| README config keys ↔ `PaddleConfig.CodingKeys` | **Match** (`readmeTableMatchesCodingKeys` PASS) |
| README shortcut list ↔ `MainMenu` `add(..., "name", …)` | **Match** (119 names; includes `space1`–`space9`, `tab1`–`tab9`, `minimize`) |
| Shipped version vs release script floor | **Consistent** (app 0.1.157; `MIN_BUILD_NUMBER=157`; commit count 157) |
| README `extensionsOnDemand` RAM cite | **Honest** (points to `docs/measurements.md`; aligns with `ExtensionHost.swift:1295-1296`) |
| Install/notarize claims vs `release.sh` | **Consistent** (Developer ID, `--notarize`, `get-task-allow` refusal described in script header/steps) |

## Leftovers (audit worktree, not product defects)

| Item | Size / note | Safe? |
|---|---|---|
| Untracked `docs/audits/_worker-*.md` + `.verify.txt` from parallel audit workers | Small memos | Yes — audit artifacts only |
| Untracked `docs/evidence/full-audit-2026-11-05/` | Index + evidence pointers | Yes |
| `.build/` from local `swift test` in worktree | Gitignored per `.gitignore:1` | Yes — not committed |
| Other agents' Debug Paddle (PID 7716) | Outside repo | Not touched |
