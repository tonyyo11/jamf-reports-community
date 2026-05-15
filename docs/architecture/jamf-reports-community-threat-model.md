# Threat Model — jamf-reports-community

Repository: `jamf-reports-community` (Python CLI + native macOS Swift app)
Modeled on: 2026-05-12
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

### Out of scope (referenced, not modeled here)
- The external `jamf-cli` binary (Go, separate repo) — treated as a trusted external dependency once Team-ID code-signature verification passes (`CodeSignVerifier.verify`, `app/Sources/JamfReports/Services/CodeSignVerifier.swift:13`, callers at `OnboardingFlow.swift:234`, `JamfCLIInstaller.swift:541`).
- The bundled python-build-standalone runtime — modeled only as a supply-chain edge (SHA-256 pinned in `app/python-runtime.lock`).
- Jamf Pro / School / Protect servers themselves.

### Components and runtime
| Component | Where | Runtime role |
|---|---|---|
| `JamfReports` (GUI) | `app/Sources/JamfReports/App` | User-facing SwiftUI app; spawns `jamf-cli` |
| `main.swift` (daemon mode) | `app/Sources/JamfReports/App/main.swift` | Triggered by LaunchAgent timers; collects + generates |
| `ReportEngine` (native engine) | `app/Sources/JamfReports/Engine/*` | Reads cached JSON, writes XLSX/HTML/CSV |
| `CLIBridge` | `app/Sources/JamfReports/Services/CLIBridge*.swift` | `Process`-based async wrapper for `jamf-cli`; environment hardening |
| `jamf-reports-community.py` | repo root | Python fallback for Excel/HTML output |
| LaunchAgents | `~/Library/LaunchAgents/com.jamfreports.<profile>-{hot,warm,cold}.plist` | Re-invoke daemon mode at 15 m / 4 h / 24 h |

### Data stores
- `~/Jamf-Reports/<profile>/jamf-cli-data/*.json` — cached snapshots (0600).
- `~/Jamf-Reports/<profile>/Generated Reports/*.{xlsx,html}` — outputs.
- `~/Jamf-Reports/<profile>/snapshots/computers/summaries/*.json` — trend history.
- `~/Jamf-Reports/<profile>/automation/logs/` — per-run stdout/stderr.
- `~/Jamf-Reports/<profile>/config.yaml` — column mapping + `jamf_cli.profile`.
- macOS Keychain (managed by `jamf-cli`, not this app) — long-term Jamf API client secret.

---

## 2. Trust Boundaries

| # | Boundary | Mechanism / controls observed |
|---|---|---|
| TB-1 | User UI ↔ on-disk workspace | `ProfileService.isValid` regex `^[a-z0-9][a-z0-9._-]*$` enforced at every path-construction site; `WorkspacePaths` typed constants; `SystemActions.canonicalize` resolves symlinks then `hasPrefix(root + "/")` check (`SystemActions.swift:46-89`). |
| TB-2 | App ↔ `jamf-cli` subprocess | `CLIBridge.environmentForJamfCLI()` pins minimal env (`PATH`, `HOME`, `LANG`, `TMPDIR`, `HTTP[S]_PROXY` allow-list, `CLIBridge.swift:1316-1330`). Code-signature Team-ID verification before passing secrets (`CodeSignVerifier.verify`). |
| TB-3 | App ↔ Jamf Pro/School/Protect servers (over network) | TLS via `jamf-cli`; `authGuard` probes `pro auth token` before live calls (`CLIBridge.swift:460-498`); School profiles skip probe (API-key auth). |
| TB-4 | App ↔ macOS Keychain | Indirect — only `jamf-cli` reads/writes; secret passed by app via stdin during onboarding (`OnboardingFlow.swift:250-264`) with `resetBytes` zeroing after dispatch. |
| TB-5 | LaunchAgent ↔ app daemon mode | `~/Library/LaunchAgents/*.plist` written atomically by `LaunchAgentWriter`; only user-agents, never LaunchDaemons. |
| TB-6 | Generated HTML report ↔ downstream readers | Centralized escaping via `HtmlSectionFormatters.escapeHTML` (Swift) and `HtmlReport._html_text` (Python `html.escape(..., quote=True)`, `jamf-reports-community.py:12916-12922`). CSS color allow-listed (`_safe_css_color`). |
| TB-7 | Build pipeline ↔ shipped artifacts | `python-runtime.lock` SHA-256 pins; ad-hoc-signed dev builds; Developer-ID signing + notarization is manual (`ARCHITECTURE.md:307-309`). |
| TB-8 | Repo CI workflows ↔ release artifacts | `.github/workflows/{ci,release,report,update-jamf-cli-version}.yml`. |

