# Threat Model — jamf-reports-community

Repository: `jamf-reports-community` (native macOS Swift app)
Original model: 2026-05-12
Refreshed: 2026-05-17 (post PR-1..PR-9 backlog-burndown sequence)
Refreshed: 2026-05-20 (post PR-16..PR-26 — tiered collection, xlsx-corruption fix, Patch CSV export)
Refreshed: 2026-05-20 (v2.0.0 release prep — §7/§9 reconciled: T-11/T-12/T-13 confirmed closed by PR-10/11/12; diagnostic-bundle PII redaction hardened)
Refreshed: 2026-06-18 (single-engine — standalone Python CLI removed; native Swift `ReportEngine` is the sole engine; Python-specific threat surface dropped)
Refreshed: 2026-10-10 (2.9.0: SMAppService background item, shared workspaces, jamf-cli trust chain, Swift manifest writer, issue-triage workflow; new entries T-23..T-27)
Scope basis: full repo (`app/`, CI workflows, scripts)

Operator-facing version of the controls below: [Security & Operational Considerations](../wiki/10-Security-and-Operational-Considerations.md) (wiki page 10). Working architecture reference: [`CLAUDE.md`](../../CLAUDE.md).

---

## 1. Scope and System Model

### In scope
- Native macOS app under `app/` (Swift 6, SwiftPM, macOS 15+).
- Build/release tooling: `app/build-app.sh`, `app/build-pkg.sh`, `app/scripts/` (sign/notarize/package).
- GitHub Actions workflows in `.github/workflows/`.
- Per-profile workspaces at `~/Jamf-Reports/<profile>/`.
- The one `SMAppService` background item (`--tick`) that ships inside the signed app bundle, and the per-Mac schedule store it reads (`~/Library/Application Support/JamfReports/schedules.json`). The app writes nothing to `~/Library/LaunchAgents`; a legacy plist found there is read once for import and then archived.
- Workspaces shared by several Macs through a sync provider (2.7.0), and the GitHub issue-triage workflow (`.github/workflows/issue-triage.yml`).
- **(2026-05-17 addition)** Planned external distribution: notarized DMG **and** PKG installer for delivery to other organizations running their own Jamf Pro / Jamf School deployments.

### Out of scope (referenced, not modeled here)
- The external `jamf-cli` binary (Go, separate repo) — treated as a trusted external dependency once code-signature verification passes (`CodeSignVerifier.verify` against a designated requirement, run through `CLIBridge.codesignGate` / `JamfCLIIdentity.ensureVerifiedJamfCLI` at every site that launches `jamf-cli`, and `OnboardingFlow.verifyJamfCLISignatureGate` on the onboarding PTY path). See T-1.
- Jamf Pro / School / Protect servers themselves.
- Recipient-org Jamf tenant compromise that is not initiated through this app — covered only at the trust boundary.

### Components and runtime
| Component | Where | Runtime role |
|---|---|---|
| `JamfReports` (GUI) | `app/Sources/JamfReports/App` | User-facing SwiftUI app; spawns `jamf-cli` |
| `main.swift` (headless modes) | `app/Sources/JamfReports/App/main.swift`, `App/Tick.swift` | Entry for `--tick` (the bundled background item, woken every 300 s), `--scheduled-run` (external scheduler) and the `jamf-reports` CLI; collects + generates |
| `ReportEngine` (native engine) | `app/Sources/JamfReports/Engine/*` | Reads cached JSON, writes XLSX/HTML/CSV |
| `CLIBridge` | `app/Sources/JamfReports/Services/CLIBridge*.swift` | `Process`-based async wrapper for `jamf-cli`; environment hardening; codesign gate (`codesignGate`) |
| `LogRedactor` | `app/Sources/JamfReports/Services/LogRedactor.swift` | Free-text + JSON credential redaction (`LogRedactor.patterns` plus webhook URL patterns) |
| `SnapshotManifest` | `app/Sources/JamfReports/Engine/SnapshotManifest.swift` | SHA-256 manifest reader/verifier (PR-7) and writer (`record`, 2.6, active when `jamf_cli.require_manifest` is true) for `jamf-cli-data/<kind>/*.json` |
| Background item | `Contents/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.tick.plist` inside the signed app bundle, registered through `SMAppService` (`TickerRegistrar`) | Runs `JamfReports --tick` every 300 s. `TickScheduler.due` decides which schedules run (managed ones derived from `AutomationPolicy`, hand-built ones from `ScheduleStore`, legacy imports). `TickLock` (pid file) keeps one run at a time; `TickRunner` run-now markers live in Application Support. macOS lists the item in Login Items and Extensions and can require approval (BTM). |
| `ScheduleStore` | `~/Library/Application Support/JamfReports/schedules.json` (0600, directory 0700) | Per-Mac JSON of hand-built schedules. Never in the workspace, which may be a synced folder. |

### Data stores
- `~/Jamf-Reports/<profile>/jamf-cli-data/<kind>/<kind>_<stamp>.json` — cached snapshots (0600). Manifest-covered when `jamf_cli.require_manifest` is true (writer since 2.6). Not stamped: the SOFA cache, `patch-release-dates`, and the `summaries/` directory.
- `~/Jamf-Reports/<profile>/jamf-cli-data/state/<kind>.last` — per-kind last-success timestamps read by the cadence filter in `ReportEngine.collect`. Listed in a `state/manifest.json` of SHA-256 hashes written beside them (`StateFileStore.rewriteManifest`). The manifest is unkeyed, so it detects corruption, not tampering by a writer — see T-21.
- `~/Jamf-Reports/<profile>/Generated Reports/*.{xlsx,html}` — outputs. **Not** manifest-covered (see T-13).
- `~/Jamf-Reports/<profile>/snapshots/computers/summaries/*.json` — trend history. **Not** manifest-covered (see T-12).
- `~/Jamf-Reports/<profile>/automation/logs/` — per-run logs. Credential patterns are redacted when the line is written (`ScheduledRunRecorder.record`) and again at display and export (`RunHistoryService.loadLog`, `RunsView.exportLogFile`, `LogRedactor.redactedForSharing`).
- `~/Jamf-Reports/<profile>/config.yaml` — column mapping, `jamf_cli.profile`, output and retention settings, `notify.url`, `shared_workspace`. On a shared workspace this file is the one every Mac reads (see T-23).
- macOS Keychain (managed by `jamf-cli`, not this app) — long-term Jamf API client secret.
- **(2026-05-17 addition)** Release artifacts in GitHub Releases (`*.dmg`, `*.pkg`, SHA-256 of each).

---

## 2. Trust Boundaries

