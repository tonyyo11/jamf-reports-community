# Diagnostics & Troubleshooting

Most likely failure modes, what they mean, and the recovery path. Walk this list before
opening an issue. The app's **Run History** screen streams full `jamf-cli` output for any
run the app itself scheduled or ran — a schedule built in the Automation screen, or a
manual Collect/Generate from the GUI. A run you triggered yourself through the
`jamf-reports` CLI (your own cron/launchd job, or an interactive terminal run) does not
appear there; use `log stream` (below) for those. Copy whichever output applies into an
issue if a failure is not listed here.

## Diagnostic bundle

To share diagnostics safely, build a redacted bundle from the app:
**Settings → Diagnostics → Generate diagnostic bundle now**.

It collects recent logs, the last few `summary.json` snapshots, `config.yaml`, a
workspace tree listing, and version metadata into a zip under the workspace's
`diagnostics/` folder, and reveals it in Finder. Credentials are always redacted; PII
(hostnames, serials, emails, device names) is redacted by default with stable hash
placeholders.

The headless equivalent is `jamf-reports diagnostic-bundle --profile <profile>` (see
[Command Line](https://github.com/tonyyo11/jamf-reports-community/wiki/07-Command-Line)) — same redaction, no GUI required.

## Logging

Every action logs through the unified `os.Logger` under subsystem
`com.github.tonyyo11.jamf-reports-community`, split across eight categories — `cli`,
`collect`, `report`, `auth`, `schedule`, `webhook`, `platform`, `ui` — so you can filter
to the area you care about in Console.app or the in-app viewer.

**Settings → Logging** controls verbosity and shows recent entries:

- **Persist verbose logs** — keeps `debug`/`info` entries in the local log store (off by
  default; the OS otherwise persists only `notice` and above). Interpolated values stay
  redacted as `<private>`.
- **Reveal private values in logs** — writes serials, hostnames, and usernames in full to
  the **local** store on this Mac. Off by default and warned; leave it off on managed or
  government Macs.
- **Log viewer** — a snapshot of this session's entries, filterable by minimum level, time
  window, and free-text search. **Export** writes a redacted copy regardless of the reveal
  toggle.
- **Reveal MDM profile** — reveals the bundled `JamfReports-Debug-Logging.mobileconfig`
  (persist-verbose only; never `Enable-Private-Data`) for org-wide deployment via Jamf.

Toggle changes take effect at the **next launch** — quit and reopen the app. To watch logs
live in Terminal:

```bash
log stream --predicate 'subsystem == "com.github.tonyyo11.jamf-reports-community"' --level debug
```

Or open Console.app and filter on the subsystem.

## Surfaced errors

Operation failures (collect, refresh, generate, backup) and `jamf-cli` exit codes are
translated into a plain-language cause and remediation rather than a raw error string — for
example, a `401` surfaces as "authentication failed (401) — re-authenticate this profile
from Data Sources." Dashboards that read a snapshot which exists but cannot be parsed show a
distinct **error state with a Retry**, separate from the normal "no data collected yet"
empty state.

## Config Doctor

The Health Audit screen runs the **Config Doctor** — checks that surface
misconfiguration and data-quality issues that would otherwise fail silently.

**Alerts.** When `alerts:` is present in `config.yaml`:

- A malformed rule (unknown metric, unknown comparison, or a missing/non-finite/negative
  threshold) shows as an error naming the rule; the rule is dropped from evaluation rather
  than breaking the whole config.
- `alerts.enabled: true` with no usable webhook (`notify.enabled: true` and an `https://`
  `notify.url`) shows a warning — alerts are configured but cannot be delivered.

**Data accuracy.** A family of checks that runs whenever the relevant inputs are present:

- **EA parse health** — flags a custom EA column whose values parse below 90% against its
  configured type, and shows the most common unparseable value shape (letters and digits
  masked, never the real value).
- **CSV/device-count reconciliation** — compares device counts across the CSV export, the
  cached `computers` snapshot, and `ea-results`, and warns when two sources disagree by
  more than 10%.
- **EA coverage drift** — compares each EA's device-coverage percentage between the two
  newest `ea-results` snapshot days and warns when one drops more than 15 points. When
  fewer than two comparable days have been collected, the doctor reports "EA coverage
  drift unavailable" rather than a false "stable" result.

**Workspace and storage.** Where the workspace lives, whether it is reachable and
writable, which layout is in effect (reports published to a shared folder, or the whole
workspace shared), and — on a shared workspace — which other Macs write there, when each
last collected, whether their clocks and app versions agree, and any leftover claim or
sync-conflict file.

**Workspace continuity.** Two suggestions for a workspace that is fine but not the one you
expected:

- **More history for this profile exists in another folder** — naming the folder and how
  many daily summaries are in each. Moving the workspace does not move existing data, so
  everything looks empty because it is; the old history is still there, just not being
  read.
- **Settings here are defaults** — this workspace is new, so column mappings, custom
  extension attributes and thresholds are scaffold defaults rather than anything you set
  previously.

Both are suggestions rather than failures, and both stay quiet once the workspace has
history. Only failures reach a scheduled run's log, so neither can turn a healthy run red.

**Hand-edited values.** Warns for each key the app does not read (with the nearest known
key), each line the reader skipped (by line number), and each value you typed that was
replaced, clamped or ignored, saying what the app uses instead; keys it reads that nothing
uses are suggestions. Security policy values it could not read are named with the level
used. These are warnings, never failures, so a typo cannot turn a healthy scheduled run
red.

The same checks run headlessly as `jamf-reports check` (and `check --json` for a CI gate)
— see [Command Line](https://github.com/tonyyo11/jamf-reports-community/wiki/07-Command-Line).

## Common failure modes

**`jamf-cli: command not found` / "jamf-cli not detected".** The binary is not installed
or not on the GUI app's `PATH` (Apple-silicon Homebrew installs under `/opt/homebrew`,
not always inherited by apps launched from Finder).

```bash
brew install Jamf-Concepts/tap/jamf-cli
which jamf-cli
```

The app falls back to CSV-only / cached-snapshot mode when jamf-cli is absent and shows a
notice.

**`401 Unauthorized` / token expired.** The OAuth token jamf-cli stored has
expired or been revoked. Re-authenticate from **Data Sources → Connection
health → Update credentials…**, or in Terminal:

```bash
jamf-cli pro setup --url https://your-instance.jamfcloud.com
```

For a Jamf Platform API profile, use **Update credentials…**, which also checks
the environment or tenant ID. A Jamf Account integration is valid for six
months; an expired one needs a replacement in Jamf Account first.

**Profile name rejected.** The app uses any name jamf-cli accepts (spaces, dots, accented
letters and punctuation included) except one with a line break or tab, one that starts or ends
with a space, or a very long one. jamf-cli has no rename command, so for an existing jamf-cli
profile with such a name, add the same connection again under another name
(`jamf-cli config add-profile <name>`) and remove the old one. A character a folder name can't
hold appears encoded in the workspace folder's name: `a/b` uses the folder `a%2Fb`. Two
profiles whose names differ only by letter case (`Prod` and `prod`, or `Zürich` and `zürich`)
would share one workspace folder on a
case-insensitive volume, so the app uses only one of them: the one that already has a
workspace, or else the lowercase spelling. The first-launch setup screen and Settings →
Connections show which profile is skipped and why, and choosing it from the profile menu says
so. If a workspace folder belongs to an older spelling of the same server (for example after
re-adding `prod` as `Prod`), set `jamf_cli.profile` in that folder's `config.yaml` to the new
spelling.

**`no space left on device` / workspace size warning.** Scan-tier inventory archives
accumulate. Check usage and lower `output.keep_latest_runs` in `config.yaml`:

```bash
du -sh ~/Jamf-Reports/<profile>/*
```

**The health strip says a data source is failing or behind.** The strip across the top of
every screen reports a source that failed two or more consecutive collects, or whose last
success is past three times its tier cadence. Press **Collect now** to re-collect just the
tiers behind it, and read the run log in Run History for jamf-cli's own message — a
non-zero exit is reported with its cause, not as a bare number. Sources whose last failure
was a usage/credentials error (exit 2) or a policy refusal (exit 8) stay listed but are
never retried automatically, because they fail identically every time. See
[Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust).

**A run says `[partial]`.** The run completed but did not refresh everything: at least one
source served cached data, the run stood down for another Mac on a shared workspace, or
the day's summary could not be written. The line names which.

**"A scheduled run is in progress".** A background run holds the lock the app takes for
every collect it starts. Wait for it to finish, then try again; the app starts nothing
while the lock is held.

**"A refresh is already running".** The app runs one collect at a time, for every profile, so
a second Refresh, Collect now, scan prompt, Generate with fresh data or first collect is turned
away rather than started beside the first, which would double the load on the Jamf server. The
status bar names the collect that is running. Wait for it to finish, then try again; nothing is
queued, and the click leaves no Run History entry.

**"jamf-cli is being updated".** An update of jamf-cli holds the same lock as a collect, so
neither starts while the other runs and the binary never changes under a collect. Updating from
Settings while a refresh or a scheduled run is going says so and changes nothing; update again
when it finishes.

**The top of a run log says what it will collect.** Every run log starts with `[plan]` lines:
the sources it will fetch (`[plan] profile <name> — collecting N sources: …`), the ones it
leaves alone grouped by reason (`jamf_cli.collect_skip`, a Platform API profile required, tier
not selected, not due, and so on), and whether the per-device scan runs. Each skipped source
still has its own `[skip]` line with the detail, such as when it last ran.

**A run in Run History says Running.** A run whose log has no exit line yet and is still being
written shows a RUNNING pill; press Refresh to update it. A run with no exit line that nothing
is writing any more (the Mac slept through it, or the app was quit) shows WARN, as before. Rows
are dated at the run's start.

**"Refresh finished with warnings".** The collect exited 0 but a source did not land. The toast is
amber, not red, and Run History has the `[partial]` line under "Manual collect"; if the run
could not be recorded the toast says Settings → Logging instead.

**"config.yaml changed on disk since this screen loaded it".** The file changed after the
Config screen loaded it, so the save was refused. Reload on the Config screen, then repeat
your edit.

**`[skip]` lines in run output.** A sub-step skipped because the cached data it needed
was stale or absent. Normal in the first day after enabling schedules. If `[skip]` lines
persist, force a collection — in the app, "Run now" on a `jamf-cli-full` schedule.

**Health Audit shows red EAs.** A Custom EA's `column:` value does not match the name
`jamf-cli` returns (renamed in Jamf Pro, trailing whitespace, or deleted). Fix the
`column:` value in the Config screen's Custom EAs tab, or re-scaffold from the Config
screen.

**Data Sources shows zero devices.** Cached JSON exists but the active profile points at
a different `data_dir`, or the profile was switched without a refresh. Confirm the
sidebar profile chip, check `jamf_cli.data_dir` in `config.yaml`, and regenerate.

**Column not found / empty CSV-sourced sheets.** A column name in `config.yaml` does not
match the CSV. Open the Config screen, re-scaffold against your CSV export, and confirm
each mapping resolves to the right header.

**CSV line-ending compatibility.** CSV exports from Windows or Excel sometimes use carriage-return-linefeed
(CRLF, `\r\n`) line endings instead of the Unix standard linefeed (`\n`). The app parses both
formats transparently — you do not need to convert the file. If the app reads your CSV as a single
row with no data, your line endings are likely not being recognized; check the file with `file` or
reopen it in a text editor and save it without line-ending conversion, or use `dos2unix` to clean it
up.

**Notarization warning on first launch.** A local build is ad-hoc signed, not
Developer-ID notarized. Right-click the app in Finder, choose Open, and confirm — macOS
remembers the choice.

## jamf-cli exit codes

`jamf-cli` returns a typed exit code; the app reacts accordingly:

| Code | Meaning | Handling |
|---|---|---|
| 0 | Success | Continue |
| 1 | General error (network, unexpected) | Warn; use cached data |
| 2 | Bad flags / missing args | Caller bug — logged as an error |
| 3 | Unauthorized (HTTP 401) | Hard fail — re-authenticate |
| 4 | Not found (HTTP 404) | Warn; use cached data |
| 5 | Permission denied (HTTP 403) | Warn; use cached data |
| 6 | Rate limited (HTTP 429) | Warn; use cached data |
| 7 | Partial failure (jamf-cli v1.19+) | Some sub-operations failed but the successful subset's JSON is saved, with a warning |
| 8 | Refused by policy (jamf-cli v1.28+) | The command is outside what this profile's API publishes — warn, keep the source visible, never retry automatically |

Only an unauthorized result (3) aborts a run. Everything else falls back to the most
recent cached snapshot.

Exit 8 means the command was correct but this profile cannot serve it: a Jamf Pro or
Classic command on a Platform gateway profile, or a Platform-only command on an instance
profile. The remedy is a different profile, not another attempt, so the automatic
re-collect leaves that source alone. `jamf-cli commands -o json` lists what the binary in
hand refuses.

### App-level exit codes (jamf-reports CLI)

The `jamf-reports` command-line tool also returns its own exit codes:

| Code | Meaning |
|---|---|
| 75 | Queued — a scheduled run or another operation holds the lock; your command was not started. Try again in a few minutes. |

Collection and report generation run under an exclusive lock so they never overlap. If
you run `jamf-reports collect`, `jamf-reports generate` or `jamf-reports schedules run`
while another operation is active (a tick wake, a scheduled run, or a report generation
on the same Mac), your command exits 75 and queues for the next opportunity.

## Report integrity envelope

Generated reports carry a self-attesting fingerprint so a recipient can confirm the file
was not altered after generation.

- **XLSX** — every workbook is written with a `<basename>.xlsx.sha256` sidecar in
  `shasum -a 256` format. Verify with `shasum -a 256 -c <file>.xlsx.sha256`.
- **HTML** — the report embeds a `report-sha256` `<meta>` tag and a visible verification
  footer; the footer documents how to recompute and check the digest.

In the app, the fingerprint appears in the Reports screen's "report ready" notice.

**Cached snapshots.** Separately, when `jamf_cli.require_manifest: true`, each raw
jamf-cli JSON snapshot the app collects gets a sibling SHA-256 `manifest.json` in its kind
folder. Health Audit's snapshot verification reports one of five states per snapshot:
`verified` (hash matches), `mismatch` (hash does not match — the likely-tampered case),
`omitted` (the manifest exists but does not list this file — a partial collect),
`corrupt` (the manifest itself is unparseable), or `absent` (no manifest exists — legacy
snapshots, or the file was collected before `require_manifest` was turned on). A manifest
write failure does not fail the collect — it appears as a `[warn]` line in Run History
naming the affected kind, and that snapshot subsequently verifies as unverified rather
than `verified`.