---

## 3. Assets

| Asset | Why it matters |
|---|---|
| Jamf API client secret (OAuth2) | Most sensitive secret. Lives in macOS Keychain via `jamf-cli`; transits the app only over stdin during onboarding. Compromise → full Jamf Pro tenant read/write per role. |
| Jamf bearer tokens | Cached on disk by `jamf-cli`; short-lived. Compromise → tenant access until expiry. |
| Device inventory + compliance JSON | Whole fleet's hardware IDs, serials, users, OS state, compliance/STIG failures. Sensitive in regulated/government environments. |
| Generated reports (XLSX/HTML) | Inherit sensitivity of inventory data. May be shared off-host (user confirmed "unknown / varies"). |
| `config.yaml` | Reveals org-specific EA names + Jamf URL; pre-onboarding bootstrap values. |
| LaunchAgent plists | If an attacker can write to `~/Library/LaunchAgents` they can persist arbitrary code — but they already have user-level execution if so. |
| Bundled Python runtime | Build-time supply-chain artifact; integrity guarded by SHA-256 pins. |
| App binary itself | Hardened-Runtime, ad-hoc-signed for local builds; release notarization is manual. |

---

## 4. Attacker Capabilities (single-admin laptop assumption)

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

---

## 5. Entry Points

| Entry point | Component | Notes |
|---|---|---|
| GUI invocation (`JamfReports.app`) | App | Trusted; same-user only |
| Daemon-mode invocation by LaunchAgent | `main.swift` | `argv[1] == "--daemon"` style; LaunchAgent plists are app-written |
| `config.yaml` parsing | `YAMLCodec` (Swift) + `yaml.safe_load` (Python, `jamf-reports-community.py:3004`) | Untrusted-ish: user-edited, but could be replaced by A1 |
| Cached JSON parsed by `ReportEngine` / `CoreDashboard` | `app/Sources/JamfReports/Engine/*`, Python classes | Source-of-truth originates from Jamf, but file is replaceable by A1 |
| CSV imports (Jamf Pro export, Jamf School export) | `CSVDashboard`, `_school_csv_load` | Auto-detects delimiter; passed cell-by-cell to `_safe_write` |
| jamf-cli stdout (JSON) | `CLIBridge.runJSON` | Parsed; effectively trusted because we just spawned the verified binary |
| Onboarding stdin (client ID + secret) | `OnboardingFlow.runPTY` | Untrusted user input, passed straight to `jamf-cli` |
| LaunchAgent plist on disk (read-back) | `LaunchAgentService` | Could be attacker-modified by A1 |
| GitHub Actions triggers | `.github/workflows/` | PRs from outside collaborators |

---

## 6. Threats (abuse paths)

For each: **goal → path → assets → likelihood × impact → priority**, with file evidence where applicable. Mitigations split into **existing** vs **recommended**.