| # | Boundary | Mechanism / controls observed |
|---|---|---|
| TB-1 | User UI ↔ on-disk workspace | `ProfileService.isValid` accepts every jamf-cli name except an empty one, control characters, a leading or trailing space, or an over-long name (2.8.3; capitals from 2026-09). No path, file name or label takes the raw name: `ProfileName.pathComponent` percent-encodes `%`, `/`, `:`, control characters and a leading `.`/`_`, so `..` and `a/b` stay one folder under the root, and `ProfileName.labelComponent` keeps `.` out of a label's profile part, which closes S-03's label ambiguity without the PR-3 dotted-slug rejection. A workspace recorded for a case-variant spelling (`ProfileName.folderKey`, accents included) is never rebound or collected into, since both names resolve to one folder on a case-insensitive volume; `WorkspacePaths` typed constants; `SystemActions.canonicalize` resolves symlinks then a `hasPrefix(root + "/")` check. |
| TB-2 | App ↔ `jamf-cli` subprocess | `CLIBridge.environmentForJamfCLI()` pins a minimal env (`PATH`, `HOME`, `LANG`, `TMPDIR`, plus the `jamfCLIAllowedEnvKeys` proxy variables). `CLIBridge.codesignGate` verifies the code signature before every launch of a binary named `jamf-cli`, at every site (see T-1). |
| TB-3 | App ↔ Jamf Pro/School/Protect servers (over network) | TLS via `jamf-cli`; `CLIBridge.authGuard` probes `pro auth token` before live calls; School profiles skip probe (API-key auth). |
| TB-4 | App ↔ macOS Keychain | Indirect — only `jamf-cli` reads/writes; secret passed by app via PTY stdin during onboarding (`OnboardingFlow.registerJamfCLIProfile`) with `resetBytes` zeroing after dispatch. |
| TB-5 | Background item ↔ app headless mode | One `SMAppService` user agent declared inside the signed bundle; it only runs `--tick`. The app writes no plist and calls no `launchctl`; no LaunchDaemons, no `sudo`. Per-Mac state (`schedules.json`, `tick-state.json`, run-now markers, `.tick.lock`) lives in Application Support, outside any workspace. |
| TB-6 | Generated HTML report ↔ downstream readers | Centralized escaping via `HtmlSectionFormatters.escapeHTML` — every dynamic insertion in `HtmlReport` routes through it. HTML output is self-contained (no remote `<script src>`). PR-3 added landmarks + table captions; PR-3 follow-up added keyboard navigation. **Not** signed/integrity-stamped (see T-13). |
| TB-7 | Build pipeline ↔ shipped artifacts | SwiftPM dependency graph pinned by `Package.resolved` (currently two dependencies: ZIPFoundation and, as of 2.4.0, swift-argument-parser); ad-hoc-signed dev builds; Developer-ID signing, notarization and packaging run on the maintainer's Mac through `app/scripts/release.sh` (see [`app/scripts/README.md`](../../app/scripts/README.md)), not in CI. |
| TB-11 | **(2.4.0)** App ↔ `/usr/local/bin` (CLI install) | `CLIInstaller` symlinks the in-bundle binary into a PATH dir on user request. No privilege escalation — writes only when the target dir is already user-writable, otherwise returns a `sudo` command for the user to run. Inspects the destination first: replaces a stale symlink, refuses to clobber a real file. |
| TB-8 | Repo CI workflows ↔ release artifacts and maintainer credentials | `.github/workflows/{ci,release,issue-triage}.yml`. Every third-party action is pinned to a commit SHA. `release.yml` builds a source zip only; it holds no signing material. `issue-triage.yml` is the one workflow that feeds untrusted text (issue title and body from anyone) to a model; what bounds it is in T-27. |
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
| `config.yaml` | Reveals org-specific EA names + Jamf URL; pre-onboarding bootstrap values. Also steers output folders, retention mode and the webhook URL (see T-23). |
| `schedules.json` and the bundled background item | A writer to `~/Library/Application Support/JamfReports/` can change which schedules the tick runs, but already has user-level execution. The agent plist inside the bundle is covered by the bundle signature. |
| App binary itself | Hardened-Runtime, ad-hoc-signed for local builds; release signing and notarization are scripted (`release.sh`) and run locally. |
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
| CLI subcommand invocation (`jamf-reports <cmd>`) | `main.swift` → `JamfReportsCLI` (`CLI/`) | Same-user, same trust as GUI; thin shells over existing engine entry points, args parsed by `swift-argument-parser`. Profile slugs validated via `ProfileService.isValid`; user-supplied `--output`/`--out` paths run through the same `WorkspacePaths.isSensitiveAbsolutePath` deny-list the GUI uses (`CLIRun.requireSafeOutput`), so a CLI write can't clobber `~/.ssh`/`~/Library`. No new privileged operation |
| Headless invocation by the bundled background item or an external scheduler | `main.swift`, `App/Tick.swift` | `--tick` (the background item) and `--scheduled-run` (an external scheduler); `--tick --now <label>` is how the GUI and `jamf-reports schedules run` start a schedule immediately |
| `config.yaml` parsing | `YAMLCodec` (Swift) | Untrusted-ish: user-edited, but could be replaced by A1 |
| Cached JSON parsed by `ReportEngine` | `app/Sources/JamfReports/Engine/*` | Source-of-truth originates from Jamf, but file is replaceable by A1; **integrity-checked against manifest** (PR-7) for files under `jamf-cli-data/<kind>/` when `jamf_cli.require_manifest` is true |
| `summary.json` parsed by `RunHistoryService.isPartialRun` + `LaunchAgentService.checkSummaryFileForPartialStatus` | partial-status authoritative source | **Not manifest-covered** (T-12) |
| CSV imports (Jamf Pro export, Jamf School export) | `ReportEngine` / `CSVFamilyDetector` | Auto-detects family + delimiter; cell values neutralized by `OOXMLWriter.sanitizeString` before write |
| jamf-cli stdout (JSON) | `CLIBridge.runJSON` | Parsed; effectively trusted because the binary is codesign-verified at every launch |
| Onboarding stdin (client ID + secret) | `OnboardingFlow` PTY setup | Untrusted user input, passed straight to `jamf-cli` |
| `schedules.json` and run-now markers (read-back) | `ScheduleStore`, `TickRunner` | Could be attacker-modified by A1; a synced `schedules.json` is an operator error the wiki warns against |
| Legacy LaunchAgent plist (one-time import) | `LaunchAgentService.parse`, `ScheduleImport` | Read once, label checked with `LaunchAgentWriter.isValidLabel`, then archived with webhook URLs scrubbed |
| Peer Macs writing the shared workspace | `SharedWorkspace`, `ConfigLoader` | A peer can write `config.yaml`, snapshots and claims through the sync provider (T-23) |
| SOFA feed response | `SOFAFeedService` | HTTPS fetch from `sofafeed.macadmins.io` (T-26) |
| GitHub issue text | `issue-triage.yml` | Written by anyone; reaches a model (T-27) |
| GitHub Actions triggers | `.github/workflows/` | PRs from outside collaborators |
| **(NEW)** DMG mount + drag-install | macOS Finder + Gatekeeper | Recipient-side; Gatekeeper enforces notarization |
| **(NEW)** PKG installer execution | `/usr/sbin/installer` | Recipient-side; runs pre/post-install scripts; can request admin auth (we should NOT) |
| **(NEW)** Homebrew tap install (if used) | `brew install --cask jamf-reports-community` | Recipient-side; tap repo integrity is GitHub-level |

