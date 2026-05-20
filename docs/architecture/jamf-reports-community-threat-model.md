# Threat Model — jamf-reports-community

Repository: `jamf-reports-community` (Python CLI + native macOS Swift app)
Original model: 2026-05-12
Refreshed: 2026-05-17 (post PR-1..PR-9 backlog-burndown sequence)
Refreshed: 2026-05-20 (post PR-16..PR-26 — tiered collection, xlsx-corruption fix, Patch CSV export)
Scope basis: full repo (`app/`, `jamf-reports-community.py`, CI workflows, scripts)

---

## 1. Scope and System Model

### In scope
- Native macOS app under `app/` (Swift 6, SwiftPM, macOS 14+).
- Python single-file CLI `jamf-reports-community.py`.
- Build/release tooling: `app/build-app.sh`, `app/build-dmg.sh`, `app/scripts/build-python-runtime.sh`, `app/python-runtime.lock`.
- GitHub Actions workflows in `.github/workflows/`.
- Per-profile workspaces at `~/Jamf-Reports/<profile>/`.
- User-space LaunchAgents written to `~/Library/LaunchAgents/com.jamfreports.*.plist`.
- **(2026-05-17 addition)** Planned external distribution: notarized DMG **and** PKG installer for delivery to other organizations running their own Jamf Pro / Jamf School deployments.

### Out of scope (referenced, not modeled here)
- The external `jamf-cli` binary (Go, separate repo) — treated as a trusted external dependency once Team-ID code-signature verification passes (`CodeSignVerifier.verify`, `app/Sources/JamfReports/Services/CodeSignVerifier.swift:13`, callers at `OnboardingFlow.swift:234`, `JamfCLIInstaller.swift:541`, and — as of PR-6/PR-9 — at every `Process()` spawn site that targets `jamf-cli`).
- The bundled python-build-standalone runtime — modeled only as a supply-chain edge (SHA-256 pinned in `app/python-runtime.lock`).
- Jamf Pro / School / Protect servers themselves.
- Recipient-org Jamf tenant compromise that is not initiated through this app — covered only at the trust boundary.

### Components and runtime
| Component | Where | Runtime role |
|---|---|---|
| `JamfReports` (GUI) | `app/Sources/JamfReports/App` | User-facing SwiftUI app; spawns `jamf-cli` |
| `main.swift` (daemon mode) | `app/Sources/JamfReports/App/main.swift` | Triggered by LaunchAgent timers; collects + generates |
| `ReportEngine` (native engine) | `app/Sources/JamfReports/Engine/*` | Reads cached JSON, writes XLSX/HTML/CSV |
| `CLIBridge` | `app/Sources/JamfReports/Services/CLIBridge*.swift` | `Process`-based async wrapper for `jamf-cli`; environment hardening; codesign gate (PR-6) |
| `LogRedactor` | `app/Sources/JamfReports/Services/LogRedactor.swift` + `jamf-reports-community.py:3144-3203` | Free-text + JSON credential redaction; 10 patterns; Python ↔ Swift parity (PR-A baseline, PR-7 reuse, PR-9 api_key addition) |
| `SnapshotManifest` | `app/Sources/JamfReports/Engine/SnapshotManifest.swift` + `_rewrite_snapshot_manifest`/`_verify_snapshot_bytes_against_manifest` in Python | SHA-256 manifest covering `jamf-cli-data/*.json` (PR-7) |
| `jamf-reports-community.py` | repo root; copied into `JamfReports.app/Contents/Resources/` by `build-app.sh` (PR-19) | Standalone Python CLI. The app never executes it — `ReportEngine` (native Swift) generates every report. The bundled copy exists only so Settings → "Copy Diagnostic Command" can emit an absolute-path command. |
| LaunchAgents | `~/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.<profile>.<slug>.plist` (`.multi.<slug>` for multi-profile) | Re-invoke daemon mode on each schedule's own cadence. The per-cadence `{hot,warm,cold}` tier model was removed in PR-23; a schedule now carries a `--tiers` flag selecting Refresh / Inventory / Scan collection tiers. |

### Data stores
- `~/Jamf-Reports/<profile>/jamf-cli-data/*.json` — cached snapshots (0600). **Manifest-covered** as of PR-7.
- `~/Jamf-Reports/<profile>/jamf-cli-data/state/<report>.last` — per-report last-successful-fetch timestamps driving the PR-22 tiered-collection `is_due()` gate. Covered by the SHA-256 manifest (schema bumped to v2 in PR-22) so a forged `.last` cannot silently suppress a scheduled fetch — see T-21.
- `~/Jamf-Reports/<profile>/Generated Reports/*.{xlsx,html}` — outputs. **Not** manifest-covered (see T-13).
- `~/Jamf-Reports/<profile>/snapshots/computers/summaries/*.json` — trend history. **Not** manifest-covered (see T-12).
- `~/Jamf-Reports/<profile>/automation/logs/` — per-run stdout/stderr. Redacted at read-time via `RunHistoryService.loadLog` + `RunsView.exportLogFile` (PR-7); raw file on disk untouched.
- `~/Jamf-Reports/<profile>/config.yaml` — column mapping, `jamf_cli.profile`, and the PR-22 `collect_cadence` block (preset + per-report tier/cadence overrides).
- macOS Keychain (managed by `jamf-cli`, not this app) — long-term Jamf API client secret.
- **(2026-05-17 addition)** Release artifacts in GitHub Releases (`*.dmg`, `*.pkg`, SHA-256 of each).

---

## 2. Trust Boundaries