### T-1. Malicious shim at `/opt/homebrew/bin/jamf-cli` exfiltrates onboarding secret
- **Goal:** Steal Jamf API client secret during the onboarding flow.
- **Path:** A1 (local same-user malware) drops a `jamf-cli` binary earlier on `PATH` than the real one, or backdoors the Homebrew tap (A4). When the user clicks "Authenticate" the app would normally pipe `clientID + "\n" + secret + "\n"` to stdin (`OnboardingFlow.swift:250`).
- **Assets:** API client secret → full Jamf tenant compromise.
- **Existing mitigations:**
  - `CodeSignVerifier.verify(url: jamfCLIURL, expectedTeamID: JamfCLITeamID)` is called *before* the secret is written to stdin (`OnboardingFlow.swift:234`). Untrusted binaries are rejected with `CLIBridgeError.untrustedJamfCLI`.
  - Stdin buffer is zeroed via `resetBytes(in:)` after dispatch (`OnboardingFlow.swift:250-252`).
  - Pinned env (`environmentForJamfCLI`) prevents `DYLD_INSERT_LIBRARIES`-style hijack.
- **Likelihood:** Low. Two stacked defenses (Team-ID + pinned env).
- **Impact:** Critical (full tenant secret).
- **Priority: MEDIUM** — primarily because the residual risk is upstream tap compromise (A4) producing a binary that *is* signed by the expected Team-ID but otherwise malicious. Codesign defends against shims, not against a compromised official binary.
- **Recommended mitigations:**
  - Document and review the Team-ID embedded in `JamfCLITeamID` for changes in PRs.
  - When `jamf-cli` is auto-updated via `JamfCLIInstaller`, log the post-update signing certificate fingerprint to `automation/logs/` so a silent identity flip is auditable.

### T-2. Tampered cached JSON leads to misleading reports / charts shared with management
- **Goal:** Cause incorrect compliance/inventory data to be reported.
- **Path:** A1 modifies `~/Jamf-Reports/<profile>/jamf-cli-data/*.json` between collect and generate. Generated XLSX/HTML is then shared (user said "unknown/varies").
- **Assets:** Integrity of generated reports → operational/compliance decisions.
- **Existing mitigations:**
  - `WorkspacePermissionHardener.tighten()` sets snapshot files to 0600 and directories to 0700 after every collect, raising the bar for *other* users (but not for the same user, which is the assumed attacker per A1).
  - Generation is idempotent and re-runs against fresh API data via `collect`.
- **Likelihood:** Medium (assumes attacker code is already running as user).
- **Impact:** Medium (no credential loss; downstream decisions distorted).
- **Priority: MEDIUM.**
- **Recommended mitigations:**
  - Record a SHA-256 of each `jamf-cli-data/*.json` immediately after collect, alongside the file; warn at generate time if the digest no longer matches. Cheap, file-local integrity hint.
  - In the HTML/XLSX footer include the collection timestamp + jamf-cli identity fingerprint (already partially done) and a banner if any source file's mtime is newer than the recorded post-collect time.

### T-3. HTML report content-injection via attacker-controlled Jamf fields
- **Goal:** Pop XSS / launch URL handlers when a sysadmin opens a shared HTML report in a browser.
- **Path:** A6 (or a malicious user controlling a device record) injects HTML/JS into a device name, EA value, or policy name. App pulls the value via `jamf-cli` JSON and renders it in the HTML report.
- **Assets:** Recipient's browser session; phishing / drive-by; data leak through `fetch` from an `about:blank`-equivalent file.
- **Existing mitigations:**
  - Swift `HtmlSectionFormatters.escapeHTML` wraps **every** dynamic insertion checked in `HtmlReport.swift` (`:138`, `:348`, `:488-489`, `:598-602`, `:682-684`, etc.).
  - Python `HtmlReport._html_text` uses `html.escape(..., quote=True)` for both text and attribute contexts (`jamf-reports-community.py:12916-12922`); CSS colors validated by `_safe_css_color` regex.
  - HTML output is self-contained — no remote `<script src>` observed in `HtmlReport.swift`.
