# Monocle review follow-up plan (2026-10-10)

Source: Dan K. Snelson's Monocle report on main @ 8ec34f33 (2026-10-09, score 70/100, 6 Low,
3 Info, 11 non-security). Each item below was verified against the code by a review agent
before it was assigned FIX / DOCUMENT / ACCEPT. Prior coverage: the 2.9.0 security review
(2026-10-05, 3 MUST-FIX fixed, 17 deferrals in epic #207 §K) and the threat model.

Branch: `monocle-review`. Work is split into PRs so each can be reviewed on its own.

## Summary

Monocle's findings hold up: of 9 security items, 7 are confirmed or partly confirmed in
code, 2 are confirmed-but-documented (S7, S8). All 11 non-security footguns are confirmed,
two narrower than stated (retention mtime only bites `snapshot_keep_count`; the tick-lock race
is cross-process, not launchd-vs-launchd). Three Monocle "fix" proposals are rejected on
analysis: R1's bare flock (no give-up step, breaks takeover; #207 K1's design is right), R5's
pid check (fork-and-exec bypass), and moving shared keys out of config.yaml (breaks the
documented every-Mac-agrees contract; pin locally instead). Two things Monocle did not find
matter more: two 2.9.0 specs in docs/superpowers carry production fleet figures and the
vendor stack (Section C), and a latent notary-profile variable mismatch in `release.sh`
(Section G).

### PR split (in order)

| # | PR | Contents | Size | Needs the maintainer first |
|---|---|---|---|---|
| 1 | `docs: scrub superpowers specs, add status index` | Section C scrub (4 files) + `docs/superpowers/README.md` | S | option (b) vs (d) |
| 2 | `docs: track jamf-cli 1.33.0` | Section A | S | no |
| 3 | `fix(security): redaction and jamf-cli trust chain` | F: S2 (patterns, chain, IP keys, boundaries), S3 ctime + gate placement, installer redirect host, `TokenStatus.raw`, R4 line buffer, `ProfileAuthMethod`/discovery via `JamfCLIProbe`, main-actor hop, version compare | S×9 | no |
| 4 | `fix(workspace): config trust, locks, notifications` | D: S5 root check, S8 redact in `record()` + tip, R3 webhook, retention by stamp, `volumeIsLocal` sync detection, lock `.writeFailed` exit 1, deny-list `/Users/Shared` + `~/Public` (output only) | S×7 | no |
| 5 | `fix(inputs): SOFA future dates; ci: triage workflow; release scripts` | G: S9, S6 (`persist-credentials`, scoped comment tool, deny `/proc`), notary var, `--timestamp`, RELEASE=1 ad-hoc guard, PDFExporter comment | S×6 | no |
| 6 | `docs: threat model 2.9.0 refresh + architecture docs` | B + G threat-model edits by one agent; JAMF_CLI_FIRST, clibridge ADR, period-report status, tiered ADR → archive, ARCHITECTURE.md delete, THIRD_PARTY_NOTICES (both copies), app/README, copilot-instructions, docs/README, wiki 10 corrections (S1 vector, S7 rationale, S8 "always redacted", bundle "snapshots") | M | ARCHITECTURE.md delete; tiered ADR archive |
| 7 | `fix: epic sweep (#207, #226)` | Section E's 18 S-sized items + ticks + closures | M | the 4 closure candidates |
| 8 | M-sized design items, one PR each | S1 local pin; S7 per-profile digest; R6 timeouts + PTY prompt wait; K1 flock per #207 K1 | M×4 | S1 approach; K1 go-ahead; K6 umask |

Verification per code PR: `swift build --build-tests` on the host, filtered `swift test` for the
touched suites, and the CI-parity Tart VM for isolation-sensitive changes (PR 3's main-actor hop,
PR 4's lock). Run `/ponytail:ponytail-review` on PRs 3-5 before pushing (hunts over-engineering
in the fixes), and `/monocle` once on main after PR 6 merges to re-score.

### Decisions needed

1. Superpowers folder: status index (b, recommended) or delete landed files (d).
2. S1: local pin of shared-sensitive values (M) vs document-only. Recommended: pin.
3. K6 / umask: tighten reports outside the workspace to 0600 (may break SMB publish folders)?
   Blocks the umask half of S5.