---

## 6. Threats (abuse paths)

For each: **goal → path → assets → likelihood × impact → priority**, with file evidence where applicable. Mitigations split into **existing** vs **recommended**. T-1..T-10 updated to reflect PR-1..PR-9 work; T-11..T-15 added from post-PR review batch; T-16..T-20 are post-release (see §11); T-21 added 2026-05-20 for the PR-22 tiered-collection surface; T-23..T-27 added 2026-10-10 (shared workspaces, dashboard frame, custom workspace root, SOFA feed, issue triage). T-16..T-20 stay in the §11 annex.

### T-1. Malicious shim in place of `jamf-cli` exfiltrates onboarding secret or command-time data
- **Goal:** Steal the Jamf API client secret during onboarding, or hijack a later routine command to receive credentials / corrupt collected data.
- **Path:** A1 (local same-user malware) replaces the `jamf-cli` binary in a directory the app searches (`/usr/local/bin`, `/opt/homebrew/bin`), or A4 backdoors the Homebrew tap or release package.
- **Assets:** API client secret → full Jamf tenant compromise. Also: live inventory data → ability to fabricate compliance posture.
- **Existing mitigations:**
  - **Onboarding gate:** `OnboardingFlow.verifyJamfCLISignatureGate` runs before the secret is written to stdin. The resolved binary path is verified again immediately before `process.run()` in the PTY launch, on both auth paths (see T-14).
  - **Install gate:** `JamfCLIInstaller` re-verifies after an install or update.
  - **Routine-command gate (PR-2 M-01 + PR-6 + PR-9):** every site that launches a binary named `jamf-cli` goes through `CLIBridge.codesignGate`, which calls `JamfCLIIdentity.ensureVerifiedJamfCLI`: `CLIBridge.run`, `runAndCapture`, `runDeviceDetailProcess`, the version probes (`Provenance`, `JamfCLIInstaller`), `ProfileService.discoverJamfCLIProfiles`, `ProfileAuthMethod` and the diagnostic bundle's `doctor` and `--version` probes.
  - **What the gate checks:** `CodeSignVerifier.verify` builds a designated requirement, `anchor apple generic and certificate leaf[subject.OU] = "<team>"`, and checks the binary against it with strict validation. A self-made or ad-hoc signature that only carries the Team ID string fails. The Team ID is pinned in `JamfCLIIdentity.expectedTeamID`; `JamfCLIInstaller.expectedJamfTeamID` holds a second copy and the two must agree.
  - **Cache:** a per-process set keyed on `JamfCLIIdentity.Fingerprint`: symlink-resolved path, size, inode, mtime and ctime, read with one `stat()`. ctime cannot be set from userland, so an in-place rewrite that restores mtime with `utimes` still invalidates the entry. A failed verify is never cached. It throws `CLIBridgeError.codesignRejected`, writes a `[fatal] jamf-cli signature verification failed` line to the run feed and spawns nothing.
  - **Stdin scrubbing:** Stdin buffer zeroed via `resetBytes(in:)` after dispatch.
  - **Pinned env:** `environmentForJamfCLI` is the default for all `CLIBridge.run` / `runAndCapture` (S-02, PR-2). Allow-listed: `PATH/HOME/LANG/TMPDIR` plus proxy variables.
- **Likelihood:** Low (4 stacked defenses; M-01 fully closed).
- **Impact:** Critical (full tenant secret + data integrity).
- **Priority: LOW.** M-01 closure removed the routine-command exposure window at every launch site. Residual = T-14 (TOCTOU, the fork-and-exec bypass of a post-launch check, no revocation checking) and upstream compromise (A4) producing a validly signed malicious binary.
- **Residual risk:** see T-14 for the accepted gaps in the check itself.
- **Recommended mitigations:**
  - Document and review `JamfCLIIdentity.expectedTeamID` and `JamfCLIInstaller.expectedJamfTeamID` (`"483DWKW443"`) for changes in PRs (CODEOWNERS rule).
  - When `jamf-cli` is auto-updated via `JamfCLIInstaller`, log the post-update signing certificate fingerprint to `automation/logs/` so a silent identity flip is auditable.

### T-2. Tampered cached JSON leads to misleading reports / charts shared with management
- **Goal:** Cause incorrect compliance/inventory data to be reported.
- **Path:** A1 modifies `~/Jamf-Reports/<profile>/jamf-cli-data/*.json` between collect and generate.
- **Assets:** Integrity of generated reports → operational/compliance decisions.
- **Existing mitigations:**
  - **SHA-256 manifest verify (PR-7):** Swift `SnapshotManifest.verify` /
    `scanWorkspace` / `scanFlatDir` read each cached file once, verify the hash
    against the sibling `manifest.json`, then parse from the same buffer (single-read
    pattern closes the verify-then-parse TOCTOU race). AuditView surfaces an
    "Unverified snapshot" card, and `jamf_cli.require_manifest: true` promotes
    warn-only mismatches to a hard generate-time abort (`ReportEngine` strict
    pre-flight).
  - **Producer (2.6):** `SnapshotManifest.record(snapshotFile:data:)` is called from
    `ReportEngine.saveSnapshot` when `jamf_cli.require_manifest` is true and stamps the
    kind's `manifest.json`, so app-collected snapshots verify as `.verified`. A
    manifest-write failure logs and does not fail the collect. Not stamped: the SOFA
    cache, `patch-release-dates` and the `summaries/` directory. With
    `require_manifest` off (the default) nothing is stamped and snapshots read as
    `.absent`.
  - `WorkspacePermissionHardener.tighten()` sets snapshot files to 0600 and directories to 0700.
  - Generation is idempotent and re-runs against fresh API data via `collect`.
- **Likelihood:** Low (with manifest); Medium (when `require_manifest` is off, the default; see T-11).
- **Impact:** Medium (no credential loss; downstream decisions distorted).
- **Priority: LOW–MEDIUM** (was MEDIUM; downgraded for manifest-covered files; T-11 / T-12 / T-13 / T-21 cover residual integrity gaps).
- **Recommended mitigations:**
  - Stamp the remaining producers (the `summaries/` directory, the SOFA cache, `patch-release-dates`) so every cached input has a hash to verify against.
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
  hard-fail on any mismatch. On a shared workspace leave it off (wiki 10 explains the same-second collision case).