- **Likelihood:** Low — escaping is centralized and exercised on every documented sink.
- **Impact:** Medium.
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - Add a unit/integration test that injects `<script>` and `"><img onerror>` into every dashboard input field and asserts no raw `<` survives in the rendered HTML for both engines (one fixture, two assertions).
  - Add a meta CSP (`default-src 'self' 'unsafe-inline'`; `script-src 'none'` if no scripts are needed) to the HTML head. Belt-and-suspenders given XSS is the primary downstream-shareable risk.
  - Audit any new `HtmlReport` interpolation site in PR review for the `escapeHTML` wrapper (consider a lint/regex check).

### T-4. CSV/spreadsheet formula injection in generated XLSX
- **Goal:** When a recipient opens the XLSX in Excel, a leading `=`, `+`, `-`, `@`, or `\t` triggers a formula that runs `WEBSERVICE(...)` / `HYPERLINK` / DDE.
- **Path:** A6 / device with attacker-controlled metadata. Python writes through `_safe_write`; Swift engine writes through its own xlsx writer.
- **Existing mitigations:**
  - `_safe_write` is the documented invariant and explicitly lists "formula injection" among the things it sanitizes (CLAUDE.md "Invariants"). All CSV-sourced data must go through it.
- **Likelihood:** Low.
- **Impact:** Medium (recipient compromise; data exfiltration via `WEBSERVICE`).
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - Add explicit tests that a cell value starting with `=SUM(1+1)` / `+1+1` / `@cmd` / `\t=...` is rendered as a literal string in the produced `.xlsx` (parse with `openpyxl` in tests).
  - Mirror the same sanitization assertion in the Swift `OOXMLWriter` equivalent — same fixture, both engines.

### T-5. Symlink/traversal escape in `SystemActions` open/reveal
- **Goal:** Trick the app into opening or revealing an attacker-chosen path outside the workspace.
- **Path:** A1 plants a symlink inside `~/Jamf-Reports/<profile>/Generated Reports/` pointing to e.g. `~/Library/Keychains/login.keychain-db`; user clicks "Reveal in Finder".
- **Existing mitigations:**
  - `SystemActions.canonicalize` resolves symlinks via `URL.resolvingSymlinksInPath()` and then enforces `resolvedPath == root || resolvedPath.hasPrefix(root + "/")` (`SystemActions.swift:46-89`). Trailing-`/` is critical: it prevents `~/Jamf-Reports-evil/` from matching `~/Jamf-Reports` as a prefix.
  - `/tmp` removed from allow-list (`:59-60`) to avoid macOS shared-tmp TOCTOU.
- **Likelihood:** Low.
- **Impact:** Low–Medium (reveal != exfil; mostly a UX-trust violation).
- **Priority: LOW.**
- **Recommended mitigations:**
  - Add a regression test for the exact prefix-without-slash case (`~/Jamf-ReportsX/`).
  - Consider also rejecting paths where any intermediate component is a symlink (currently only the final resolve is checked), to defeat partial-path swaps.

### T-6. LaunchAgent plist takeover persists attacker code as the user
- **Goal:** Persist code that runs at every interval boundary.
- **Path:** A1 overwrites `~/Library/LaunchAgents/com.jamfreports.<profile>-hot.plist` with a `ProgramArguments` pointing to attacker code. On next `launchctl bootstrap` (or login) the attacker's binary runs as the user.
- **Existing mitigations:**
  - App writes plists atomically with `replaceItem(at:withItemAt:)`.
  - Only user-agents, never LaunchDaemons (so no privilege escalation past the current user).
- **Likelihood:** Medium *given* A1 is assumed; without A1 the file is not writable by network attackers.
- **Impact:** Medium (persists user-level access the attacker presumably already had).
- **Priority: LOW.** This is largely the user's macOS / LaunchAgent attack surface, not specific to this app. The relevant defense (FileVault, EDR, login-item review) is OS-level.
- **Recommended mitigations:**
  - On app start, `LaunchAgentService` parses existing plists — make it warn if a `com.jamfreports.*` plist points to a `ProgramArguments[0]` that is not the app's own bundle executable URL. Cheap drift detection.

