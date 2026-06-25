# Diagnostics & Troubleshooting

Most likely failure modes, what they mean, and the recovery path. Walk this list before
opening an issue. The app's **Run History** screen streams full `jamf-cli` output for any
run — copy that into an issue if a failure is not listed here.

## Diagnostic bundle

To share diagnostics safely, build a redacted bundle from the app:
**Settings → Diagnostics → Generate diagnostic bundle now**.

It collects recent logs, the last few `summary.json` snapshots, `config.yaml`, a
workspace tree listing, and version metadata into a zip under the workspace's
`diagnostics/` folder, and reveals it in Finder. Credentials are always redacted; PII
(hostnames, serials, emails, device names) is redacted by default with stable hash
placeholders.

## Logging

Every action logs through the unified `os.Logger` under subsystem
`com.github.tonyyo11.jamf-reports-community`, split across eight categories — `cli`,
`collect`, `report`, `auth`, `schedule`, `webhook`, `platform`, `ui` — so you can filter
to the area you care about in Console.app or the in-app viewer.

**Settings → Diagnostics → Logging** controls verbosity and shows recent entries:

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

**`401 Unauthorized` / token expired.** The OAuth token jamf-cli stored has expired or
been revoked. Re-authenticate:

```bash
jamf-cli pro setup --url https://your-instance.jamfcloud.com
```

**Profile slug rejected.** A profile name must match `^[a-z0-9][a-z0-9._-]*$` — no
spaces, capitals, or leading punctuation. Use a name like `prod` or `tenant-east`.

**`no space left on device` / workspace size warning.** Scan-tier inventory archives
accumulate. Check usage and lower `output.keep_latest_runs` in `config.yaml`:

```bash
du -sh ~/Jamf-Reports/<profile>/*
```

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

Only an unauthorized result (3) aborts a run. Everything else falls back to the most
recent cached snapshot.

## Report integrity envelope

Generated reports carry a self-attesting fingerprint so a recipient can confirm the file
was not altered after generation.

- **XLSX** — every workbook is written with a `<basename>.xlsx.sha256` sidecar in
  `shasum -a 256` format. Verify with `shasum -a 256 -c <file>.xlsx.sha256`.
- **HTML** — the report embeds a `report-sha256` `<meta>` tag and a visible verification
  footer; the footer documents how to recompute and check the digest.

In the app, the fingerprint appears in the Reports screen's "report ready" notice.