### T-3. HTML report content-injection via attacker-controlled Jamf fields
- **Goal:** Pop XSS / launch URL handlers when a sysadmin opens a shared HTML report in a browser.
- **Path:** A6 (or a malicious user controlling a device record) injects HTML/JS into a device name, EA value, or policy name.
- **Existing mitigations:**
  - Swift `HtmlSectionFormatters.escapeHTML` wraps every dynamic insertion in `HtmlReport` (see `HtmlReport+Sections.swift:9` — "All user-controlled strings MUST go through `escapeHTML`").
  - HTML output is self-contained — no remote `<script src>`.
  - The embedded jamf-cli dashboard page runs in a sandboxed frame under its own CSP (T-24).
  - **PR-3 added landmarks + table captions** for a11y, no XSS regression.
- **Likelihood:** Low — escaping is centralized.
- **Impact:** Medium.
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - The report has no CSP of its own. The earlier suggestion of a `script-src 'none'` meta policy no longer works: the report ships one inline script that drives Expand all / Collapse all, the print handling and the theme switch, and that policy would disable it. A report-wide policy would need a hash or nonce for that script. The only CSP today is the one added to the dashboard frame's page (T-24).
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

### T-6. Background item or schedule store takeover persists attacker-chosen runs as the user
- **Goal:** Persist runs that fire on every tick, or change what a schedule does.
- **Path:** Three variants:
  - **T-6a (schedule store):** A1 edits `~/Library/Application Support/JamfReports/schedules.json` or drops a run-now marker. A related operator error is syncing `schedules.json` through a cloud folder, which would let a cloud-account compromise change schedules on every Mac that syncs it.
  - **T-6b (label-parsing confusion, closed):** Previously the validator allowed `.` in profile slugs and the label parser split ambiguously.
  - **T-6c (legacy plist, import only):** a pre-2.8.0 plist in `~/Library/LaunchAgents` is attacker-modified before the one-time import.
- **Existing mitigations:**
  - The background item is one `SMAppService` agent whose plist sits inside the signed bundle (`Contents/Library/LaunchAgents/...tick.plist`), so editing it breaks the bundle signature. The app writes no plist, runs no `launchctl`, installs no LaunchDaemon. macOS shows the item in Login Items and Extensions and can require approval (BTM); `AutomationHealth` raises a `.tickerDisabled` issue when it is not enabled.
  - `ScheduleStore` is a 0600 JSON file in a 0700 directory, written atomically, and each operation re-reads it. Managed schedules are never stored; `ManagedAutomation.desiredSchedules` derives them from the policy on every tick.
  - `TickLock` is a pid file: a live holder blocks a second tick, a dead one is taken over. A run-now marker that names no schedule is dropped before anything runs.
  - **S-03 / 2.8.3:** `ProfileName.labelComponent` encodes everything outside ASCII letters, digits, `_` and `-`, so a `.` in a label is always a separator. This replaced the PR-3 rule that rejected dotted slugs.
  - **Legacy import:** `LaunchAgentService.parse` rejects a label that fails `LaunchAgentWriter.isValidLabel`; an imported plist is read once, then archived to `_archived-launchagents` with webhook URLs scrubbed. PR-8's MigrationBanner covers dotted legacy workspaces.
- **Likelihood:** Low for T-6a (assumes A1, who already has user-level execution); Negligible for T-6b and T-6c.
- **Impact:** Medium for T-6a; Low for T-6b and T-6c.
- **Priority: LOW.**
- **Residual:** `schedules.json` is trusted without a write-permission check. The wiki tells operators never to sync it (wiki 10, "Per-machine scheduling state is never safe to sync").

### T-7. Onboarding secret leakage via process arguments / logs
- **Goal:** Read the client secret from a debug log, crash dump, or process-listing.
- **Path:** A1 or a debugging mistake.
- **Existing mitigations:**
  - Secret passed via **stdin only**, not argv.
  - Stdin buffer zeroed after dispatch.
  - **LogRedactor:** the credential patterns in `LogRedactor.patterns` (`client_secret`, `client_id`, `Bearer <token>`, JWT, `access_token`, `refresh_token`, `password`, `api_key`/`apikey`, HTTP Basic, `webhook_url`) plus the Slack, Teams, Teams Workflows and Power Automate URL patterns. Run logs are redacted when `ScheduledRunRecorder.record` writes each line, so the file on disk no longer holds those secrets, and again at display and export (`RunHistoryService.loadLog`, `RunsView.exportLogFile`, `LogRedactor.redactedForSharing`, which also removes the Jamf host and tenant and environment IDs). Status markers such as `[partial]` are left readable.
  - **Diagnostic bundle** (`DiagnosticBundleService` + `DiagnosticRedactor`): credential patterns including secrets in quoted JSON (`"client_secret": "..."`), exact-key JSON values (the IP-address keys `lastIpAddress` and `lastReportedIp` are among them), IPv4 addresses, and HMAC-SHA256 PII placeholders. Seeded literals (server host, tenant and environment IDs, device names) are matched as whole words, so a seed that is also an ordinary word is not cut out of unrelated text. The `doctor.json` capture strips the server hostname via `redactJSON`. Default-on.
- **Residual:** profile slugs and schedule labels are not redacted and appear in a bundle's file names and tree listing (documented in `README.md`).
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
  - **Minimal dependency graph:** the app has two external SwiftPM dependencies, ZIPFoundation and swift-argument-parser (2.4.0), pinned by `app/Package.resolved` (revision + version). A bump requires a `Package.resolved` change visible in the diff. Both, and the bundled IBM Plex Mono fonts, are listed in `THIRD_PARTY_NOTICES.md`.
  - jamf-cli is verified against its designated requirement at every launch (T-1); a malicious bumped binary still has to pass that gate.
  - Every third-party GitHub Action is pinned to a commit SHA.
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
  - Swift `YAMLCodec` is a minimal hand-rolled reader/writer — it parses only the scalar/map/sequence subset the GUI exposes, with no tag/anchor/constructor machinery that could instantiate arbitrary objects. Nesting past `YAMLCodec.maxNestingDepth` (64) is kept as text or skipped, and `ConfigLoader.load` refuses a file over 4 MB.
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
  hard-fails generation on tampered manifests (`.mismatch`/`.corrupt`) via
  `ReportEngine`'s strict pre-flight; missing or unparseable-legacy manifests
  (`.absent`/`.omitted`) are tolerated, not hard-failed. AuditView surfaces an
  "Unverified snapshot" warning card
  listing the count and breakdown of unverified snapshot directories regardless of
  the config setting, so manifest absence is visible rather than a silent pass.
