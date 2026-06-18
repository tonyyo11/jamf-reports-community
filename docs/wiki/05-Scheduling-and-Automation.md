# Scheduling & Automation

Historical reporting is only as good as the cadence behind it. The app schedules unattended
runs through macOS **LaunchAgents** — user-scoped jobs that run as the logged-in user, never
as root.

> **v2.2.0 is moving to "set policy, not cron jobs."** The per-schedule builder below is
> being replaced by an **Automation** screen: one global policy keeps every profile's data
> fresh daily, runs the heavy per-device scans weekly, and generates reports on a single
> cadence across all profiles (adjusting automatically as profiles are added or removed),
> with optional opt-in Teams/Slack webhook digests and grouped consolidated fleet reports.
> The managed model is **off by default** and the underlying LaunchAgent mechanics described
> here are unchanged. This page is updated in full when v2.2.0 ships.

## The Schedules screen

![Scheduled Runs](images/schedules.png)

In the app, the **Schedules** screen manages scheduled runs. Each schedule becomes one
LaunchAgent plist. A schedule has:

- **Name** — a human-readable label.
- **Profile** — which workspace profile to run.
- **Cadence** — daily, weekdays, weekly, or monthly, at a chosen time.
- **Run mode** — what the run does (see below).
- **Collection tiers** — which data the run fetches (see below).

Saving a schedule writes its plist, loads it into `launchd`, and can trigger an immediate
first run. "Run now" executes a schedule on demand.

## Run modes

Each run mode is strict — it does exactly one thing:

| Mode | Behavior | Trends updated |
|---|---|---|
| `snapshot-only` | Collect only (Refresh tier) — refreshes snapshots, no workbook | Yes |
| `jamf-cli-only` | Generate only, from the latest cached snapshots — no collect | No |
| `jamf-cli-full` | Collect + generate, no CSV | Yes |
| `csv-assisted` | Collect + generate, using a CSV from the inbox — **hard-fails if no CSV is present** | Yes |

`csv-assisted` fails loudly when its inbox has no CSV rather than silently degrading to a
no-CSV workbook — use `jamf-cli-full` explicitly if you want the no-CSV path.

## Collection tiers and cadence presets

Collection is split into three tiers by API cost:

- **Refresh** — overview, security, policy-status. Summary endpoints; seconds per run.
- **Inventory** — device lists, profiles, apps, EA coverage. Bulk queries; tens of seconds.
- **Scan** — full device inventory and patch/update failure scans. Per-device
  enumeration; minutes on large fleets.

Each tier has its own cadence. **Settings → Performance** offers three presets:

- **On-prem** — conservative: daily Refresh, weekly Inventory and Scan, pacing between
  calls. Best for memory-constrained self-hosted Jamf Pro.
- **Cloud** — more frequent, no pacing.
- **Custom** — set a tier and cadence per report.

Schedule expensive Scan-tier runs overnight if your account is rate-limited. The app does
not throttle `jamf-cli` — it inherits whatever limits your tenant enforces. Persistent
HTTP 429s in the logs mean you should lower the Scan cadence or stagger profiles.

## LaunchAgent plists

Schedules are written to `~/Library/LaunchAgents/` with labels of the form:

```
com.github.tonyyo11.jamf-reports-community.<profile>.<slug>
```

Multi-profile schedules use `…jamf-reports-community.multi.<slug>`. The app only ever
manages `~/Library/LaunchAgents` — it never installs a system-wide LaunchDaemon or
requests `sudo`. If the Mac is logged out, schedules do not run; `launchd` coalesces
schedule events missed during sleep into one run on wake.

Inspect a schedule from Terminal:

```bash
# List loaded JamfReports agents
launchctl list | grep com.github.tonyyo11.jamf-reports-community

# Print one schedule's launchd state
launchctl print "gui/$(id -u)/com.github.tonyyo11.jamf-reports-community.prod.daily"

# Force an immediate run
launchctl kickstart -k "gui/$(id -u)/com.github.tonyyo11.jamf-reports-community.prod.daily"
```

A schedule that loads but never fires usually has a malformed `StartCalendarInterval` —
`launchctl print` shows warnings near the end of its output.

## Logs

A scheduled run logs in two places:

- **launchd stdout/stderr** at `~/Library/Logs/JamfReports/<label>/` — size-rotated at
  ~5 MiB, four generations kept.
- **Per-run logs** at `~/Jamf-Reports/<profile>/automation/logs/<timestamp>.log` — one
  file per run, read by the **Run History** screen. These are not auto-pruned; clear them
  manually if a high-frequency schedule grows the directory.
