# Background Refresh

JamfReports keeps its cached jamf-cli data fresh via per-schedule LaunchAgents that
run as the logged-in user — never as root. You create schedules from the Schedules
tab; each schedule becomes one LaunchAgent plist that fires on your chosen cadence.

## What this is NOT

These are not LaunchDaemons. The app does not request `sudo` and does not install
anything outside `~/Library/LaunchAgents`. There is no system-wide service. If your
Mac is logged out, schedules do not run.

## Schedules

Each schedule is one `~/Library/LaunchAgents/<label>.plist` that invokes the JamfReports
app with `--scheduled-run`. You control:

- **Name** — a human-readable identifier (e.g., "Daily Refresh")
- **Profile** — which jamf-cli profile to use
- **Cadence** — when to run (daily at 7 AM, weekly on Mondays, etc.)
- **RunMode** — what the schedule should do: `snapshot-only` (Refresh tier only),
  `jamf-cli-only` (generate from cache, no fresh data), `jamf-cli-full` (collect all
  tiers + generate), or `csv-assisted` (collect + generate with a CSV)
- **Collection tiers** — which data to fetch: Refresh (overview / security / policy-status),
  Inventory (lists / profiles / apps / EA coverage), or Scan (full device inventory /
  patch failures / update failures). Defaults to all three for `jamf-cli-full`/`csv-assisted`.

Plist labels follow the pattern `com.github.tonyyo11.jamf-reports-community.<profile>.<slug>`
for single-profile schedules. Multi-profile schedules use `com.github.tonyyo11.jamf-reports-community.multi.<slug>`.

The schedule writes its plist when you save it from the form, loads it into launchd,
and optionally triggers an immediate first run.

## Where logs live

A scheduled run logs in two places:

- **launchd stdout/stderr** — `~/Library/Logs/JamfReports/<label>/stdout.log`
  and `stderr.log`. The plist points launchd's `StandardOutPath` /
  `StandardErrorPath` here. The app size-rotates these (`LaunchAgentLogRotator`):
  when a file passes 5 MiB it shifts `stdout.log` → `stdout.log.1` → `.2` → `.3`
  and drops the oldest, so at most four generations (~20 MiB) per stream survive.
- **Per-run logs** — `~/Jamf-Reports/<profile>/automation/logs/<timestamp>.log`,
  one file per invocation holding the full streamed output (jamf-cli snapshots,
  app-level operations, final status). This is the set the Runs tab reads via
  `RunHistoryService` and lists newest-first. The app does not age- or
  count-prune this directory — clear it manually if a high-frequency schedule
  makes it grow large.

## Inspecting a schedule

```bash
# List loaded JamfReports agents for the current user
launchctl list | grep com.github.tonyyo11.jamf-reports-community

# Print the plist for a specific schedule (inspect label first)
launchctl list | grep jamf-reports
# Example output: 0  -  com.github.tonyyo11.jamf-reports-community.prod.daily

launchctl print "gui/$(id -u)/com.github.tonyyo11.jamf-reports-community.prod.daily"

# Tail the most recent run log
ls -t ~/Jamf-Reports/prod/automation/logs/*.log | head -1 | xargs tail -f

# Force an immediate run
launchctl kickstart -k "gui/$(id -u)/com.github.tonyyo11.jamf-reports-community.prod.daily"
```

A schedule that loads but never fires usually has a malformed `StartCalendarInterval`.
Inspect with `launchctl print` and look for warnings near the bottom.

## Disabling a stuck schedule

```bash
# First identify the label from launchctl list
LABEL="com.github.tonyyo11.jamf-reports-community.prod.daily"

# Unload the agent and remove the plist
launchctl bootout "gui/$(id -u)/$LABEL"
rm ~/Library/LaunchAgents/$LABEL.plist
```

Then re-create the schedule from the Schedules tab to get a freshly written plist.

## Cost considerations

- **Refresh tier** (overview, security, policy-status) — summary endpoints, seconds per run.
- **Inventory tier** (lists, profiles, apps, EA coverage) — pageable bulk queries, tens of seconds.
- **Scan tier** (full inventory, device compliance, patch/update failures) — per-device
  enumeration, minutes on large fleets. Schedule these overnight if your account has
  rate limits or if your on-prem Jamf Pro is memory-constrained.

The app does not throttle jamf-cli. It inherits whatever rate limits your tenant and
service account enforce. If you see HTTP 429 in the run logs, lower the
Scan schedule's cadence, drop the Scan tier from that schedule, or split
inventory collection across multiple profiles with staggered cadences.