- **Producer (2.6):** the Swift collect path writes the per-kind `manifest.json`
  (`SnapshotManifest.record`) when `jamf_cli.require_manifest` is true, so with the
  option on, `require_manifest` can be satisfied. With it off, nothing is stamped and
  JSON snapshots read as `.absent`; the AuditView card still shows that state. The
  state-file manifest (T-21) and report-artifact sidecar (T-13) are separate Swift
  writers.
- **Likelihood:** Low (manifest absence is surfaced, not silent).
- **Impact:** Defeats T-2 control. Medium.
- **Priority: LOW — surfaced by PR-10** (was HIGH); the 2.6 writer closed the producer gap the single-engine change opened.
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
- **Producer gap (open):** the summaries-directory `manifest.json` was emitted by
  the removed Python generate path. The 2.6 writer stamps only snapshots saved
  through `ReportEngine.saveSnapshot`, not `summary_<date>.json`, so the SHA-256
  cross-check has nothing to read and the pill falls back to the `[partial]` log
  marker, which keeps it honest.
- **Likelihood:** Low (the `[partial]` log marker remains authoritative on fallback).
- **Impact:** Undermines a UI control PR-8 added. Low–Medium.
- **Priority: LOW** (was MEDIUM); the SHA-256 leg is dormant until the summaries directory is stamped (T-2 recommended).

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

### T-14. Codesign-gate stat/exec TOCTOU and bypasses of the check (accepted)
- **Goal:** Swap or modify a verified binary between the signature check and the exec, or run a different binary than the one checked.
- **Path:** Race window between `JamfCLIIdentity.ensureVerifiedJamfCLI` (one `stat()` for the fingerprint, then the requirement check) and `process.run()`. On the onboarding PTY path the window used to be wider: the gate ran at the top of setup, ahead of a version probe (up to 60 s) and the PTY setup, with the launch on an unresolved path. The resolved path is now re-verified immediately before `process.run()` on both auth paths, so the window matches the routine path.
- **Existing mitigations:** The gate sits directly before exec at every site. The fingerprint includes inode and ctime from the same `stat()` as size and mtime, so an in-place overwrite followed by `utimes`, or a same-content replacement, invalidates the cached approval. The install-time gate raises the cost of the initial swap.
- **Accepted residuals:**
  - The check and the exec are not atomic on POSIX (no `fexecve` path in Foundation).
  - A pid-based `SecCode` check after launch (verify the running process instead of the file) is not used. It is sound against pid reuse but bypassable: a swapped binary can fork a helper that keeps the PTY fd, then exec the real jamf-cli, so the pid being checked is clean while the helper holds the descriptor.
  - `kSecCSEnforceRevocationChecks` is not set. It fails outright when the Mac cannot reach OCSP, which includes air-gapped on-prem deployments. Revocation of Jamf's certificate is therefore not detected by this check.
- **Likelihood:** Very Low (requires precise timing + same-user write to the binary path).
- **Impact:** Critical (same as T-1).
- **Priority: LOW (ACCEPTED).**
- **Documented:** if Apple exposes a verify-then-exec-from-handle API, revisit.

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
- **Goal:** Freeze the fleet data the app shows by making the collect cadence filter believe a report is fresh when it is not.
- **Path:** A1 writes a recent (or future) timestamp into `jamf-cli-data/state/<kind>.last`. The per-kind cadence check in `ReportEngine.collect` then skips that kind's fetch; dashboards keep rendering the last-collected JSON while the schedule appears to run normally.
- **Assets:** Freshness/integrity of inventory + compliance data → operational decisions made on stale data.
- **Existing mitigations:** `StateFileStore.rewriteManifest` writes `state/manifest.json`, a list of SHA-256 hashes of the `.last` files (schema v2), and AuditView's "Unverified snapshot" card scans the `state/` directory. The manifest is unkeyed and sits beside the files it covers. It detects corruption and a partial or stale edit; a writer who can change a `.last` can rewrite the manifest to match, so it does not stop tampering by A1. Run logs record `[skip] <kind>` lines and `DataFreshnessHealth` flags kinds that have not landed, which makes an unexpectedly never-fetched kind visible.
- **Likelihood:** Low (assumes A1; a single-file edit that the manifest does not stop).
- **Impact:** Low–Medium (no credential loss; decision quality degraded).
- **Priority: LOW (accepted).** The same limit as T-2's residual: the manifest is not a defence against a local writer.
- **Recommended mitigations:** None planned. `DataFreshnessHealth` and the Run History `[skip]` lines are the detection path.

---

### T-22. Debug-logging profile / OSLog store as a local data surface (NEW, 2.4.0, accepted)
- **Goal:** Read sensitive fleet data (serials, hostnames, usernames) from the local unified-log store, or use the debug-logging toggle to widen what is captured.
- **Path:** The Settings → Logging panel writes `~/Library/Preferences/Logging/Subsystems/com.github.tonyyo11.jamf-reports-community.plist` (`DebugLoggingService`, user-owned, no escalation). With `revealPrivate` on, interpolated values OSLog normally renders `<private>` are written in full to the **local** log store; `log`/Console.app can then read them. The in-app log viewer reads only the app's own in-memory `LogBuffer` (this session's tee'd events, not the OSLog store), so `revealPrivate` output is not exposed there. The bundled `JamfReports-Debug-Logging.mobileconfig` only enables persist-verbose (never `Enable-Private-Data`).
- **Assets:** Device serials / hostnames / usernames already present on the same machine.
- **Existing mitigations:** Default posture is redacted — `revealPrivate` defaults off, is warned inline, and is intentionally absent from the MDM profile so it cannot be pushed org-wide (a `DebugLoggingProfileTests` test asserts the profile contains no `Enable-Private-Data`). All writes are to the user's own `~/Library/Preferences` (no privilege escalation, no system-wide config). In-app log **export** is always `LogRedactor`-scrubbed regardless of the reveal toggle. The in-app viewer only ever sees this session's own buffered entries, not the whole-system log.
- **Likelihood:** Low (requires local access already; reveal is an explicit, warned opt-in).
- **Impact:** Low (data is local-only and already on the box; nothing leaves the device).
- **Priority: LOW (accepted).** A local admin who can flip the toggle can already read the same data via `log`/Console directly; the feature surfaces an existing OS capability behind a redacted default. In a high-security or regulated build, leave `revealPrivate` off (and the MDM profile already cannot enable it).