4. K1: go ahead with the flock redesign under the three constraints (heartbeat limit closes
   the fd, never unlink, pid stays in the file)?
5. Delete ARCHITECTURE.md; archive tiered-collection-adr.md.
6. E226: raise the jamf-cli floor to 1.29 (unblocks `--no-verify` and gate removal)?
7. Close E3, E226-2, AI, K13 (after one assertion).
8. Model-providers spec: mark non-binding only, or open an epic item.

## Section A — jamf-cli 1.33.0 (agent: jamf-cli-review) — DONE, no code change

Upstream v1.33.0 (2026-10-09). Nothing the app runs changed: bulk/write commands,
`pro setup --scope standard` narrowing, blueprint import rework, MCP, verbose HTTP output
and the Platform SDK 1.3.0 bump. PRs #406/#408 shipped in 1.32.0; no stderr string the
app matches changed. Gates (1.29 spec names, 1.31 dashboard) unchanged.

Edits (PR "docs: track jamf-cli 1.33.0"):
- `.jamf-cli-tracked-version` → v1.33.0
- CLAUDE.md + AGENTS.md: v1.33.0 paragraph after the v1.32.0 one; add the 1.32.0 facts the
  note missed (120 s header timeout, `--all` halves page size on timeout, no retry on timeout)
- CHANGELOG Unreleased: Dependencies line
- Optional wiki 13: a `standard` role created before 1.33 keeps its old privileges until re-run

## Section B — non-wiki docs (agent: docs-architecture)

| File | Verdict | Action |
|---|---|---|
| docs/architecture/jamf-reports-community-threat-model.md | STALE structurally (refresh header 2026-06-18) | UPDATE: LaunchAgent plists → SMAppService ticker (TB-5, T-6, lines 20/32/37/79/120/127/444); drop `collect_cadence`; `isTrustedJamfCLIExecutable` does not exist → `CodeSignVerifier` designated requirement + `JamfCLIIdentity`; ARCHITECTURE.md:307 citations → app/scripts/README.md; line 292 "single dependency" → two; T-2/T-11/T-12/§9 manifest writer "partially closed in 2.6"; add security-content changes from Section C; cross-link wiki 10; refresh header to 2.9.0 |
| .github/copilot-instructions.md | STALE, misleading to tools | UPDATE: profile-slug regex (2.8.3 ProfileName rule), LaunchAgent lines → ScheduleStore/TickScheduler/TickerRegistrar, three entry points + CLI; or replace with a pointer to AGENTS.md |
| app/README.md | STALE ("shipped in v2.0.0", LaunchAgents, planned atomic writes, dead design-handoff ref, stale layout tree) | UPDATE: shrink to build/run/distribute + pointer to CLAUDE.md |
| docs/architecture/JAMF_CLI_FIRST.md | STALE (LaunchAgents, cache path, log path, PATH claim) | UPDATE lines 34/51/63/75/76/81-83/94 |
| docs/architecture/tiered-collection-adr.md | Most of the Decision never shipped or retired (presets, collect_cadence, pacing, TieredLaunchAgentWriter); cites a private local script | MOVE to docs/architecture/archive/ with a "what shipped" header |
| docs/architecture/period-report-design.md | Says "not implemented"; shipped 2.7.0 and matches code | UPDATE status line; drop "two source documents" ref; verify the @AppStorage persistence claim |
| docs/architecture/clibridge-error-typing-adr.md | STALE in Implementation notes (9 cases → 15; exit codes 7/8/-2) | UPDATE small |
| ARCHITECTURE.md (root) | 13-line pointer still says "Python CLI"; only the threat model cites it | DELETE after fixing the threat-model citations |
| THIRD_PARTY_NOTICES.md + Resources mirror | Missing swift-argument-parser (Apache-2.0) and IBM Plex Mono (SIL OFL 1.1, must ship with the fonts) | UPDATE both copies together |
| app/scripts/README.md | Mostly current; 2.1.0 examples; no build-pkg.sh mention; orphaned | UPDATE minor; link from docs/README.md |
| docs/README.md | CURRENT, thin | UPDATE: list the five architecture files, mention superpowers/, link scripts README |
| docs/testing.md, Fixtures/README.md, BACKLOG.md, NOTICE.md | CURRENT | KEEP (scrub checklist duplicated in two places; consider one copy) |