### T-7. Onboarding secret leakage via process arguments / logs
- **Goal:** Read the client secret from a debug log, crash dump, or process-listing.
- **Path:** A1 or a debugging mistake. Secret could appear in `ps auxww` (if passed as argv) or in `automation/logs/`.
- **Existing mitigations:**
  - Secret is passed via **stdin only**, not argv (`OnboardingFlow.swift:250-264`).
  - Stdin buffer is zeroed after dispatch.
  - PTY path comments explicitly note the secret is streamed and the env is pinned (`OnboardingFlow.swift:504-507`).
- **Likelihood:** Low.
- **Impact:** Critical (if leaked).
- **Priority: LOW.**
- **Recommended mitigations:**
  - Add an automated test that captures all log lines written during onboarding for a fixture client-secret value `"FAKE-SECRET-CANARY"` and asserts the canary appears nowhere in stdout/stderr/log file. This locks the redaction property against future regressions.

### T-8. `jamf-cli` exit-code mishandling causes silent data corruption
- **Goal:** Get the app to silently fall back to stale cached data after an auth or permission change, hiding compliance gaps.
- **Path:** Auth expires (exit 3) or role privilege revoked (exit 5). Per the table in `ARCHITECTURE.md:240-249`, only exit 3 hard-aborts; 4/5/6 warn-and-fall-back-to-cached. If the warning is not surfaced to the user, reports look fine but are days/weeks old.
- **Existing mitigations:**
  - `authGuard` probes the token before each live call (`CLIBridge.swift:460`).
  - Run logs in `automation/logs/` record warnings.
- **Likelihood:** Medium (auth/privilege drift is common in real fleets).
- **Impact:** Low–Medium (decision-quality, not confidentiality).
- **Priority: LOW–MEDIUM.**
- **Recommended mitigations:**
  - In the Runs / Sources screen, render a persistent banner when any tier's last successful live collect is older than 2× its expected interval. This is partly tracked under deferred S5 (CLIBridge exit-code behavioral tests, per memory `review_deferred_items_may2026`); close that gap to lock the behavior.

### T-9. Supply-chain: malicious dependency in Python runtime or PR
- **Goal:** Bundle backdoored code into a release.
- **Path:** A6 introduces a malicious commit to `requirements-runtime.txt` or a dependent package's transitive dep; or the `python-build-standalone` checksum in `python-runtime.lock` is updated to a malicious build.
- **Existing mitigations:**
  - `app/python-runtime.lock` pins SHA-256 of the downloaded runtime archive.
  - `requirements.txt` is small: `xlsxwriter, pandas, pyyaml, matplotlib`.
  - CODEOWNERS file present.
- **Likelihood:** Low (small dependency surface).
- **Impact:** High (signed/notarized release would ship the payload).
- **Priority: MEDIUM.**
- **Recommended mitigations:**
  - Pin Python dependencies to exact versions with hashes (`pip install --require-hashes`) in `requirements.txt` and `requirements-runtime.txt`.
  - Require GitHub branch protection on `main` + signed commits or required reviews from CODEOWNERS for any change to `python-runtime.lock`, `requirements*.txt`, `build-python-runtime.sh`, or `JamfCLITeamID`. (Cheap, high leverage.)
  - Add a CI job that runs `pip-audit` (or equivalent) on `requirements*.txt` per PR.

### T-10. `YAMLCodec` / `yaml.safe_load` parsing of a hostile `config.yaml`
- **Goal:** Code execution or path escape via crafted YAML.
- **Path:** A1 swaps `config.yaml` for a malicious file.
- **Existing mitigations:**
  - Python side uses `yaml.safe_load` (`jamf-reports-community.py:3004`) — no `yaml.load`/`unsafe_load` calls found.
  - Swift `YAMLCodec` is a minimal hand-rolled reader/writer (not a full YAML interpreter) — narrower attack surface, but not separately fuzzed.