### T-23. Shared-workspace peer trust: a peer's `config.yaml` steers every Mac (NEW, 2.9.0)
- **Goal:** Redirect reports, delete data or exfiltrate aggregates by changing settings that every Mac sharing a workspace reads.
- **Path:** The workspace lives in a synced folder (2.7.0, Settings → Workspace location). Anyone who can write that folder, or a compromised cloud account, can edit `config.yaml`. The file is the one place every Mac must agree on (`shared_workspace`), so each Mac reads it at its next run. Values that matter: `output.allow_absolute_paths` and `output.output_dir` / `output.archive_dir` (where finished reports go), `retention.mode` and `retention.snapshot_keep_days` (a `delete` mode with a short horizon purges raw snapshots), and `notify.url` (where the digest cards go).
- **Assets:** Fleet reports and raw snapshots (PII), snapshot history, aggregate metrics in webhook cards.
- **Existing mitigations:** The documented layouts are local-only or a folder shared with the reporting team only; wiki 10 lists everyone-with-access-can-read-PII as the main cost of a shared workspace and asks for a deliberate decision. Output folders pass `WorkspacePaths` deny-lists: system and credentials folders, `/Applications`, dot-folders under home, `/Users/Shared` and `~/Public` are refused and the run falls back to `Generated Reports` in the workspace with a `[warn]` line. Absolute output paths need `allow_absolute_paths`. Retention is off by default, `archive` moves rather than deletes, and ranking and ageing use the date in the snapshot's own file name. The webhook must be `https://`, an unparseable URL counts as a failed send, and `notify.detail: minimal` limits cards to counts. The workspace root itself, `ScheduleStore` and the tick state are per Mac and not in the folder.
- **Likelihood:** Low (needs write access to the shared folder or the sync account).
- **Impact:** Medium (reports and aggregates leave to a chosen location; retention can destroy local history).
- **Priority: LOW–MEDIUM.**
- **Existing mitigations (`SharedConfigPin`, after 2.9.0):** On a shared workspace each Mac pins, in its own Application Support (0600), the values a peer could abuse: `allow_absolute_paths`, the output, archive, data and historical-CSV folders, `retention.archive_dir`, `retention.enabled`/`mode`, the webhook host:port plus a hash of its URL, `notify.detail`, `protect.profile` and `shared_workspace.enabled` itself (so a peer cannot opt the pin off). Scheduled runs, the CLI and automatic GUI collects use the safe value for a drifted key (workspace folders, archive not delete, no webhook send, minimal detail, no borrowed Protect profile) and log one `[warn]` per key; an unreadable pin fails closed. First sight pins what it finds, but an absolute folder outside the workspace or `retention.mode: delete` stays unconfirmed, and so safe, until confirmed. Onboarding confirms exactly the keys it wrote on this Mac; a Config or notification save confirms only a key that save changed; Config Doctor lists drifts with a Confirm action that re-pins only what it showed, and a health-banner entry points at it.
- **Residual:** First-sight trust: a Mac joining a workspace a peer already tampered with pins the tampered values, except the two unconfirmed cases above. Keys judged a nuisance rather than abuse (`html.history_file`, `output.timestamp_outputs`, `keep_latest_runs`, `notify.enabled`/`provider`, `collect_skip`, `sheets`, the retention counts) are not pinned. While an automatic collect runs, GUI reads of that workspace see the safe folders. Limit write access to the folder to the reporting team regardless (wiki 10, "Configuration Integrity").

### T-24. Embedded jamf-cli dashboard frame (NEW, 2.9.0, accepted)
- **Goal:** Use script in the jamf-cli dashboard page to leave the frame, reach the report or send data out.
- **Path:** `HtmlReport+Dashboard` embeds the newest `dashboard` snapshot (a page jamf-cli 1.31+ writes) in an `<iframe srcdoc>` with `sandbox="allow-scripts"`. A hostile page, from a replaced snapshot (A1) or from attacker-influenced names in the tenant, would run script inside the frame.
- **Existing mitigations:** No `allow-same-origin`, so the page cannot read the report, its file or storage. A CSP meta is added to the page before embedding (`default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'`): no requests, frames or fonts, no `<base>`, no form posts. The report accepts a `postMessage` only from that frame, for its height. Pages over 4,000,000 bytes are not embedded. The payload is fleet aggregates and admin-set names; jamf-cli's page holds no device names, serials or usernames. The print path shows a note instead of the frame.
- **Likelihood:** Low.
- **Impact:** Low (aggregates only).
- **Priority: LOW (accepted).**
- **Residual:** A sandboxed frame may always navigate itself, and no sandbox token or CSP directive stops that (`navigate-to` never shipped). A hostile page could replace its own content or show a misleading one. Dropping `allow-scripts` would stop script but would lose the height and theme sync, collapse and filters. Open check: confirm upstream's `dashboard_html.go` builds the page with `html/template`, so tenant-supplied names are escaped at the source (tracked in epic #207, K17).

### T-25. Custom workspace root with weak ownership or permissions (NEW, 2.9.0)
- **Goal:** Read or alter workspace data by placing the workspace where another account can write.
- **Path:** The operator picks a root other than `~/Jamf-Reports` (`WorkspaceRootStore.set`), for example a folder another local account owns, or one that is group- or world-writable or carries an ACL. Snapshots, logs and `config.yaml` there would be writable by that account.
- **Existing mitigations:** `WorkspaceRootStore.validate` refuses a sensitive path, a missing or non-directory path and an unwritable one, and also a root the user does not own, one that is group- or world-writable, or one with an ACL. Folders under `/Volumes` and `~/Library/CloudStorage` are exempt because a share or sync provider reports ownership and modes its own way. `set(_:)` throws for a rejected root and nothing moves. A stored root that later becomes unreachable is not silently replaced by the default (that would start a second, empty history); Config Doctor explains why nothing reads. `WorkspacePermissionHardener` still sets 0600 files in 0700 directories.
- **Likelihood:** Low.
- **Impact:** Medium.
- **Priority: LOW.**
- **Residual:** On `/Volumes` and CloudStorage the permission checks are skipped, so those locations rely on the provider's access control (T-23 for shared folders).

### T-26. SOFA feed as an external input (NEW, 2.9.0)
- **Goal:** Skew the macOS-current, XProtect-current and Security Score figures by serving false release data.
- **Path:** `SOFAFeedService` fetches `https://sofafeed.macadmins.io/v2/<platform>` during collect, caches it under `jamf-cli-data/sofa/` and `SOFAScoreFeed` reads release dates and the XProtect version from it. A compromised feed host, or a modified cache file (A1), could report a release as newer, older or released in the future.
- **Existing mitigations:** TLS only (an ephemeral `URLSession`); there is no signature on the feed, so the connection is the only integrity check. Releases dated more than a day ahead are ignored, so a future date cannot skew the `os_current` or `xprotect_current` factors. The factors that depend on it have no data, not 0, when no feed is available. `jamf_cli.collect_skip: [sofa]` stops the fetch for a network that must not reach a third-party host; the last cached feed stays in use. This is the only non-Jamf host the app contacts.
- **Likelihood:** Low.
- **Impact:** Low (two score factors and the OS-currency sheets; no credentials involved).
- **Priority: LOW.**
- **Residual:** A feed that lies within the accepted range is believed. The cache is not manifest-stamped (T-2).

