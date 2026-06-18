# Threat Model — jamf-reports-community

Repository: `jamf-reports-community` (native macOS Swift app)
Original model: 2026-05-12
Refreshed: 2026-05-17 (post PR-1..PR-9 backlog-burndown sequence)
Refreshed: 2026-05-20 (post PR-16..PR-26 — tiered collection, xlsx-corruption fix, Patch CSV export)
Refreshed: 2026-05-20 (v2.0.0 release prep — §7/§9 reconciled: T-11/T-12/T-13 confirmed closed by PR-10/11/12; diagnostic-bundle PII redaction hardened)
Refreshed: 2026-06-18 (single-engine — standalone Python CLI removed; native Swift `ReportEngine` is the sole engine; Python-specific threat surface dropped)
Scope basis: full repo (`app/`, CI workflows, scripts)

---

## 1. Scope and System Model

### In scope
- Native macOS app under `app/` (Swift 6, SwiftPM, macOS 14+).
- Build/release tooling: `app/build-app.sh`, `app/build-pkg.sh`, `app/scripts/` (sign/notarize/package).
- GitHub Actions workflows in `.github/workflows/`.
- Per-profile workspaces at `~/Jamf-Reports/<profile>/`.
- User-space LaunchAgents written to `~/Library/LaunchAgents/com.jamfreports.*.plist`.
- **(2026-05-17 addition)** Planned external distribution: notarized DMG **and** PKG installer for delivery to other organizations running their own Jamf Pro / Jamf School deployments.

### Out of scope (referenced, not modeled here)
- The external `jamf-cli` binary (Go, separate repo) — treated as a trusted external dependency once Team-ID code-signature verification passes (`CodeSignVerifier.verify`, `app/Sources/JamfReports/Services/CodeSignVerifier.swift:13`, callers at `OnboardingFlow.swift:234`, `JamfCLIInstaller.swift:541`, and — as of PR-6/PR-9 — at every `Process()` spawn site that targets `jamf-cli`).
- Jamf Pro / School / Protect servers themselves.
- Recipient-org Jamf tenant compromise that is not initiated through this app — covered only at the trust boundary.

### Components and runtime
| Component | Where | Runtime role |
|---|---|---|
| `JamfReports` (GUI) | `app/Sources/JamfReports/App` | User-facing SwiftUI app; spawns `jamf-cli` |
| `main.swift` (daemon mode) | `app/Sources/JamfReports/App/main.swift` | Triggered by LaunchAgent timers; collects + generates |
| `ReportEngine` (native engine) | `app/Sources/JamfReports/Engine/*` | Reads cached JSON, writes XLSX/HTML/CSV |
| `CLIBridge` | `app/Sources/JamfReports/Services/CLIBridge*.swift` | `Process`-based async wrapper for `jamf-cli`; environment hardening; codesign gate (PR-6) |
| `LogRedactor` | `app/Sources/JamfReports/Services/LogRedactor.swift` | Free-text + JSON credential redaction; 10 patterns (PR-A baseline, PR-7 reuse, PR-9 api_key addition) |
| `SnapshotManifest` | `app/Sources/JamfReports/Engine/SnapshotManifest.swift` | SHA-256 manifest covering `jamf-cli-data/*.json` (PR-7) |
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
| TB-6 | Generated HTML report ↔ downstream readers | Centralized escaping via `HtmlSectionFormatters.escapeHTML` — every dynamic insertion in `HtmlReport` routes through it. HTML output is self-contained (no remote `<script src>`). PR-3 added landmarks + table captions; PR-3 follow-up added keyboard navigation. **Not** signed/integrity-stamped (see T-13). |
| TB-7 | Build pipeline ↔ shipped artifacts | SwiftPM dependency graph pinned by `Package.resolved`; ad-hoc-signed dev builds; Developer-ID signing + notarization is manual (`ARCHITECTURE.md:307-309`). |
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
| `config.yaml` parsing | `YAMLCodec` (Swift) | Untrusted-ish: user-edited, but could be replaced by A1 |
| Cached JSON parsed by `ReportEngine` | `app/Sources/JamfReports/Engine/*` | Source-of-truth originates from Jamf, but file is replaceable by A1; **integrity-checked against manifest** (PR-7) for files under `jamf-cli-data/` |
| `summary.json` parsed by `RunHistoryService.isPartialRun` + `LaunchAgentService.checkSummaryFileForPartialStatus` | partial-status authoritative source | **Not manifest-covered** (T-12) |
| CSV imports (Jamf Pro export, Jamf School export) | `ReportEngine` / `CSVFamilyDetector` | Auto-detects family + delimiter; cell values neutralized by `OOXMLWriter.sanitizeString` before write |
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
  - **SHA-256 manifest verify (PR-7):** Swift `SnapshotManifest.verify` /
    `scanWorkspace` / `scanFlatDir` read each cached file once → verify the hash
    against the sibling `manifest.json` → parse from the same buffer (single-read
    pattern closes the verify-then-parse TOCTOU race). AuditView surfaces an
    "Unverified snapshot" card, and `jamf_cli.require_manifest: true` promotes
    warn-only mismatches to a hard generate-time abort (`ReportEngine` strict
    pre-flight). **Producer caveat — see Residual:** the per-`jamf-cli-data/<kind>/`
    snapshot `manifest.json` was written by the (now-removed) Python collector;
    the Swift collect path does not yet write it, so for JSON snapshots the verify
    side currently has no producer.
  - `WorkspacePermissionHardener.tighten()` sets snapshot files to 0600 and directories to 0700.
  - Generation is idempotent and re-runs against fresh API data via `collect`.