No org-specific content found in any scoped file.

## Section C — docs/superpowers (agent: docs-superpowers)

All 16 files are tracked; nothing in the repo links to the folder (two test comments cite a
spec and a plan by path). Recommendation (b): add `docs/superpowers/README.md` as a status
index (landed in which release / partly landed / not landed / superseded) with a header saying
these are point-in-time records and CLAUDE.md, CHANGELOG and the wiki are the authority. Leave
the files in place. Reasons: stale "Status:" lines are the misreading risk; deleting loses the
unbuilt halves and rejected alternatives; archiving breaks the two test-comment paths.

**Scrub before they stay public (content edits, do first):**
- `specs/2026-10-05-security-score-factors-design.md` lines 11-30: production fleet size with
  per-control counts, the named EDR/monitoring vendor stack, "beta 1592".
- `specs/2026-10-05-stale-basis-and-contact-gap-design.md` lines 17-30, 142: production
  counts, an internal KB article ID, the owner's workspace setting.
- `specs/2026-09-11-jamf-cli-1.29.0-compat-design.md` line 5, 152: a personal local path and a beta build number.
- `plans/2026-10-01-epic-decisions-and-cleanup.md` and `plans/2026-10-01-epics-207-226-mechanical-items.md`:
  references to `.superpowers/sdd/` files and `~/.claude/rules/shell.md`, neither in the repo.

**Index must say:**
- Connection-access spec (2026-09-12): §8-§17 (reachability record, access card, region picker,
  `jamf-reports permissions`) NOT built; "spec 2" never written; no epic tracks it. The plan lists
  7 deliberate deviations the spec does not mention.
- Model providers + App Intents spec (2026-10-04): NOT built; contradicts wiki 03b (on-device
  only) and the 2.9 removal of `ai.external`. Mark non-binding; decide whether an epic item belongs.
- Ticker spec says target 2.9.0; shipped 2.8.0. Run-now marker and tick state moved to
  Application Support (plan records it, spec does not).
- Security-policy spec §5 / plan `score_weights` task superseded by the score-factors spec.
- DDM spec: exit 3 now refreshes the token and retries once; the 7-day pending rule is `>=`.
- Stale "Status: awaiting review / uncommitted" lines on five files.

Decision for the maintainer: (b) index as recommended, or (d) delete the landed ones. Default (b).

## Section D — Monocle cluster: shared workspace, config trust, notifications, locks (agent: sec-workspace)

Prior coverage checked: #207 §K holds only K1 (tick lock), K2 (digest sent twice), K6 (0644
reports outside the workspace). #226 none. Threat model predates shared workspaces (2.7.0) and
the ticker (2.8.0): T-20's "no shared-disk path" mitigation is out of date.

| Item | Verdict | Decision | Size |
|---|---|---|---|
| S1 shared config.yaml steers output/retention/webhook | PARTLY (deny-list gap confirmed: `/Users/Shared`, `~/Public` not denied; impact documented on wiki 10 but the redirect vector is not) | FIX: local pin of shared-sensitive values + output-only deny-list extension. DOC: new threat T-23, wiki 10 "Configuration Integrity" | M + S |
| S5 custom root not checked for owner/group-write/ACL; no umask | CONFIRMED (`WorkspaceRootStore.validate` checks sensitive/exists/dir/writable only; hardener sets mode, never strips ACLs) | FIX: `.notOwned` / `.groupOrWorldWritable` / `.hasACL` cases, skipped under `/Volumes` and CloudStorage; Doctor row, no silent fallback. umask: decide #207 K6 first | S |
| S7 headless digest names other profiles | CONFIRMED headless only (GUI path is per-profile); wiki rationale stale since 2.8.0 | FIX: route each profile's issues to its own webhook, multi-profile issues to each; update wiki 10 | S-M |
| S8 raw run logs; keychain tip | CONFIRMED, by design (T-7). Wiki 10 lines 264-265 wrongly say logs are "always redacted" while recommending a raw SIEM tail | FIX: `LogRedactor.redact` in `ScheduledRunRecorder.record()` (credential patterns only, markers untouched); reword tip; fix wiki 10 + T-7 | S |
| R3 webhook returns true on URL parse failure | CONFIRMED, narrow (`URL(string:)` only nils on a space in host, `[bad`, DEL) | FIX as R3, `.error` log, return false | S |
| Retention orders by mtime | PARTLY (age rule fails safe; `snapshot_keep_count` can drop newer local files after a provider restamp) | FIX: rank and age by `CloudStorage.snapshotTimestamp`, summary date from the filename | S |
| Path-only sync detection | PARTLY (`/Users/Shared` example wrong; real for NFS/autofs outside `/Volumes`, `~/Nextcloud`) | FIX: `volumeIsLocal == false` and `shared_workspace.enabled` reach `BackupMaintenance` | S |
| Unwritable lock file reads as held, exit 75 | CONFIRMED (`acquire` collapses `.writeFailed` into "held") | FIX: report write failure, record via `TickFailureLog`, exit 1 | S |
| R1 tick lock check-then-write | PARTLY: not launchd-vs-launchd (single instance), real across `spawnNow`/GUI/`--scheduled-run`/CLI; sub-ms window. Sleep takeover (K1) is the practical failure | FIX under #207 K1, not Monocle's snippet: flock, heartbeat limit closes the fd (give-up), never unlink, pid stays in file for the read-only probe | M |