### T-27. Issue-triage workflow: prompt injection through issue text (NEW, 2.9.0)
- **Goal:** Make the triage model act on instructions hidden in an issue, or reach secrets in the runner.
- **Path:** `issue-triage.yml` runs `anthropics/claude-code-action` on newly opened issues and on the `claude` label. `allowed_non_write_users: "*"` is set on purpose, because the reporters it serves have no write access, so the issue title and body are fully attacker-controlled input to a model.
- **Existing mitigations:** The tool allow-list is the control that constrains the model: `Read`, `Grep`, `Glob`, `gh issue view`, and `gh issue comment` scoped to the triggering issue number. No `Edit`, `Write`, general `Bash` or git. The job has `contents: read` and `issues: write` only, uses the auto-generated `GITHUB_TOKEN` (expires when the job ends, never a PAT), and checks out without persisting credentials. The only other secret is the model OAuth token. Reads of `/proc` are denied so `Read` cannot reach the runner's environment. The prompt tells the model to treat issue text as data. Epics, bot-filed issues and non-`claude` label events are skipped; runs are serialised, capped at 25 turns and 20 minutes, and every action is pinned to a commit SHA.
- **Likelihood:** Medium that someone tries; Low that it works.
- **Impact:** Low (a wrong or misleading comment on one issue; no code, label or release access).
- **Priority: LOW.**
- **Residual:** No per-author rate limit (concurrency serialises runs but does not cap how many a person can open). The model can still be talked into a misleading comment. Anyone adding a tool to the allow-list, a write permission or another secret to this job widens the blast radius and needs review.

---

## 7. Priority Summary (current state)

Open threats first, then those closed by PR-10..PR-12.