- **Likelihood:** Low (with manifest); Medium (when manifest absent — see T-11).
- **Impact:** Medium (no credential loss; downstream decisions distorted).
- **Priority: LOW–MEDIUM** (was MEDIUM; downgraded for manifest-covered files; T-11 / T-12 / T-13 cover residual integrity gaps).
- **Recommended mitigations:**
  - **Restore a snapshot-manifest writer in the Swift collect path.** With the
    Python collector removed, nothing writes the `jamf-cli-data/<kind>/manifest.json`
    (or the `summaries/` manifest) any longer. `SnapshotManifest.verify` now
    returns `.absent` for JSON snapshots, and `require_manifest: true` would
    hard-fail every generate. The state-file manifest (`StateFileStore.rewriteManifest`,
    T-21) and the report-artifact sidecar (`ReportEngine.writeManifestStatic`,
    T-13) are unaffected — both are Swift writers. This is the top integrity
    follow-up.
  - Add a UI banner in the Sources screen showing the last-verified-manifest timestamp.
- **Residual (accepted — Epic #103 item 14):** Even when a snapshot manifest is
  written, the writer rewrites the whole `manifest.json` and re-hashes from disk
  every other `.json` in the directory (older snapshots retained by
  `keep_latest_runs`, per-day summaries). An A1 attacker who tampers one of those
  files in the window before the next manifest write gets the tampered content
  re-hashed and recorded as authoritative. Accepted because: (1) it requires A1 —
  local write access to `jamf-cli-data/`; (2) the manifest is unsigned, so an A1
  attacker can already rewrite it wholesale — the re-hash window grants no
  capability A1 lacks; (3) the manifest is a tamper-*detection* aid against
  non-A1 actors and accidental corruption, not a tamper-*prevention* mechanism
  against A1. `require_manifest` remains available for deployments that want
  hard-fail on any mismatch (subject to the producer caveat above).

### T-3. HTML report content-injection via attacker-controlled Jamf fields
- **Goal:** Pop XSS / launch URL handlers when a sysadmin opens a shared HTML report in a browser.
- **Path:** A6 (or a malicious user controlling a device record) injects HTML/JS into a device name, EA value, or policy name.
- **Existing mitigations:**
  - Swift `HtmlSectionFormatters.escapeHTML` wraps every dynamic insertion in `HtmlReport` (see `HtmlReport+Sections.swift:9` — "All user-controlled strings MUST go through `escapeHTML`").
  - HTML output is self-contained — no remote `<script src>`.
  - **PR-3 added landmarks + table captions** for a11y, no XSS regression.
- **Likelihood:** Low — escaping is centralized.
- **Impact:** Medium.
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - Add a meta CSP (`default-src 'self' 'unsafe-inline'`; `script-src 'none'`) to the HTML head.
  - Add Swift malicious-payload tests over the HTML/CSV sinks (`<script>`, `"><img onerror>`, `=SUM`, `+1+1`, etc.) — the prior Python `test_sanitization.py` corpus was removed with the Python engine.
  - Lint/regex check that any new `HtmlReport` interpolation site routes through `escapeHTML`.

### T-4. CSV/spreadsheet formula injection in generated XLSX or CSV exports
- **Goal:** When a recipient opens a generated XLSX or CSV in Excel/Numbers, a leading `=`, `+`, `-`, `@`, or `\t` triggers `WEBSERVICE` / `HYPERLINK` / DDE.
- **Path:** A6 / a device record or patch title with attacker-controlled metadata.
- **Existing mitigations:**
  - Swift `OOXMLWriter.sanitizeString` prepends a tab to any cell beginning with `=+-@` — the documented XLSX invariant (CLAUDE.md), verified clean in the PR-26 security review.
  - **PR-25 Patch Compliance CSV export:** `PatchStatusService.csvField` neutralizes the same formula-injection prefixes before RFC 4180 quoting; covered by `testComplianceCSVNeutralizesFormulaInjection`. This was a MUST-FIX caught in the PR-26 security review and folded into PR-25 before merge.
- **Likelihood:** Low.
- **Impact:** Medium.
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - Per-run counter + end-of-run summary of how many cells `OOXMLWriter.sanitizeString` truncated / sanitized (BACKLOG N-13 — formula-injection silent truncation).
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
  - **PR-A / PR-7 / PR-9 LogRedactor:** 10 patterns enforced in Swift (`LogRedactor.patterns`): `client_secret`, `client_id`, `Bearer <token>`, JWT, `access_token`, `refresh_token`, `password`, `api_key`/`apikey` (PR-9), HTTP Basic, `webhook_url`. Applied at `RunHistoryService.loadLog` (UI render) AND `RunsView.exportLogFile` (file export — CR-1 fix in PR-7). Raw log on disk untouched per design.
  - Diagnostic-bundle (`DiagnosticBundleService` + `DiagnosticRedactor`) redacts both free-text credential patterns AND exact-key JSON values, plus HMAC-SHA256 PII placeholders. Default-on; the `doctor.json` capture strips the server hostname via `redactJSON`.
- **Likelihood:** Very Low.
- **Impact:** Critical (if leaked).
- **Priority: LOW.**
- **Recommended mitigations:**
  - Canary-in-logs regression test (insert known fixture secret value, assert it appears nowhere in `automation/logs/` / clipboard / file export / diagnostic bundle).
  - Audit any NEW credential pattern that may flow through logs (e.g., Jamf School API key new shapes) and add the matching pattern to `LogRedactor`.

### T-8. `jamf-cli` exit-code mishandling causes silent data corruption
- **Goal:** Get the app to silently fall back to stale cached data after an auth or permission change.
- **Path:** Auth expires (exit 3) or role privilege revoked (exit 5). Only exit 3 hard-aborts; 4/5/6 warn-and-fall-back-to-cached.
- **Existing mitigations:**
  - `authGuard` probes the token before each live call.
  - Run logs in `automation/logs/` record warnings.
  - **PR-7 stale banner** on `DeviceLookupView` surfaces last-fetched-X-ago via `RelativeDateTimeFormatter` when live calls fall back to cache.
  - **PR-8 partial-status pill:** `Schedule.LastStatus.partial` case rendered with distinct icon (`exclamationmark.triangle.fill`) in `RunsView` + `SchedulesView`. Operators see PARTIAL pills instead of green OK on partial runs. Authoritative source = sibling `summary.json` `{"status":"partial"}` with `[partial]` log marker as fallback.
- **Likelihood:** Medium (auth/privilege drift is common).
- **Impact:** Low–Medium.
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - Extend stale-data banner pattern to TrendsView / DevicesView / Posture dashboards (BACKLOG: T-15 broader application, deferred per anti-churn rule).
  - Audit the Swift summary builders (`ReportEngine`) for decode-failure zero-fill (the Python summary-builder zero-fill items N-09 / N-20 are retired with that engine; confirm the native path omits rather than zero-fills `patchPct` on failure).

### T-9. Supply-chain: malicious dependency or PR
- **Goal:** Bundle backdoored code into a release.
- **Path:** A6 introduces a malicious commit that bumps a SwiftPM dependency to a compromised version (or edits `Package.swift` / `Package.resolved`), or backdoors the build/release scripts.
- **Existing mitigations:**
  - **Minimal dependency graph:** the app has a single external SwiftPM dependency (ZIPFoundation), pinned by `app/Package.resolved` (revision + version). A bump requires a `Package.resolved` change visible in the diff.
  - jamf-cli is verified by Team-ID code signature at every spawn (T-1) — a malicious bumped binary still has to pass that gate.
  - CODEOWNERS file present.
- **Likelihood:** Low.
- **Impact:** High (signed/notarized release would ship the payload).
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - Branch protection on `main` + required CODEOWNERS reviews for any change to `Package.swift`, `Package.resolved`, the `app/scripts/` release tooling, and `JamfCLIIdentity.expectedTeamID`.
  - Pin SwiftPM dependencies to exact revisions in `Package.resolved` and review every bump.

### T-10. `YAMLCodec` parsing of a hostile `config.yaml`
- **Goal:** Code execution or path escape via crafted YAML.
- **Path:** A1 swaps `config.yaml` for a malicious file.
- **Existing mitigations:**
  - Swift `YAMLCodec` is a minimal hand-rolled reader/writer — it parses only the scalar/map/sequence subset the GUI exposes, with no tag/anchor/constructor machinery that could instantiate arbitrary objects.
- **Likelihood:** Low.
- **Impact:** Low–Medium.
- **Priority: LOW.**
- **Recommended mitigations:**
  - Property-based / fuzz tests against `YAMLCodec` for malformed input.

### T-11. Snapshot manifest absence treated as silent pass (NEW, defense evasion)
- **Goal:** Bypass PR-7's SHA-256 integrity control by deleting the manifest itself.
- **Path:** A1 modifies a snapshot AND deletes the matching `manifest.json` entry (or the whole file). Swift `SnapshotManifest.verify` returns `.absent`/`.corrupt` when the manifest is missing/unparseable. The comment at `SnapshotManifest.swift:11-16` documents the no-abort behavior as intentional ("partial-collect crashes look the same as tampering") — the resolution is a UI warning, not silence.
- **Existing mitigations:** **Surfaced by PR-10.** `jamf_cli.require_manifest: true`
  (and the "Require snapshot manifest" toggle in Configuration → jamf-cli Cache)
  hard-fails generation on missing or unparseable manifests via `ReportEngine`'s
  strict pre-flight. AuditView surfaces an "Unverified snapshot" warning card
  listing the count and breakdown of unverified snapshot directories regardless of
  the config setting, so manifest absence is visible rather than a silent pass.
- **Producer caveat (2026-06-18, single-engine):** the `jamf-cli-data/<kind>/`
  snapshot `manifest.json` was written by the removed Python collector; the Swift
  collect path does not yet write it (see T-2). Until a Swift snapshot-manifest
  writer lands, JSON snapshots verify as `.absent` by default and
  `require_manifest: true` would block every generate. The AuditView surfacing
  still makes the unverified state visible. (The state-file manifest, T-21, and
  report-artifact sidecar, T-13, remain produced by Swift.)
- **Likelihood:** Low (manifest absence is surfaced, not silent).
- **Impact:** Defeats T-2 control. Medium.
- **Priority: LOW — surfaced by PR-10** (was HIGH); reopened as a producer gap by the single-engine change (see T-2 recommended).
- **Residual:** A workspace that never enables `require_manifest` still renders
  tampered data, but the AuditView card makes the unverified state visible.

### T-12. `summary.json` outside manifest coverage; authoritative for PR-8 PARTIAL pill (NEW)
- **Goal:** Flip a `.partial` run status to `.ok` in the UI by editing one untrusted file.
- **Path:** PR-8's `RunHistoryService.isPartialRun` reads `<workspace>/snapshots/computers/summaries/summary_<ts>.json` and trusts the `status` field. A1 edits `"status": "partial"` → `"status": "ok"`; the UI downgrades from a yellow pill to a green checkmark unless the summary's SHA-256 is verified against a sibling manifest.
- **Existing mitigations:** Swift `RunHistoryService.isPartialRun` and
  `LaunchAgentService.checkSummaryFileForPartialStatus` verify the summary file's
  SHA-256 against a sibling `manifest.json` (via `SnapshotManifest.verify`) before
  trusting `status` — a tampered or corrupt summary falls back to the `[partial]`
  log-marker scan rather than silently misreporting the pill.
- **Producer caveat (2026-06-18, single-engine):** the summaries-directory
  `manifest.json` that PR-11 introduced was emitted by the Python generate path.
  The Swift verify side is intact, but with the Python engine removed the
  summaries manifest currently has no producer, so verification falls back to the
  `[partial]` log-marker scan. The log-marker fallback keeps the pill honest; the
  SHA-256 cross-check is dormant until a Swift summary-manifest writer lands (see
  T-2 recommended).
- **Likelihood:** Low (the `[partial]` log marker remains authoritative on fallback).
- **Impact:** Undermines a UI control PR-8 added. Low–Medium.
- **Priority: LOW** (was MEDIUM); the SHA-256 leg is a producer gap after the single-engine change — fold into the T-2 writer follow-up.

### T-13. Generated Reports (XLSX/HTML) have no integrity envelope (NEW)
- **Goal:** Tamper with a leadership-bound report between generation and recipient open.
- **Path:** No code execution required — `open -e report.html`, change "FileVault: 100%" to "FileVault: 60%", save, send. Or modify a row in the XLSX. The generation pipeline produces no signature, no embedded hash, no sidecar.
- **Existing mitigations:** **Closed by PR-12.** Every generated `.xlsx` ships a
  `<basename>.xlsx.sha256` sidecar in `shasum -a 256 -c` format; generated HTML
  embeds a `<meta name="report-sha256">` tag plus a visible source-fingerprint
  footer with the verification procedure. The app's "Report ready" toast and the
  Generate sheet's completion banner surface the digest. Produced by the Swift
  engine's `ReportEngine.writeManifestStatic`.
- **Likelihood:** Low (recipients can verify; tamper is detectable).
- **Impact:** Medium (cross-trust-boundary: recipient acts on tampered data).
- **Priority: LOW — CLOSED by PR-12** (was MEDIUM).
- **Residual:** The sidecar / meta tag is an integrity *hint*, not a signature —
  an attacker who controls both the report and its sidecar can rewrite both. It
  raises tamper cost and gives a careful recipient a check; it is not a
  cryptographic guarantee.

### T-14. Codesign-gate stat/exec TOCTOU (NEW, accepted)
- **Goal:** Swap a verified binary between codesign check and exec.
- **Path:** Race window between `JamfCLIIdentity.ensureVerifiedJamfCLI` (calls `stat` + `codesign --verify`) and `process.run()`.
- **Existing mitigations:** Window narrowed to microseconds by inlining the gate immediately before exec. Install-time gate at `JamfCLIInstaller.swift:543` raises the cost of the initial path swap.
- **Likelihood:** Very Low (requires precise timing + same-user write to the binary path).
- **Impact:** Critical (same as T-1).
- **Priority: LOW (ACCEPTED).** No fix proposed without an `fexecve`-style API.
- **Documented:** if Apple ever exposes a verify-then-exec-from-handle API, revisit.

### T-15. Run-log mtime attacker-controllable; PR-7 stale-data banner suppressible
- **Goal:** Hide a stale-cache condition from the user by forging the snapshot file's mtime.
- **Path:** A1 runs `touch -t` on the cached snapshot; `RelativeDateTimeFormatter` then reads the forged mtime; stale banner reports "fresh".
- **Existing mitigations (updated Epic #103 / PR-7):**
  - Per-cache `.meta` sidecar (`<cache>.json.meta`) written atomically by
    `CLIBridge.writeDeviceDetailFreshnessSidecar` on every successful live-data refresh.
    The sidecar holds `{"generated_at": "<ISO-8601 UTC>"}` and is removed before each
    fresh write so a forged-old-timestamp sidecar cannot survive a live refresh.
  - `freshnessTimestamp(for:)` in DeviceLookupView prefers the sidecar over mtime.
    It falls back to `contentModificationDate` only when the sidecar is absent (caches
    written before this fix) or unparseable (truncated write).
  - The sidecar uses `.meta` extension (not `.json`) so it is invisible to all services
    that scan `jamf-cli-data/` with `pathExtension == "json"` filters
    (DeviceLookupIndex, CompliancePostureService, PolicyHealthService, PatchStatusService).
    `SnapshotManifest` was intentionally not extended — an optional Decodable field with
    no reader is unwired scaffolding; the device-detail cache is a Swift on-demand write,
    never manifested.
- **Residual:** An attacker with write access to both the cache file and its `.meta` sidecar
  can rewrite both. This fix specifically defeats the metadata-only `touch -t` scenario;
  it does not help if the attacker can craft valid JSON.
- **Likelihood:** Low (specific tool needed; assumes A1 same-user write access).
- **Impact:** Low (decision quality only).
- **Priority: LOW (partially mitigated).** The sidecar defeats the metadata-only
  `touch -t` attack; an A1 attacker who can also write valid JSON content retains
  the capability — see Residual above.

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

Open threats first, then those closed by PR-10..PR-12.

| Threat | Priority | Notes |
|---|---|---|
| T-9 Supply-chain (SwiftPM deps / scripts) | LOW–MEDIUM | Single pinned dep (ZIPFoundation via `Package.resolved`); CODEOWNERS gap — see §9 |
| T-3 HTML XSS in shared report | LOW–MEDIUM | Centralized `escapeHTML`; Swift sink tests + meta CSP still recommended |
| T-4 XLSX formula injection | LOW–MEDIUM | `OOXMLWriter.sanitizeString` + Patch CSV escaper; Swift malicious-payload tests recommended |
| T-8 Exit-code silent fallback | LOW–MEDIUM | Stale banner + PARTIAL pill close UI surface |
| T-2 Tampered cached JSON | LOW–MEDIUM | Swift verify + AuditView surfacing; snapshot-manifest WRITER gap after single-engine change — see T-2 recommended |
| T-1 Secret exfil via shim/upstream | LOW | All 7 spawn sites codesign-gated (PR-2 + PR-6 + PR-9) |
| T-5 Symlink/traversal | LOW | Trailing-`/` enforced; PR-8 MigrationBanner verified clean |
| T-6 LaunchAgent takeover | LOW | T-6a still residual; T-6b structurally closed |
| T-7 Secret + PII leakage via logs/bundle | LOW | 10-pattern `LogRedactor`; `DiagnosticBundleService`/`DiagnosticRedactor` PII redaction (username paths, device names, extended PII keys) |
| T-10 YAML parser abuse | LOW | Minimal hand-rolled `YAMLCodec` (no tags/anchors/constructors) |
| T-14 Codesign TOCTOU | LOW (ACCEPTED) | Foundation-API limited |
| T-15 mtime-forged stale banner | LOW | `.meta` sidecar defeats `touch -t` (Epic #103); content-editing attacker residual |
| T-21 Tiered-collection state-file skip | LOW | Manifest v2 covers `state/*.last` |
| T-11 Manifest absence silent pass | LOW (surfaced, PR-10) | `require_manifest` gate + AuditView card; snapshot-manifest writer gap after single-engine change (see T-2) |
| T-12 summary.json outside manifest | LOW | Swift SHA-256 verify intact; summary-manifest writer gap — `[partial]` log marker remains authoritative |
| **T-13** Generated Reports no integrity envelope | **CLOSED (PR-12)** | `.xlsx.sha256` sidecar + HTML `report-sha256` meta tag (Swift `writeManifestStatic`) |

---

## 8. Assumptions and Open Questions

Confirmed with user (2026-05-12, refreshed 2026-05-17, re-confirmed 2026-05-20):
- **Single-admin laptop** deployment for current state — re-confirmed 2026-05-20. One trusted user per Mac, no co-resident accounts. Cross-user threats deprioritized.
- Generated report distribution is **unknown / varies** — output-side injection threats (T-3, T-4) kept at LOW–MEDIUM.
- **Public release shipped** as v2.0.0 (2026-05-20). Distribution is a notarized DMG **and** a PKG installer (PKG confirmed in scope — see T-17). The §11 annex applies to the shipped artifacts; T-16 / T-17 are live concerns, not hypothetical.
- The Developer ID signing certificate is an **individual** Apple Developer enrollment, not an organization. Recipient-Mac background-activity / Login Items prompts therefore show the individual developer's name. T-16 blast radius is one individual certificate on a single signing host.

Material assumptions still in effect:
- `JamfCLIIdentity.expectedTeamID` (`"483DWKW443"`) is the legitimate jamf-cli publisher. If false, T-1 jumps to HIGH.
- `Package.resolved` SwiftPM dependency pins are reviewed in PR and not auto-bumped without review. If false, T-9 jumps to HIGH.
- `automation/logs/` is treated as same-trust as the workspace. Verified by `WorkspacePermissionHardener` sweep; not by a permission-regression test.
- The app never auto-updates its own binary (only `jamf-cli`). If a future auto-update path is added, re-rank T-9 / T-16.
- Reports may be opened by recipients on Windows / non-macOS — relevant for T-4 (Excel-only formula evaluation).
- **(NEW)** PKG installer will NOT request admin authorization (no root scripts). If that changes, model TB-10 explicitly and add T-21 (script-as-root abuse).

---

## 9. Highest-Value Next Actions (current state)

With the report-artifact integrity envelope (T-13) shipped and the standalone
Python engine removed, the highest-value remaining actions are:

1. **Restore a Swift snapshot-manifest writer (T-2 / T-11 / T-12).** The removed
   Python collector was the only producer of the `jamf-cli-data/<kind>/manifest.json`
   and the `summaries/` manifest. Their Swift verify side (`SnapshotManifest`,
   AuditView "Unverified snapshot" card, `require_manifest` gate) is intact but
   now has nothing to verify against, so JSON snapshots read as `.absent` and the
   summary-pill SHA-256 cross-check falls back to the log marker. Add the manifest
   write at the Swift collect/generate sites so the integrity controls have a
   producer again. (The state-file manifest, T-21, and the report-artifact
   sidecar, T-13, are unaffected — both are Swift writers.)
2. **Harden the supply-chain trust boundary for a public repo (T-9).** A public
   repo accepts outside PRs. Add branch protection on `main` requiring CODEOWNERS
   review for any change to `Package.swift`, `Package.resolved`, the `app/scripts/`
   release tooling, and `JamfCLIIdentity.expectedTeamID`.
3. **Act on the release-pipeline threats now that they are near-term (§11).**
   T-16 (signing-key compromise) and T-18 (downgrade attack) are no longer
   hypothetical — keep the Developer ID certificate off CI, store it in a
   hardware token if possible, and publish a "verify build" doc carrying each
   release artifact's SHA-256 and the signing certificate fingerprint.
4. **Add a meta CSP to the HTML report (T-3)** (`default-src 'self'
   'unsafe-inline'`; `script-src 'none'`) and add Swift malicious-payload tests
   over the XLSX/CSV/HTML sinks (T-3 / T-4) — the cheapest remaining
   recipient-facing hardening steps now that the Python sanitization corpus is gone.

The diagnostic-bundle PII redaction gaps surfaced during release prep are
already closed — username path leak, free-text device names, and extended PII
keys (see T-7).

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
- [x] PR-16..PR-26 reflected: tiered-collection surface (T-21, `state/` store), xlsx-corruption fix + Patch CSV export (T-4), single-admin + public-release prep re-confirmed with user 2026-05-20 (§8).
- [x] PR-10/PR-11/PR-12 reflected: T-13 CLOSED (§6/§7); T-11/T-12 surfaced (Swift verify intact).
- [x] **Single-engine refresh (2026-06-18):** standalone Python CLI removed; Python-only threat surface (runtime supply chain, `yaml.safe_load`, Python sanitization corpus, `_safe_write`) dropped; every Swift control kept. **Producer gap flagged:** the snapshot-/summary-manifest writer was Python-only — T-2/T-11/T-12 verify sides now lack a producer (see §9 item 1). State-file (T-21) and report-artifact (T-13) manifests stay Swift-produced.

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