Design notes to carry into implementation:
- Do NOT move `allow_absolute_paths` / retention / `notify.url` out of config.yaml (documented
  contract: every Mac sharing the folder must agree; Keychain would mean re-entry per Mac).
  Pin per Mac in AppSupport (0600) only when `SharedWorkspace` is effective; on drift, headless
  runs use the safe value (workspace output, archive mode, no send) and log `[warn]`; GUI and
  Doctor offer Confirm.
- Deny `/Users/Shared` and `~/Public` only for `workspaceRoot == false`; `refusingSensitive`
  silently falls back for a root, which would orphan an existing root there.

## Section E — Epics #207 and #226 (agent: epic-triage)

Only #207 and #226 are open on the repo; no community issues. Verified by rg / `git log -S`.

**Tick with no code change (already done):** J15, J17, G2, G3, G4, G8, G10, G12, G13, E226-5
(mobile fetch retired). **Close candidates (maintainer):** E3 (catch-up, invalid since
`TickScheduler.due`), E226-2 (empty SOFA feed warns by design), AI (OS-current insight line is
model behaviour), K13 after one assertion that `/tmp` resolves to the denied `/private`.

**S-sized, purely internal, bundle into one "epic sweep" PR** (keep clear of the files the
Monocle fixers touch): J7 (drop `authGuard` from `exportInventoryCSV`), J8 (cache hint on
Generate's thrown collect), J9 (warn once per run on refused `output_dir`), J11
(`JRC_WORKSPACES_ROOT` before the XCTest branch), J13 (`YAMLCodec.parseMapping` complexity),
J14 (redundant `round1`), J16 (two long test lines), K9 (warn at the 10,000-row CSV cap), K10
(force unwrap in `SchoolDashboard.loadSchoolJSON`), K11 (`generateRefusal` for the period
report), K12 (`'` trimmed after the 31-unit cut), K13 (assertion), K14 (DEBUG+XCTest guard on
`defaultSOFARefresh`), G7 (stale `SchoolColumnMapper` comment), G11 (blueprint counts as dash,
not 0), G18 (blank not 0 for missing Compliance Devices/Rules counts), G27 (demo paths read the
real home), E226-6 (supervision pill shows "Unsupervised" for nil).

**Overlap with Monocle (fix in the Monocle PRs, not the sweep):** K1 tick lock (Section D),
K7 unbounded spawns in `ProfileAuthMethod.configList` and `ProfileService.discoverJamfCLIProfiles`
(Section F), K15 bundle config.yaml free text (Section F), K17 dashboard CSP manual check
(Section G), K5 `branding.logo_path` reads any PNG path and K6 0644 reports outside the
workspace (Section D's shared-config trust; both need a decision), K8 config.yaml size cap only
in `ConfigLoader.load` (one shared capped reader, M).

**Need a decision from the maintainer (not in the sweep):** A3 donut filter rollout (L, UI); J2
compliance-band trend plots the wrong measure (M); K2 digest sent twice (M); K3 Teams FactSet
markdown (needs a real channel); K4 `DeviceRecordMerger` O(n²) cap (M); K16 config re-read
after merge save (M); F2 period-report deferrals (product scope); F3b Customize round-trip
Doctor check (M); G5 `osCurrentPercent` denominator vs doc; G6 Device Lookup refresh runs a
full forced collect including the device scan (M, collect-affecting); G34 CI leg; the three
manual checks (add-profile on macOS 27, tick under CloudStorage with the app quit,
Acknowledgements on another Mac); E226-1/E226-3 floor raise to 1.29 (unblocks `--no-verify`
and gate removal); E226-4 catalog-driven exit-8 filter (design).

## Section G — Monocle cluster: output, external inputs, CI, release tooling, threat model (agent: sec-output-ci)

| Item | Verdict | Decision | Size |
|---|---|---|---|
| S4 dashboard frame can navigate itself | CONFIRMED, Low. HTML spec: a frame may always navigate itself; no sandbox token or CSP directive (`navigate-to` never shipped) stops it. Payload is aggregates + admin-set names. Dropping `allow-scripts` loses height sync, theme sync, collapse and filters; rings/cards survive (CSS) | DOCUMENT as a new threat entry (accepted residual); close #207 K17 by checking upstream `dashboard_html.go` uses `html/template`. FIX (drop `allow-scripts`, static theme) only if it does not | S doc / S fix |
| S9 SOFA future dates | PARTLY: only when EVERY release of a major is future-dated; `isXProtectCurrent` IS fooled by one future date | FIX: ignore releases after `now + 1 day`, nil when none left; no grace for a future XProtect date; 2 tests in `SOFAScoreFeedTests` | S |
| S6 issue-triage workflow | CONFIRMED on all three lines; every action across the 3 workflows is SHA-pinned. Unverified extra: whether `Read` can reach `/proc/self/environ` and so `CLAUDE_CODE_OAUTH_TOKEN` | FIX: `persist-credentials: false`; comment tool `Bash(gh issue comment ${{ github.event.issue.number }}:*)`; deny `Read(/proc/**)`. ACCEPT no per-author limit (concurrency serialises) | S |
| PDFExporter isolation comment | CONFIRMED: comment says `data:` allowed and no subresource loads; delegate allows only `about:`/empty and subresources are not filtered. Not exploitable today (JS off, every insertion escaped) | DOCUMENT: reword lines 126-131 and 140-143. Optional `WKContentRuleList` (~20 lines) if the claim should become true | S |
| Notary variable mismatch | CONFIRMED, latent, fails loudly: `release.sh` exports `NOTARY_KEYCHAIN_PROFILE`, `package-dmg.sh` reads `NOTARY_PROFILE` (works only because the profile is named `JamfReports-Notary`) | FIX: one line in `release.sh` | S |
| `sign-release.sh` no `--timestamp` | CONFIRMED, no effect today (2.9.0 carries a secure timestamp by default policy) | FIX: pass `--timestamp` on all three calls so a timestamp-server outage fails at signing | S |
| Ad-hoc signing fallback | CONFIRMED but cannot ship through `release.sh` (re-signs; pkg notarization would reject) | CONSIDER: exit when `RELEASE=1` and identity is `-` | S |
| Threat model | IDs T-11/T-14 exist as Monocle says; content stale since 2026-06-18 (pre-2.3 → 2.9) | DOCUMENT: 2.9.0 refresh. New entries: S1 shared-config trust, S4 frame, S5 root permissions, S6 triage workflow under TB-8, S9 SOFA as external input. Extend T-1/T-14 with in-place overwrite / ctime. Correct: T-1 fingerprint has inode (no ctime) and names `JamfCLIInstaller.expectedJamfTeamID`; T-2/T-11 manifest writer exists since 2.6; §1/TB-5/T-6 LaunchAgents → SMAppService; §7 "single dep" → two; T-3's suggested `script-src 'none'` would now break the report's own script; TB-2 line refs | M |

The threat-model refresh is one doc PR that merges Section B's structural edits with these
security-content edits, done by one agent so the numbering (T-16..T-20 after T-22) is fixed once.

## Section F — Monocle cluster: jamf-cli trust chain, child processes, redaction (agent: sec-clichain)

Neither epic tracks any of these (G22-G24 are different, fixed items). Regex claims were
re-run with NSRegularExpression, the engine the app uses.

| Item | Verdict | Decision | Size |
|---|---|---|---|
| S2 bundle redaction | CONFIRMED. `"client_secret": "…"` passes DiagnosticRedactor unchanged; `collectLogs` runs one redactor; R2 alone still leaves `"token"`/`"private_key"` (neither redactor has a quoted-key token pattern). `lastIpAddress`, `lastReportedIp(V4)` not in `piiJSONKeys`. Wiki 10 and README say the bundle packages snapshots; `stageFiles` does not | FIX: `["']?` after the key in the five patterns; chain `LogRedactor.redact` in `collectLogs`; add the three IP keys; seed only `general.name` from `computers`, never a bare `name` key; optional IPv4 rule. Fix the wiki 10 / README "snapshots" line | S |
| S3 fingerprint lacks ctime | CONFIRMED (in-place write + `utimes` keeps inode/size/mtime; ctime cannot be set from userland). Needs `stat()`; `attributesOfItem` has no ctime | FIX: add `ctime` to `Fingerprint`; test an in-place write + `utimes` invalidates the cache | S |
| S3 onboarding gate placement | CONFIRMED, window wider than T-14's "microseconds": gate at :510, then a 60 s version probe, PTY setup, `run()` at :1445 on the unresolved path | FIX: move the gate into `runWithPTY` directly before `process.run()`, both auth paths; correct T-14 | S |
| S3 R5 pid-based SecCode check | Sound against pid reuse, but bypassable: a swapped binary forks a helper that keeps the PTY fd and execs the real jamf-cli | ACCEPT under T-14; record the bypass in the threat model | — |
| Installer redirect comment | CONFIRMED: host validated pre-download only; SHA-256 + Team ID are the real controls | FIX: check `response.url?.host` against `trustedAssetHosts` after download | S |
| No `kSecCSEnforceRevocationChecks` | CONFIRMED | ACCEPT: fails outright without OCSP reach (air-gapped on-prem); note in T-1 | — |
| Unkeyed state manifest | CONFIRMED; T-21 overstates it ("a forged `.last` fails verification") | DOCUMENT in T-21: corruption, not tampering | — |
| Bearer token in `TokenStatus.raw` | CONFIRMED, held long-term in `WorkspaceStore.authStatus`, no production reader | FIX: delete the field | S |
| R4 UTF-8 decode per chunk | CONFIRMED at CLIBridge :272/:284/:459; `StderrSignalWatcher` misses a marker split across reads (low likelihood: Go writes a line per call). `CollectHonestyWatcher` unaffected | FIX: per-pipe byte buffer, emit complete lines, flush at EOF | S |
| Pipe drain: bundle doctor | PARTLY: a 15 s watchdog bounds it (the 2.9.0 review's "no timeout" note is stale) | FIX with the next item | S |
| Pipe drain: `ProfileAuthMethod.configList` | CONFIRMED (stderr never read, no timeout; #207 K7) | FIX: route through `JamfCLIProbe.run` (drains both, 60 s); same for `ProfileService.discoverJamfCLIProfiles` | S |
| Blind PTY credential writes, no timeout | CONFIRMED | FIX: wait for each prompt with a deadline before writing; `TimedProcessBox` bound | M |
| `checkForUpdate` blocks the main actor | CONFIRMED (two 60 s probes + `brew --prefix` inline) | FIX: `await Task.detached { Self.currentInstallation() }.value` | S |
| Pre-release version compare | CONFIRMED, low impact (an installed rc is never offered the final) | FIX: cut at `-`/`+`, rank pre-release lower on a tie | S |
| Seeded-literal over-redaction | CONFIRMED ("Main" → "org-xxxxtenance") | FIX: `(?<![A-Za-z0-9])(?:…)(?![A-Za-z0-9])` | S |
| No timeouts on brew/tar/unzip | CONFIRMED; a hung `brew update` holds the tool-update lock for up to 6 h, refusing every collect | FIX (R6): `runProcess` via `TimedProcessBox`, 300 s brew, 60 s tar/unzip | M |