| Threat | Priority | Notes |
|---|---|---|
| T-9 Supply-chain (SwiftPM deps / scripts) | LOW–MEDIUM | Two pinned deps (ZIPFoundation, swift-argument-parser via `Package.resolved`); CODEOWNERS gap — see §9 |
| T-3 HTML XSS in shared report | LOW–MEDIUM | Centralized `escapeHTML`; Swift sink tests still recommended; a report-wide CSP needs a script hash or nonce |
| T-4 XLSX formula injection | LOW–MEDIUM | `OOXMLWriter.sanitizeString` + Patch CSV escaper; Swift malicious-payload tests recommended |
| T-8 Exit-code silent fallback | LOW–MEDIUM | Stale banner + PARTIAL pill close UI surface |
| T-2 Tampered cached JSON | LOW–MEDIUM | Swift verify + writer (2.6, with `require_manifest`) + AuditView surfacing; summaries, SOFA and patch-release-dates not stamped |
| T-1 Secret exfil via shim/upstream | LOW | Every launch site gated by `CLIBridge.codesignGate`: designated requirement + fingerprint with ctime |
| T-5 Symlink/traversal | LOW | Trailing-`/` enforced; PR-8 MigrationBanner verified clean |
| T-6 Background item / schedule store takeover | LOW | Signed-bundle `SMAppService` item; `schedules.json` 0600; T-6b closed |
| T-7 Secret + PII leakage via logs/bundle | LOW | `LogRedactor` at log write and at display/export; `DiagnosticBundleService`/`DiagnosticRedactor` (quoted-JSON secrets, IP keys, IPv4, PII placeholders) |
| T-10 YAML parser abuse | LOW | Minimal hand-rolled `YAMLCodec` (no tags/anchors/constructors) |
| T-14 Codesign TOCTOU and check bypasses | LOW (ACCEPTED) | No `fexecve`; pid-based post-launch check bypassable; no revocation checking |
| T-15 mtime-forged stale banner | LOW | `.meta` sidecar defeats `touch -t` (Epic #103); content-editing attacker residual |
| T-21 State-file forged to suppress a fetch | LOW (accepted) | `state/manifest.json` is unkeyed: detects corruption, not a writer |
| T-11 Manifest absence silent pass | LOW (surfaced, PR-10) | `require_manifest` gate + AuditView card; writer since 2.6 |
| T-12 summary.json outside manifest | LOW | Verify side intact; no producer for `summaries/`, so the `[partial]` log marker stays authoritative |
| T-23 Shared-workspace peer trust | LOW–MEDIUM | Local-or-team-only layout, output deny-list; per-Mac confirmation planned |
| T-24 Dashboard frame | LOW (accepted) | Sandbox without same-origin, CSP; self-navigation not preventable |
| T-25 Custom workspace root | LOW | Owner, mode and ACL checked except under `/Volumes` and CloudStorage |
| T-26 SOFA feed | LOW | TLS only; future dates ignored; `collect_skip: [sofa]` |
| T-27 Issue-triage workflow | LOW | Tool allow-list, job-scoped token, SHA-pinned actions |
| **T-13** Generated Reports no integrity envelope | **CLOSED (PR-12)** | `.xlsx.sha256` sidecar + HTML `report-sha256` meta tag (Swift `writeManifestStatic`) |

---

## 8. Assumptions and Open Questions

Confirmed with user (2026-05-12, refreshed 2026-05-17, re-confirmed 2026-05-20):
- **Single-admin laptop** deployment for current state — re-confirmed 2026-05-20. One trusted user per Mac, no co-resident accounts. Cross-user threats deprioritized.
- Generated report distribution is **unknown / varies** — output-side injection threats (T-3, T-4) kept at LOW–MEDIUM.
- **Public release shipped** as v2.0.0 (2026-05-20). Distribution is a notarized DMG **and** a PKG installer (PKG confirmed in scope — see T-17). The §11 annex applies to the shipped artifacts; T-16 / T-17 are live concerns, not hypothetical.
- Since 2.7.0 a workspace can be shared by several Macs on purpose (T-23). The single-admin assumption holds per Mac; the shared folder's audience is the operator's decision.
- The Developer ID signing certificate is an **individual** Apple Developer enrollment, not an organization. Recipient-Mac background-activity / Login Items prompts therefore show the individual developer's name. T-16 blast radius is one individual certificate on a single signing host.

Material assumptions still in effect:
- `JamfCLIIdentity.expectedTeamID` and `JamfCLIInstaller.expectedJamfTeamID` (`"483DWKW443"`) are the legitimate jamf-cli publisher. If false, T-1 jumps to HIGH.
- `Package.resolved` SwiftPM dependency pins are reviewed in PR and not auto-bumped without review. If false, T-9 jumps to HIGH.
- `automation/logs/` is treated as same-trust as the workspace. Verified by `WorkspacePermissionHardener` sweep; not by a permission-regression test.
- The app never auto-updates its own binary (only `jamf-cli`). If a future auto-update path is added, re-rank T-9 / T-16.
- Reports may be opened by recipients on Windows / non-macOS — relevant for T-4 (Excel-only formula evaluation).
- **(NEW)** PKG installer will NOT request admin authorization (no root scripts). If that changes, model TB-10 explicitly and add T-21 (script-as-root abuse).

---

## 9. Highest-Value Next Actions (current state)

With the report-artifact integrity envelope (T-13) shipped, the standalone
Python engine removed and the Swift snapshot-manifest writer in place (2.6), the
highest-value remaining actions are:

1. **Per-Mac confirmation of shared-config values (T-23).** Pin `allow_absolute_paths`,
   output and archive folders, retention mode and `notify.url` per Mac when a
   workspace is shared, so a peer's edit to `config.yaml` cannot change them silently.
   Planned, not built.
2. **Finish the manifest producers (T-2 / T-12).** `SnapshotManifest.record` stamps
   snapshots saved through `ReportEngine.saveSnapshot` when `require_manifest` is on.
   The `summaries/` directory, the SOFA cache and `patch-release-dates` have no
   producer, so the summary-pill SHA-256 cross-check stays dormant.
3. **Harden the supply-chain trust boundary for a public repo (T-9).** A public
   repo accepts outside PRs. Add branch protection on `main` requiring CODEOWNERS
   review for any change to `Package.swift`, `Package.resolved`, the `app/scripts/`
   release tooling, `.github/workflows/`, and the jamf-cli Team ID constants.
4. **Act on the release-pipeline threats (§11).** T-16 (signing-key compromise)
   and T-18 (downgrade attack) are near-term. Keep the Developer ID certificate off
   CI, store it in a hardware token if possible, and publish a "verify build" doc
   carrying each release artifact's SHA-256 and the signing certificate fingerprint.
5. **Add Swift malicious-payload tests over the XLSX/CSV/HTML sinks (T-3 / T-4).**
   The prior Python sanitization corpus is gone. A report-wide CSP is only worth
   adding with a hash or nonce for the report's own script.

The diagnostic-bundle PII redaction gaps surfaced during release prep are
already closed (see T-7).

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
- [x] **Single-engine refresh (2026-06-18):** standalone Python CLI removed; Python-only threat surface (runtime supply chain, `yaml.safe_load`, Python sanitization corpus, `_safe_write`) dropped; every Swift control kept. The snapshot-manifest writer gap this opened was closed in 2.6; the `summaries/` directory still has no producer (§9 item 2).
- [x] **2.9.0 refresh (2026-10-10):** background item (`SMAppService`) replaces LaunchAgent plists in §1, TB-5, T-6; jamf-cli gate described as a designated requirement plus fingerprint (T-1, T-14); T-3, T-7, T-21 corrected; shared workspaces, dashboard frame, custom root, SOFA and issue triage added as T-23..T-27; TB-8 covers the triage workflow.

---

## 11. External Distribution Annex (post-release, next 6 months)

This annex models threats that arise only when the app is shipped externally to other organizations. The current-state model (§§ 1–10) remains primary; this annex is forward-looking. Threats T-16..T-20 are scoped to the additional capabilities A7..A10 and the additional trust boundaries TB-9..TB-10. They sit here, after T-23..T-27 in numbering, because they are the release-channel annex rather than runtime threats.

### Distribution channels in scope

Per user confirmation (2026-05-17), planned external distribution includes:
- **Notarized DMG** delivered via GitHub Releases. Recipient drags `.app` to `/Applications` (no install scripts). Gatekeeper enforces notarization.
- **PKG installer** delivered via GitHub Releases (and potentially a Homebrew cask). Recipient runs `installer -pkg ... -target /` or double-clicks. Pre/post-install scripts MAY run as root depending on `productbuild` flags.

### T-16. Notarization key / Developer ID certificate compromise
- **Goal:** Ship malicious updates that pass macOS Gatekeeper on every recipient Mac.
- **Path:** A9 exfiltrates the Developer ID certificate (and/or notarization API key) from the build host. Re-signs and re-notarizes a backdoored build. Recipients update via Homebrew or manual download and Gatekeeper raises no warning.
- **Existing mitigations:** Signing, notarization and packaging are scripted in `app/scripts/release.sh` (`sign-release.sh`, `notarize-release.sh`, `package-dmg.sh`; see [`app/scripts/README.md`](../../app/scripts/README.md)) and `app/build-pkg.sh`, and run on the maintainer's Mac. CI (`release.yml`) builds a source zip and holds no signing material. Signing passes `--timestamp`, the notary profile is a keychain profile on the signing host, and a release build (`RELEASE=1`) refuses to fall back to ad-hoc signing. Single-developer signing host.
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
- **Path:** A8 swaps the PKG in transit or A9 ships a malicious one. If the PKG runs pre/post-install scripts as root (default for `productbuild` when scripts directory is provided), those scripts execute with root privileges. A PKG is one of the distribution formats.
- **Existing mitigations:** `app/build-pkg.sh` builds a component package that installs `JamfReports.app` to `/Applications` with no pre- or post-install scripts (`pkgbuild --root`, no `--scripts`), signs it with `productsign --timestamp`, and notarizes and staples it for a release build. A design-time guard, not a runtime one: adding a scripts directory would change this.
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
- **Existing mitigations:** Per-user workspace under `$HOME` by default. Since 2.7.0 an operator can move a workspace to a shared folder on purpose; that case is T-23 and T-25. A networked home directory is still not detected.
- **Likelihood:** Low (requires shared home dir).
- **Impact:** Low–Medium (no credentials cross over — those are in `jamf-cli` keychain — but org-internal naming leaks).
- **Priority: LOW.**
- **Recommended mitigations:**
  - On first launch in a workspace that already has a `config.yaml` written by a different macOS user account, show a warning banner asking the user to confirm intent.
  - Document that workspaces are per-user and should not be placed on networked home directories. Wiki 10 documents the deliberate shared layout.

---

## 12. Annex Quality Check

- [x] §11 covers DMG and PKG paths per user request.
- [x] §11 covers post-release supply-chain (notarization key, downgrade, Homebrew tap).
- [x] §11 explicitly notes T-17 is HIGH **conditional** on PKG design — design-time guidance provided to keep it LOW.
- [x] §11 explicitly distinguishes recipient-side capabilities (A7) from build-host capabilities (A9) so mitigations land on the right actor.
- [x] All §11 threats reference the new trust boundaries (TB-9, TB-10) and new attacker capabilities (A7..A10).