| # | Boundary | Mechanism / controls observed |
|---|---|---|
| TB-1 | User UI ↔ on-disk workspace | `ProfileService.isValid` regex `^[a-z0-9][a-z0-9._-]*$` enforced at every path-construction site; `WorkspacePaths` typed constants; `SystemActions.canonicalize` resolves symlinks then `hasPrefix(root + "/")` check (`SystemActions.swift:46-89`). Dotted-slug rejection added in PR-3 (S-03). |
| TB-2 | App ↔ `jamf-cli` subprocess | `CLIBridge.environmentForJamfCLI()` pins minimal env (`PATH`, `HOME`, `LANG`, `TMPDIR`, `HTTP[S]_PROXY` allow-list, `CLIBridge.swift:1316-1330`). Code-signature Team-ID verification before every spawn at every site (PR-2 + PR-6 + PR-9 closed 4 sites total). |
| TB-3 | App ↔ Jamf Pro/School/Protect servers (over network) | TLS via `jamf-cli`; `authGuard` probes `pro auth token` before live calls (`CLIBridge.swift:460-498`); School profiles skip probe (API-key auth). |
| TB-4 | App ↔ macOS Keychain | Indirect — only `jamf-cli` reads/writes; secret passed by app via stdin during onboarding (`OnboardingFlow.swift:250-264`) with `resetBytes` zeroing after dispatch. |
| TB-5 | LaunchAgent ↔ app daemon mode | `~/Library/LaunchAgents/*.plist` written atomically by `LaunchAgentWriter`; only user-agents, never LaunchDaemons. |
| TB-6 | Generated HTML report ↔ downstream readers | Centralized escaping via `HtmlSectionFormatters.escapeHTML` (Swift) and `HtmlReport._html_text` (Python `html.escape(..., quote=True)`, `jamf-reports-community.py:12916-12922`). CSS color allow-listed (`_safe_css_color`). PR-3 added landmarks + table captions; PR-3 follow-up added keyboard navigation. **Not** signed/integrity-stamped (see T-13). |
| TB-7 | Build pipeline ↔ shipped artifacts | `python-runtime.lock` SHA-256 pins; `requirements.lock.txt` + `requirements-dev.lock.txt` hash-pinned via `uv pip compile --generate-hashes` (PR-7); ad-hoc-signed dev builds; Developer-ID signing + notarization is manual (`ARCHITECTURE.md:307-309`). |
| TB-8 | Repo CI workflows ↔ release artifacts | `.github/workflows/{ci,release,report,update-jamf-cli-version}.yml`. |
| TB-9 | **(NEW)** Build host ↔ external recipient | Notarized DMG and PKG installer downloaded by other-org Mac admins via GitHub Releases or a Homebrew tap. Integrity hint via GitHub-served SHA-256 only; no signed manifest of releases. See "External Distribution Annex" §11. |
| TB-10 | **(NEW)** PKG installer pre/post-install scripts ↔ recipient root | Only relevant if the PKG runs scripts with root privileges (current default for `productbuild`-style packages). Privilege boundary; currently nothing in scope requires root install. Documented to avoid scope creep. |

---

## 3. Assets

| Asset | Why it matters |
|---|---|
| Jamf API client secret (OAuth2) | Most sensitive secret. Lives in macOS Keychain via `jamf-cli`; transits the app only over stdin during onboarding. Compromise → full Jamf Pro tenant read/write per role. |
| Jamf bearer tokens | Cached on disk by `jamf-cli`; short-lived. Compromise → tenant access until expiry. |
| Jamf School API key | Long-lived static key (no OAuth refresh). Used by `school-*` commands. Compromise → School tenant access. |
| Device inventory + compliance JSON | Whole fleet's hardware IDs, serials, users, OS state, compliance/STIG failures. Sensitive in regulated/government environments. Now **integrity-protected** by SHA-256 manifest (PR-7) — see T-11 for residual gap. |
| Generated reports (XLSX/HTML) | Inherit sensitivity of inventory data. May be shared off-host (user confirmed "unknown / varies"). **No integrity envelope** — see T-13. |
| `config.yaml` | Reveals org-specific EA names + Jamf URL; pre-onboarding bootstrap values. |
| LaunchAgent plists | If an attacker can write to `~/Library/LaunchAgents` they can persist arbitrary code — but they already have user-level execution if so. |
| Bundled Python runtime | Build-time supply-chain artifact; integrity guarded by SHA-256 pins. |
| Hash-pinned Python requirements | `requirements.lock.txt` + `requirements-dev.lock.txt` (PR-7) gate dependency tampering. |
| App binary itself | Hardened-Runtime, ad-hoc-signed for local builds; release notarization is manual. |
| **(NEW)** Developer ID signing certificate + notarization App Store Connect API key | Used during release build; compromise → ability to ship malicious updates that pass macOS Gatekeeper. Stored outside repo. |

---

## 4. Attacker Capabilities

### 4a. Current state — single-admin laptop assumption (unchanged)

**Realistic:**
- A1. Local non-privileged process running as the same user (malware, malicious npm/brew package, drive-by RCE in another app) with read/write to `$HOME`.
- A2. Person with brief unattended physical access to the unlocked Mac.
- A3. Network attacker on the same LAN, no Jamf TLS interception (`jamf-cli` validates certs).
- A4. Compromised upstream — Homebrew tap or `jamf-cli` GitHub release replaced with a malicious binary.
- A5. Recipient of a generated HTML/XLSX report (downstream — content-injection vector if a Jamf-side field was attacker-controlled).
- A6. Attacker who can submit a malicious PR or compromise a maintainer account on GitHub.

**Explicit non-capabilities:**
- Not root / not in `admin` group; the app never requests `sudo` and installs nothing system-wide.
- No remote unauthenticated network surface — the app exposes no listeners; no inbound sockets.
- Not assumed to have Keychain access (would require user auth or a prior privilege escalation).
- Not assumed to have access to a co-resident user account (single-admin model).

### 4b. Post-release / external-distribution capabilities (NEW, per 2026-05-17 scope expansion)

When the app is shipped to external organizations via notarized DMG or PKG installer, the threat model extends with:

- **A7. Recipient-side attacker (different physical host).** Same A1-style capabilities but on a Mac the maintainer doesn't control. Threat model bounds at the trust boundary — we cannot make assumptions about recipient's EDR, FileVault, or login posture.
- **A8. Distribution channel attacker.** A party who can replace a release artifact in transit (GitHub Releases CDN — low likelihood given HTTPS + GitHub's controls; Homebrew tap mirror — higher; user-side MITM with self-signed cert — relevant for under-managed Macs).
- **A9. Compromised maintainer signing key.** Attacker exfiltrates the Developer ID certificate from the build host. Can re-sign and re-notarize malicious updates. Catastrophic; mitigated only by signing-host isolation + key revocation.
- **A10. Downgrade attacker.** Recipient is tricked into installing an older signed version with known vulnerabilities (e.g., pre-PR-7 manifest, pre-PR-9 codesign coverage). All older versions remain validly signed/notarized.

---

## 5. Entry Points

| Entry point | Component | Notes |
|---|---|---|
| GUI invocation (`JamfReports.app`) | App | Trusted; same-user only |
| Daemon-mode invocation by LaunchAgent | `main.swift` | `argv[1] == "--daemon"` style; LaunchAgent plists are app-written |
| `config.yaml` parsing | `YAMLCodec` (Swift) + `yaml.safe_load` (Python, `jamf-reports-community.py:3004`) | Untrusted-ish: user-edited, but could be replaced by A1 |
| Cached JSON parsed by `ReportEngine` / `CoreDashboard` | `app/Sources/JamfReports/Engine/*`, Python classes | Source-of-truth originates from Jamf, but file is replaceable by A1; **integrity-checked against manifest** (PR-7) for files under `jamf-cli-data/` |
| `summary.json` parsed by `RunHistoryService.isPartialRun` + `LaunchAgentService.checkSummaryFileForPartialStatus` | partial-status authoritative source | **Not manifest-covered** (T-12) |
| CSV imports (Jamf Pro export, Jamf School export) | `CSVDashboard`, `_school_csv_load` | Auto-detects delimiter; passed cell-by-cell to `_safe_write` |
| jamf-cli stdout (JSON) | `CLIBridge.runJSON` | Parsed; effectively trusted because the binary is codesign-verified at every spawn |
| Onboarding stdin (client ID + secret) | `OnboardingFlow.runPTY` | Untrusted user input, passed straight to `jamf-cli` |
| LaunchAgent plist on disk (read-back) | `LaunchAgentService` | Could be attacker-modified by A1 |
| GitHub Actions triggers | `.github/workflows/` | PRs from outside collaborators |
| **(NEW)** DMG mount + drag-install | macOS Finder + Gatekeeper | Recipient-side; Gatekeeper enforces notarization |
| **(NEW)** PKG installer execution | `/usr/sbin/installer` | Recipient-side; runs pre/post-install scripts; can request admin auth (we should NOT) |
| **(NEW)** Homebrew tap install (if used) | `brew install --cask jamf-reports-community` | Recipient-side; tap repo integrity is GitHub-level |

---

## 6. Threats (abuse paths)

For each: **goal → path → assets → likelihood × impact → priority**, with file evidence where applicable. Mitigations split into **existing** vs **recommended**. T-1..T-10 updated to reflect PR-1..PR-9 work; T-11..T-15 added from post-PR review batch; T-16..T-20 are post-release (see §11); T-21 added 2026-05-20 for the PR-22 tiered-collection surface.

### T-1. Malicious shim at `/opt/homebrew/bin/jamf-cli` exfiltrates onboarding secret or command-time data
- **Goal:** Steal the Jamf API client secret during onboarding, or hijack a later routine command to receive credentials / corrupt collected data.
- **Path:** A1 (local same-user malware) drops a `jamf-cli` binary earlier on `PATH` than the real one, or backdoors the Homebrew tap (A4).
- **Assets:** API client secret → full Jamf tenant compromise. Also: live inventory data → ability to fabricate compliance posture.
- **Existing mitigations:**
  - **Onboarding gate:** `CodeSignVerifier.verify(...)` runs *before* the secret is written to stdin (`OnboardingFlow.swift:418`).
  - **Install gate:** `JamfCLIInstaller.swift:543` re-verifies after auto-update.
  - **Routine-command gate (PR-2 M-01 + PR-6 + PR-9):** All 7 jamf-cli spawn sites now codesign-gated: `CLIBridge.run`, `CLIBridge.runAndCapture`, `runDeviceDetailProcess` (PR-2), `Provenance.captureJamfCLIVersion`, `JamfCLIInstaller.installedVersion`, `ProfileService.discoverJamfCLIProfiles` (PR-6), and `LaunchAgentWriter.isTrustedJamfCLIExecutable` (PR-9). The gate checks a per-process cache keyed on `(path, size, mtime)`. A failed verify returns exit `-1` with a `[fatal] jamf-cli signature verification failed` user-facing diagnostic; no `Process` is spawned.
  - **Stdin scrubbing:** Stdin buffer zeroed via `resetBytes(in:)` after dispatch (`OnboardingFlow.swift:250-252`).
  - **Pinned env:** `environmentForJamfCLI` is the default for all `CLIBridge.run` / `runAndCapture` (S-02, PR-2). Whitelisted: `PATH/HOME/LANG/TMPDIR` + proxy vars.
- **Likelihood:** Low (4 stacked defenses; M-01 fully closed).
- **Impact:** Critical (full tenant secret + data integrity).
- **Priority: LOW.** M-01 closure removed the routine-command exposure window across all 7 sites. Residual = T-14 (TOCTOU) and upstream tap compromise (A4) producing a Team-ID-valid malicious binary.
- **Residual risk — stat/exec TOCTOU (T-14):** The fingerprint check (`stat`) and the subsequent `process.run()` are not atomic on POSIX. Mitigated in practice by (a) the gate firing immediately before exec, narrowing the window to microseconds; (b) install-time codesign gate raising the cost of the initial swap. Accepted per existing policy (no `fexecve` available in Foundation).
- **Recommended mitigations:**
  - Document and review `JamfCLIIdentity.expectedTeamID` (`"483DWKW443"`) for changes in PRs (CODEOWNERS rule).
  - When `jamf-cli` is auto-updated via `JamfCLIInstaller`, log the post-update signing certificate fingerprint to `automation/logs/` so a silent identity flip is auditable.

### T-2. Tampered cached JSON leads to misleading reports / charts shared with management
- **Goal:** Cause incorrect compliance/inventory data to be reported.
- **Path:** A1 modifies `~/Jamf-Reports/<profile>/jamf-cli-data/*.json` between collect and generate.
- **Assets:** Integrity of generated reports → operational/compliance decisions.
- **Existing mitigations:**
  - **SHA-256 manifest (PR-7):** Every snapshot file under `jamf-cli-data/<report_type>/` is hashed at collect time; collect writes `manifest.json` per directory using in-memory bytes (no read-write race). Verify-side (`_load_cached_json`, `_load_json_snapshots`, Swift `SnapshotManifest.verify`) reads each cached file once via `read_bytes()` → verifies hash → `json.loads(raw)` from same buffer. Single-read pattern structurally closes the verify-then-parse TOCTOU race (PR-7 M-3 fix). `--strict-manifest` flag (Python) promotes warn-only mismatches to hard errors for generate + html commands.
  - `WorkspacePermissionHardener.tighten()` sets snapshot files to 0600 and directories to 0700.
  - Generation is idempotent and re-runs against fresh API data via `collect`.
- **Likelihood:** Low (with manifest); Medium (when manifest absent — see T-11).
- **Impact:** Medium (no credential loss; downstream decisions distorted).
- **Priority: LOW–MEDIUM** (was MEDIUM; downgraded for manifest-covered files; T-11 / T-12 / T-13 cover residual integrity gaps).
- **Recommended mitigations:**
  - Close T-11 (manifest absence silent pass) — surface unverified-snapshot warning in AuditView.
  - Close T-12 (summary.json outside manifest coverage).
  - Add a UI banner in the Sources screen showing the last-verified-manifest timestamp.

### T-3. HTML report content-injection via attacker-controlled Jamf fields
- **Goal:** Pop XSS / launch URL handlers when a sysadmin opens a shared HTML report in a browser.
- **Path:** A6 (or a malicious user controlling a device record) injects HTML/JS into a device name, EA value, or policy name.
- **Existing mitigations:**
  - Swift `HtmlSectionFormatters.escapeHTML` wraps every dynamic insertion in `HtmlReport.swift`.
  - Python `HtmlReport._html_text` uses `html.escape(..., quote=True)`; CSS colors via `_safe_css_color`.
  - HTML output is self-contained — no remote `<script src>`.
  - **PR-3 added landmarks + table captions** for a11y, no XSS regression.
  - **Sanitization tests (PR-5):** 29 malicious-payload tests in `tests/test_sanitization.py` exercise the Python path with `<script>`, `"><img onerror>`, `=SUM`, `+1+1`, etc. across every CSV-sourced sink.
- **Likelihood:** Low — escaping is centralized and tested.
- **Impact:** Medium.
- **Priority: LOW–MEDIUM** (sanitization tests close most of the regression risk).
- **Recommended mitigations:**
  - Add a meta CSP (`default-src 'self' 'unsafe-inline'`; `script-src 'none'`) to the HTML head.
  - Mirror Python sanitization tests to the Swift `OOXMLWriter` equivalent (currently Python-only).
  - Lint/regex check that any new `HtmlReport` interpolation site routes through `escapeHTML`.

### T-4. CSV/spreadsheet formula injection in generated XLSX or CSV exports
- **Goal:** When a recipient opens a generated XLSX or CSV in Excel/Numbers, a leading `=`, `+`, `-`, `@`, or `\t` triggers `WEBSERVICE` / `HYPERLINK` / DDE.
- **Path:** A6 / a device record or patch title with attacker-controlled metadata.
- **Existing mitigations:**
  - Python `_safe_write` is the documented invariant (CLAUDE.md "Invariants") sanitizing formula injection; PR-5 added 29 malicious-payload tests including formula-injection payloads.
  - Swift `OOXMLWriter.sanitizeString` prepends a tab to any cell beginning with `=+-@` — parity with `_safe_write`, verified clean in the PR-26 security review (`app/SECURITY_AUDIT.md`).
  - **PR-25 Patch Compliance CSV export:** `PatchStatusService.csvField` neutralizes the same formula-injection prefixes before RFC 4180 quoting; covered by `testComplianceCSVNeutralizesFormulaInjection`. This was a MUST-FIX caught in the PR-26 security review and folded into PR-25 before merge.
- **Likelihood:** Low.
- **Impact:** Medium.
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - Per-run counter + end-of-run summary of how many cells `_safe_write` truncated / sanitized (BACKLOG N-13 — formula-injection silent truncation).
  - Treat any new structured-data export (CSV/XLSX/clipboard sink) as required to route through a neutralizing escaper; add a lint or test that fails a new export path lacking one.

### T-5. Symlink/traversal escape in `SystemActions` open/reveal
- **Goal:** Trick the app into opening or revealing an attacker-chosen path outside the workspace.
- **Path:** A1 plants a symlink inside `~/Jamf-Reports/<profile>/Generated Reports/` pointing to e.g. `~/Library/Keychains/login.keychain-db`.
- **Existing mitigations:**
  - `SystemActions.canonicalize` resolves symlinks then `resolvedPath == root || resolvedPath.hasPrefix(root + "/")`.
  - `/tmp` removed from allow-list to avoid macOS shared-tmp TOCTOU.
  - **PR-8 MigrationBanner path-traversal verified clean** (security-reviewer audit): `SystemActions.reveal` is called only with workspace root + `~/Library/LaunchAgents`, not interpolated dotted-folder names.
- **Likelihood:** Low.
- **Impact:** Low–Medium.
- **Priority: LOW.**
- **Recommended mitigations:**
  - Regression test for prefix-without-slash case (`~/Jamf-ReportsX/`).
  - Reject paths where any intermediate component is a symlink (currently only the final resolve is checked).

### T-6. LaunchAgent plist takeover or label-parsing confusion persists attacker code as the user
- **Goal:** Persist code that runs at every interval boundary.
- **Path:** Two variants:
  - **T-6a (plist overwrite):** A1 overwrites a `~/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.*.plist` job.
  - **T-6b (label-parsing confusion, closed):** Previously the validator allowed `.` in profile slugs; the label parser then split ambiguously.
- **Existing mitigations:**
  - App writes plists atomically with `replaceItem(at:withItemAt:)`.
  - Only user-agents, never LaunchDaemons.
  - **S-03 fix (PR-3):** `ProfileService.isValid` rejects any `.` in profile slugs at every label-construction and parse site. Cross-profile operation confusion structurally impossible.
  - **PR-8 MigrationBanner:** Surfaces dotted legacy workspaces + schedules via `dottedLegacyWorkspaces()` + `dottedLegacyAgents()` with first-launch acknowledgment and "Show in Finder" affordances for manual cleanup. Closes the silent-data-loss UX gap from S-03.
- **Likelihood:** Medium for T-6a (assumes A1); Negligible for T-6b.
- **Impact:** Medium for T-6a; Low for T-6b.
- **Priority: LOW.**
- **Recommended mitigations:**
  - On app start, warn if a `com.jamfreports.*` plist points to a `ProgramArguments[0]` that is not the app's own bundle executable URL.

### T-7. Onboarding secret leakage via process arguments / logs
- **Goal:** Read the client secret from a debug log, crash dump, or process-listing.
- **Path:** A1 or a debugging mistake.
- **Existing mitigations:**
  - Secret passed via **stdin only**, not argv.
  - Stdin buffer zeroed after dispatch.
  - **PR-A / PR-7 / PR-9 LogRedactor:** 10 patterns enforced in both Python (`_SECRET_PATTERNS`) and Swift (`LogRedactor.patterns`) with parity audited: `client_secret`, `client_id`, `Bearer <token>`, JWT, `access_token`, `refresh_token`, `password`, `api_key`/`apikey` (PR-9), HTTP Basic, `webhook_url`. Applied at `RunHistoryService.loadLog` (UI render) AND `RunsView.exportLogFile` (file export — CR-1 fix in PR-7). Raw log on disk untouched per design.
  - Diagnostic-bundle (`cmd_diagnostic_bundle`) redacts both free-text via `_SECRET_PATTERNS` AND JSON keys via `_SENSITIVE_JSON_KEYS`. Default-on; opt-out via `--keep-*` flags for local-only use.
- **Likelihood:** Very Low.
- **Impact:** Critical (if leaked).
- **Priority: LOW.**
- **Recommended mitigations:**
  - Canary-in-logs regression test (insert known fixture secret value, assert it appears nowhere in `automation/logs/` / clipboard / file export / diagnostic bundle).
  - Audit any NEW credential pattern that may flow through logs (e.g., Jamf School API key new shapes) and add matching pattern to both LogRedactors.

### T-8. `jamf-cli` exit-code mishandling causes silent data corruption
- **Goal:** Get the app to silently fall back to stale cached data after an auth or permission change.
- **Path:** Auth expires (exit 3) or role privilege revoked (exit 5). Only exit 3 hard-aborts; 4/5/6 warn-and-fall-back-to-cached.
- **Existing mitigations:**
  - `authGuard` probes the token before each live call.
  - Run logs in `automation/logs/` record warnings.
  - **PR-7 stale banner** on `DeviceLookupView` surfaces last-fetched-X-ago via `RelativeDateTimeFormatter` when live calls fall back to cache.
  - **PR-8 partial-status pill:** `Schedule.LastStatus.partial` case rendered with distinct icon (`exclamationmark.triangle.fill`) in `RunsView` + `SchedulesView`. Operators see PARTIAL pills instead of green OK on partial runs. Authoritative source = sibling `summary.json` `{"status":"partial"}` with `[partial]` log marker as fallback. **Caveat:** per-run summary writer for the summary.json path is not yet implemented (BACKLOG MEDIUM-3); today only the log-marker fallback fires.
  - **PR-9 patchPct null-omission:** Bridge-path `_build_summary_from_bridge` no longer writes `patchPct: 0.0` on failure (closes N-20 bridge path).
- **Likelihood:** Medium (auth/privilege drift is common).
- **Impact:** Low–Medium.
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - Extend stale-data banner pattern to TrendsView / DevicesView / Posture dashboards (BACKLOG: T-15 broader application, deferred per anti-churn rule).
  - Close BACKLOG SHOULD-FIX "Summary builders zero-fill on decode failure (Python side only)" — `_build_summary_from_csv` CSV path still zero-fills.
  - Close BACKLOG N-09 — `cmd_launchagent_run:17386` unconditional `success=true` ignores per-command collect failures.

### T-9. Supply-chain: malicious dependency in Python runtime or PR
- **Goal:** Bundle backdoored code into a release.
- **Path:** A6 introduces a malicious commit to `requirements*.txt` or `python-runtime.lock`.
- **Existing mitigations:**
  - **PR-7 hash-pinned deps:** `requirements.lock.txt` + `requirements-dev.lock.txt` generated via `uv pip compile --generate-hashes --universal --python-version 3.9`. SHA-256 per package across all platforms.
  - `app/python-runtime.lock` pins SHA-256 of the downloaded runtime archive.
  - CODEOWNERS file present.
- **Likelihood:** Low.
- **Impact:** High (signed/notarized release would ship the payload).
- **Priority: LOW–MEDIUM** (was MEDIUM; downgraded by hash-pinned requirements).
- **Recommended mitigations:**
  - Branch protection on `main` + required CODEOWNERS reviews for any change to `python-runtime.lock`, `requirements*.lock.txt`, `requirements*.txt`, `build-python-runtime.sh`, `JamfCLITeamID`.
  - CI job running `pip-audit` (or equivalent) on `requirements*.lock.txt` per PR.
  - Mirror the hash-pinning discipline to `requirements-runtime.txt` (currently unpinned).

### T-10. `YAMLCodec` / `yaml.safe_load` parsing of a hostile `config.yaml`
- **Goal:** Code execution or path escape via crafted YAML.
- **Path:** A1 swaps `config.yaml` for a malicious file.
- **Existing mitigations:**
  - Python uses `yaml.safe_load` exclusively (`jamf-reports-community.py:3004`).
  - Swift `YAMLCodec` is a minimal hand-rolled reader/writer.
- **Likelihood:** Low.
- **Impact:** Low–Medium.
- **Priority: LOW.**
- **Recommended mitigations:**
  - Property-based / fuzz tests against `YAMLCodec` for malformed input.

### T-11. Snapshot manifest absence treated as silent pass (NEW, defense evasion)
- **Goal:** Bypass PR-7's SHA-256 integrity control by deleting the manifest itself.
- **Path:** A1 modifies a snapshot AND deletes the matching `manifest.json` entry (or the whole file). Swift `SnapshotManifest.verify` returns silently when manifest is absent/unparseable; Python `_verify_snapshot_against_manifest` warns to stderr only. The comment at `SnapshotManifest.swift:11-16` documents this as intentional ("partial-collect crashes look the same as tampering") — but the resolution should be a UI warning, not silence.
- **Existing mitigations:** None UI-surfaced; warning only in logs.
- **Likelihood:** Medium (assumes A1 plus 2 file operations vs 1).
- **Impact:** Defeats T-2 control. Medium.
- **Priority: HIGH** (largest residual security gap; direct evasion of a control just shipped).
- **Recommended mitigations:**
  - Surface "Unverified snapshot" pill on affected dashboards' data-source line.
  - Add `jamf_cli.require_manifest: true` config gate that forces `--strict-manifest` by default for new workspaces.
  - Cost: ~30 lines + 1 view change.

### T-12. `summary.json` outside manifest coverage; authoritative for PR-8 PARTIAL pill (NEW)
- **Goal:** Flip a `.partial` run status to `.ok` in the UI by editing one untrusted file.
- **Path:** PR-8's `RunHistoryService.isPartialRun` reads `<workspace>/snapshots/computers/summaries/summary_<ts>.json` and trusts `status` field verbatim. The summaries directory is structurally outside `_rewrite_snapshot_manifest`'s scope (manifest writer is only ever called inside `JamfCLIBridge._save_snapshot` against `jamf-cli-data/`). A1 edits `"status": "partial"` → `"status": "ok"`; UI silently downgrades from yellow pill to green checkmark.
- **Existing mitigations:** None.
- **Likelihood:** Medium (one-file edit).
- **Impact:** Undermines a UI control PR-8 just added. Low–Medium.
- **Priority: MEDIUM.**
- **Recommended mitigations:**
  - Extend `_rewrite_snapshot_manifest` to cover `snapshots/computers/summaries/`.
  - Add Swift `SnapshotManifest.verify(...)` call inside `isPartialRun` + `checkSummaryFileForPartialStatus` before trusting `status`.
  - Cost: ~40 lines + 1 test. Also closes BACKLOG MEDIUM-3 dead-code documentation by giving the dormant branch a real producer.

### T-13. Generated Reports (XLSX/HTML) have no integrity envelope (NEW)
- **Goal:** Tamper with a leadership-bound report between generation and recipient open.
- **Path:** No code execution required — `open -e report.html`, change "FileVault: 100%" to "FileVault: 60%", save, send. Or modify a row in the XLSX. The generation pipeline produces no signature, no embedded hash, no sidecar.
- **Existing mitigations:** Filesystem permissions only (0600 on writer mtime).
- **Likelihood:** Medium (low skill required; insider attacker plausible).
- **Impact:** Medium (cross-trust-boundary: recipient acts on tampered data).
- **Priority: MEDIUM.**
- **Recommended mitigations:**
  - Embed `<meta name="report-sha256" content="...">` in HTML head plus a visible "Verify: shasum -a 256 <file>" footer line. Recipient who cares can compare; raises tamper cost.
  - Write a side-car `.sha256` file alongside each XLSX; surface the hash in the UI "Report ready" toast.
  - Cost: ~25 lines.

### T-14. Codesign-gate stat/exec TOCTOU (NEW, accepted)
- **Goal:** Swap a verified binary between codesign check and exec.
- **Path:** Race window between `JamfCLIIdentity.ensureVerifiedJamfCLI` (calls `stat` + `codesign --verify`) and `process.run()`.
- **Existing mitigations:** Window narrowed to microseconds by inlining the gate immediately before exec. Install-time gate at `JamfCLIInstaller.swift:543` raises the cost of the initial path swap.
- **Likelihood:** Very Low (requires precise timing + same-user write to the binary path).
- **Impact:** Critical (same as T-1).
- **Priority: LOW (ACCEPTED).** No fix proposed without an `fexecve`-style API.
- **Documented:** if Apple ever exposes a verify-then-exec-from-handle API, revisit.

### T-15. Run-log mtime attacker-controllable; PR-7 stale-data banner suppressible (NEW)
- **Goal:** Hide a stale-cache condition from the user by forging the snapshot file's mtime.
- **Path:** A1 runs `touch -t` on the cached snapshot; `RelativeDateTimeFormatter` then reads the forged mtime; stale banner reports "fresh".
- **Existing mitigations:** Codex 2026-05-13 review noted this; in BACKLOG (line 403) as CONSIDER.
- **Likelihood:** Low (specific tool needed; assumes A1).
- **Impact:** Low (decision quality only).
- **Priority: LOW.**
- **Recommended mitigations:** Extend `SnapshotManifest` schema with `generated_at`; surface that to the stale banner instead of mtime. Tracked in BACKLOG.

### T-21. Tiered-collection state file forged to suppress a scheduled fetch (NEW)
- **Goal:** Freeze the fleet data the app shows by making the PR-22 tiered-collection engine believe a report is fresh when it is not.
- **Path:** A1 writes a recent (or future) timestamp into `jamf-cli-data/state/<report>.last`. `ReportEngine.collect`'s `is_due()` check then skips that report's fetch indefinitely; dashboards keep rendering the last-collected JSON while the schedule appears to run normally.
- **Assets:** Freshness/integrity of inventory + compliance data → operational decisions made on stale data.
- **Existing mitigations:** The PR-22 manifest schema bump (v2) extends SHA-256 coverage to `state/*.last`, so a forged `.last` fails manifest verification on the next verified read. Run logs record `[skip] <report> not due` lines, making an unexpectedly-never-fetched report visible to an operator who reads them.
- **Likelihood:** Low (assumes A1; single-file edit, but the v2 manifest catches it).
- **Impact:** Low–Medium (no credential loss; decision quality degraded).
- **Priority: LOW.** The residual is identical to T-11 — if the manifest itself is absent or deleted, the forged `.last` passes silently. Closing T-11 closes this too.
- **Recommended mitigations:** Fold into the T-11 fix — the "Unverified snapshot" surface should also flag a `state/` directory whose manifest is missing.

---

## 7. Priority Summary (current state)

| Threat | Priority | Notes |
|---|---|---|
| **T-11** Manifest absence silent pass | **HIGH** | Largest residual gap; defeats PR-7's headline control with one extra file op |
| **T-12** summary.json outside manifest | **MEDIUM** | Undermines PR-8 PARTIAL pill; ~40 line fix |
| **T-13** Generated Reports no integrity envelope | **MEDIUM** | Recipient-side tamper vector; ~25 line fix |
| T-9 Supply-chain (Python runtime / deps) | LOW–MEDIUM | Hash-pinned in PR-7; CODEOWNERS + pip-audit gap |
| T-2 Tampered cached JSON | LOW–MEDIUM | Manifest-covered post PR-7; T-11 is the residual |
| T-3 HTML XSS in shared report | LOW–MEDIUM | Sanitization tests in PR-5; CSP still recommended |
| T-4 XLSX formula injection | LOW–MEDIUM | Tested on Python side (PR-5); Swift side untested |
| T-8 Exit-code silent fallback | LOW–MEDIUM | Stale banner + PARTIAL pill close UI surface; PR-9 closed bridge-path N-20 |
| T-1 Secret exfil via shim/upstream | LOW | All 7 spawn sites codesign-gated (PR-2 + PR-6 + PR-9) |
| T-5 Symlink/traversal | LOW | Trailing-`/` enforced; PR-8 MigrationBanner verified clean |
| T-6 LaunchAgent takeover | LOW | T-6a still residual; T-6b structurally closed |
| T-7 Secret leakage via logs | LOW | 10-pattern LogRedactor Python ↔ Swift parity (PR-A + PR-7 + PR-9) |
| T-10 YAML parser abuse | LOW | `safe_load` only |
| T-14 Codesign TOCTOU | LOW (ACCEPTED) | Foundation-API limited |
| T-15 mtime-forged stale banner | LOW | BACKLOG |
| T-21 Tiered-collection state-file skip | LOW | Manifest v2 covers `state/*.last`; residual = T-11 |

---

## 8. Assumptions and Open Questions

Confirmed with user (2026-05-12, refreshed 2026-05-17, re-confirmed 2026-05-20):
- **Single-admin laptop** deployment for current state — re-confirmed 2026-05-20. One trusted user per Mac, no co-resident accounts. Cross-user threats deprioritized.
- Generated report distribution is **unknown / varies** — output-side injection threats (T-3, T-4) kept at LOW–MEDIUM.
- **Public release in preparation** (confirmed 2026-05-20), not yet shipped. Distribution will be a notarized DMG **and** a PKG installer (PKG confirmed in scope — see T-17). The §11 annex stays forward-looking but is now near-term; T-16 / T-17 should be treated as imminent rather than hypothetical.
- The Developer ID signing certificate is an **individual** Apple Developer enrollment, not an organization. Recipient-Mac background-activity / Login Items prompts therefore show the individual developer's name. T-16 blast radius is one individual certificate on a single signing host.

Material assumptions still in effect:
- `JamfCLIIdentity.expectedTeamID` (`"483DWKW443"`) is the legitimate jamf-cli publisher. If false, T-1 jumps to HIGH.
- `python-runtime.lock` + `requirements.lock.txt` SHA-256 values are reviewed in PR and not auto-bumped by a bot. If false, T-9 jumps to HIGH.
- `automation/logs/` is treated as same-trust as the workspace. Verified by `WorkspacePermissionHardener` sweep; not by a permission-regression test.
- The app never auto-updates its own binary (only `jamf-cli`). If a future auto-update path is added, re-rank T-9 / T-16.
- Reports may be opened by recipients on Windows / non-macOS — relevant for T-4 (Excel-only formula evaluation).
- **(NEW)** PKG installer will NOT request admin authorization (no root scripts). If that changes, model TB-10 explicitly and add T-21 (script-as-root abuse).

---

## 9. Highest-Value Next Actions (current state)

If only three things are done from this report, do these:

1. **Close T-11 (manifest absence silent pass).** Surface "Unverified snapshot" warning in the Sources / AuditView; add `jamf_cli.require_manifest: true` config gate feeding `--strict-manifest` by default. ~30 lines + 1 view change. The single highest-leverage gap remaining.
2. **Close T-12 (summary.json under manifest coverage).** Extend `_rewrite_snapshot_manifest` to cover `snapshots/computers/summaries/`; verify in `isPartialRun` + `checkSummaryFileForPartialStatus`. ~40 lines + 1 test. Also resolves BACKLOG MEDIUM-3 dead-code by giving the dormant Swift branch a real producer.
3. **Ship T-13 integrity hints for Generated Reports** (HTML `<meta name="report-sha256">` + XLSX sidecar `.sha256`). ~25 lines. The single highest-impact change for the cross-trust-boundary recipient surface.

Items 1 + 2 are pure follow-ups to PR-7 / PR-8 — close gaps in controls just shipped. Item 3 addresses the only cross-trust-boundary surface the manifest discipline explicitly skipped.

---

## 10. Quality Check

- [x] All discovered entry points covered (§5 maps each to ≥1 threat).
- [x] Each trust boundary appears in at least one threat.
- [x] Runtime vs build/CI separated (T-9 is the build-time threat; T-16..T-19 are release-pipeline threats).
- [x] User clarifications recorded (§8).
- [x] Assumptions explicit (§8).
- [x] Current-state vs post-release annex separated (§6 vs §11 per user request).
- [x] Both DMG and PKG installer scenarios covered in §11 per user request.
- [x] PR-1..PR-9 mitigations reflected in T-1..T-10 existing mitigations.
- [x] PR-16..PR-26 reflected: tiered-collection surface (T-21, `state/` + `collect_cadence` stores), xlsx-corruption fix + Patch CSV export (T-4), Python script role corrected (§1), single-admin + public-release prep re-confirmed with user 2026-05-20 (§8).

---

## 11. External Distribution Annex (post-release, next 6 months)

This annex models threats that arise only when the app is shipped externally to other organizations. The current-state model (§§ 1–10) remains primary; this annex is forward-looking. Threats T-16..T-20 are scoped to the additional capabilities A7..A10 and the additional trust boundaries TB-9..TB-10.

### Distribution channels in scope

Per user confirmation (2026-05-17), planned external distribution includes:
- **Notarized DMG** delivered via GitHub Releases. Recipient drags `.app` to `/Applications` (no install scripts). Gatekeeper enforces notarization.
- **PKG installer** delivered via GitHub Releases (and potentially a Homebrew cask). Recipient runs `installer -pkg ... -target /` or double-clicks. Pre/post-install scripts MAY run as root depending on `productbuild` flags.

### T-16. Notarization key / Developer ID certificate compromise
- **Goal:** Ship malicious updates that pass macOS Gatekeeper on every recipient Mac.
- **Path:** A9 exfiltrates the Developer ID certificate (and/or notarization API key) from the build host. Re-signs and re-notarizes a backdoored build. Recipients update via Homebrew or manual download and Gatekeeper raises no warning.
- **Existing mitigations:** Manual notarization (per `ARCHITECTURE.md:307-309`) — no CI automation that could be compromised. Single-developer signing host.
- **Likelihood:** Low (key kept off CI; manual signing flow).
- **Impact:** Catastrophic (every recipient).
- **Priority: HIGH** for the post-release horizon. **N/A** pre-release.
- **Recommended mitigations:**
  - Store Developer ID certificate in a hardware token (YubiKey / Secure Enclave) requiring touch-to-sign.
  - Notarization API key in a separate password manager entry not on the build host; copy-paste at sign time.
  - Document key-revocation procedure: `xcrun stapler` cannot revoke; the path is Apple Developer portal certificate revocation + re-sign of every supported version.
  - Publish a "verify build" doc with the SHA-256 of each release artifact and the signing certificate's SHA-1 fingerprint so recipients can attest.

### T-17. PKG installer root-script abuse
- **Goal:** Run attacker code as root on the recipient's Mac via a tampered PKG.
- **Path:** A8 swaps the PKG in transit or A9 ships a malicious one. If the PKG runs pre/post-install scripts as root (default for `productbuild` when scripts directory is provided), those scripts execute with root privileges. The current build does not yet ship a PKG, but the user has stated PKG will be one of the distribution formats.
- **Existing mitigations:** None — PKG not yet built.
- **Likelihood:** Depends entirely on PKG design at build time.
- **Impact:** Critical (root code execution on recipient host).
- **Priority: HIGH if the PKG runs scripts as root.** **LOW otherwise.**
- **Recommended mitigations (design-time):**
  - **Strongly prefer a drag-install DMG.** If a PKG is required, design it to install to `/Applications/JamfReports.app` with no pre/post-install scripts (component-only `pkgbuild` + `productbuild` with no `--scripts` arg).
  - If scripts are unavoidable: keep them to filesystem-only operations; never `curl | bash`, never write to `/Library/LaunchDaemons`, never request `setuid` binaries. Audit every line.
  - Sign the PKG with the same Developer ID Installer certificate; notarize the PKG; document the SHA-256 in release notes.
  - In CI / release docs, explicitly forbid `--component-plist` or `--scripts` flags unless a security review approves the script contents.

### T-18. Downgrade attack against signed older versions
- **Goal:** Trick a recipient into installing an older signed-and-notarized version with known vulnerabilities (e.g., a build pre-PR-7 has no manifest verification; pre-PR-6 has 3 ungated jamf-cli spawn sites).
- **Path:** A8 serves an older `.dmg` / `.pkg` from a typosquat repo, phishing email, or in-the-middle a slow CDN. Older versions remain validly signed and notarized indefinitely — Gatekeeper does not check version.
- **Existing mitigations:** None at the app layer.
- **Likelihood:** Medium (low skill required for the social-engineering side).
- **Impact:** Medium (re-introduces vulnerabilities already fixed).
- **Priority: MEDIUM** for post-release horizon.
- **Recommended mitigations:**
  - In-app version check on launch against a signed `latest-version.json` served from a GitHub Pages site. If running version < latest minor, show "Update recommended" banner. Cheap and high-leverage.
  - Document version-specific security notes in `CHANGELOG.md` so a recipient can self-assess whether to upgrade urgently.
  - At a minimum, do NOT delete old releases from GitHub — auditability requires the historical record stay accessible, but recipients should be steered to the latest.

### T-19. Homebrew tap / cask integrity
- **Goal:** Compromise the Homebrew installation path (if a tap or cask is published).
- **Path:** A6 (or A8) modifies the cask formula to point to a different `url` and `sha256`. Recipient running `brew upgrade` pulls and installs the malicious build. The Gatekeeper check still passes if the binary is correctly signed by A9; if not, Gatekeeper warns the user but many recipients click through.
- **Existing mitigations:** None (tap not yet established).
- **Likelihood:** Medium when established (low when not).
- **Impact:** High.
- **Priority: MEDIUM** (conditional on publishing a tap).
- **Recommended mitigations:**
  - Use the official `homebrew/cask` repo rather than a personal tap if possible — recipients benefit from the wider security review.
  - If a personal tap is required, enable GitHub branch protection on the tap repo's `main` (signed commits + CODEOWNERS).
  - Document the canonical install command in `README.md` so recipients aren't relying on typo-squat taps.

### T-20. Recipient's `~/Jamf-Reports/` adoption — multi-org config exposure
- **Goal:** Cross-recipient data leakage via shared workspace conventions.
- **Path:** Two recipients in the same org accidentally share a workspace via networked home directories (rare on Mac, but possible in some education / federal contexts). One recipient's onboarding writes `config.yaml` with Jamf URL + EA names of org A; the other recipient's run sees those values.
- **Existing mitigations:** Per-user workspace under `$HOME`; no shared-disk path baked in.
- **Likelihood:** Low (requires shared home dir).
- **Impact:** Low–Medium (no credentials cross over — those are in `jamf-cli` keychain — but org-internal naming leaks).
- **Priority: LOW.**
- **Recommended mitigations:**
  - On first launch in a workspace that already has a `config.yaml` written by a different macOS user account, show a warning banner asking the user to confirm intent.
  - Document in `README.md` that workspaces are per-user and should not be placed on networked home directories.

---

## 12. Annex Quality Check

- [x] §11 covers DMG and PKG paths per user request.
- [x] §11 covers post-release supply-chain (notarization key, downgrade, Homebrew tap).
- [x] §11 explicitly notes T-17 is HIGH **conditional** on PKG design — design-time guidance provided to keep it LOW.
- [x] §11 explicitly distinguishes recipient-side capabilities (A7) from build-host capabilities (A9) so mitigations land on the right actor.
- [x] All §11 threats reference the new trust boundaries (TB-9, TB-10) and new attacker capabilities (A7..A10).