- **Likelihood:** Low.
- **Impact:** Low–Medium.
- **Priority: LOW.**
- **Recommended mitigations:**
  - Property-based / fuzz tests against `YAMLCodec` decode for malformed input (unbalanced quotes, deeply nested mappings, control chars in keys). Memory entry already flags `YAMLCodec` as a residual gap.

---

## 7. Priority Summary

| Threat | Priority | Notes |
|---|---|---|
| T-1 Secret exfil via shim/upstream `jamf-cli` | MEDIUM | Codesign defends shims; upstream compromise still possible |
| T-9 Supply-chain (Python runtime / deps) | MEDIUM | Pin hashes; protect lock-file paths via CODEOWNERS rule |
| T-2 Tampered cached JSON in shared reports | MEDIUM | Add per-file digest record |
| T-3 HTML XSS in shared report | LOW–MEDIUM | Add CSP meta + XSS regression test |
| T-4 XLSX formula injection | LOW–MEDIUM | Add formula-injection regression test on both engines |
| T-8 Exit-code silent fallback | LOW–MEDIUM | Close S5 deferred test gap + UI staleness banner |
| T-5 Symlink/traversal in `SystemActions` | LOW | Add intermediate-symlink test |
| T-6 LaunchAgent takeover | LOW | Drift warning on app start |
| T-7 Secret leakage via logs | LOW | Canary-in-logs regression test |
| T-10 YAML parser abuse | LOW | Fuzz `YAMLCodec` |

---

## 8. Assumptions and Open Questions

Confirmed with user (2026-05-12):
- Deployment model is **single-admin laptop** (one Mac admin, no shared host). Cross-user threats deprioritized.
- Generated report distribution is **unknown / varies** — so output-side injection threats (T-3, T-4) cannot be ruled out; they are kept at LOW–MEDIUM rather than LOW.

Material assumptions still in effect:
- The Team-ID compared in `CodeSignVerifier.verify(...)` (the constant `JamfCLITeamID` used at call sites) is the legitimate Team ID of the jamf-cli publisher and is reviewed when changed. If false, T-1 jumps to HIGH.
- `python-runtime.lock` SHA-256 values are reviewed in PR and not auto-bumped by a bot. If false, T-9 jumps to HIGH.
- `automation/logs/` is treated as same-trust as the workspace (user-readable, not world-readable after `WorkspacePermissionHardener` runs). Verified by hardening sweep, but not by a permission-regression test.
- The app never auto-updates its own binary (only `jamf-cli` via Homebrew). If a future auto-update path is added, re-rank T-9.
- Reports may be opened by recipients on Windows / non-macOS — relevant for T-4 (Excel-only formula evaluation behavior).

---

## 9. Highest-Value Next Actions

If only three things are done from this report, do these:

1. **Pin Python dependencies with hashes + CODEOWNERS-gate the lock files** (T-9). Low effort, removes the largest residual supply-chain risk.
2. **Add regression tests for HTML escaping and XLSX formula-injection on both engines** (T-3, T-4). Locks the most error-prone invariant in the codebase against silent regression.
3. **Record per-file SHA-256 of `jamf-cli-data/*.json` at collect time and re-verify at generate time** (T-2). Cheap integrity hint for the case where someone is asked "is this report actually based on what the server returned?"

---

## 10. Quality Check

- [x] All discovered entry points covered (§5 maps each to ≥1 threat).
- [x] Each trust boundary appears in at least one threat (TB-1 → T-5; TB-2 → T-1, T-7; TB-3 → T-8; TB-4 → T-1, T-7; TB-5 → T-6; TB-6 → T-3, T-4; TB-7/TB-8 → T-9; TB-1 → T-2, T-10).
- [x] Runtime vs build/CI separated (T-9 is the only build-time threat).
- [x] User clarifications recorded (§8).
- [x] Assumptions explicit (§8).
- [x] Output matches `references/prompt-template.md` structure (scope → boundaries → assets → attackers → entry points → threats → priorities → assumptions → quality check).
