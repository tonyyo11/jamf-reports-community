# Background Refresh

JamfReports keeps its cached jamf-cli data fresh through a tiered set of macOS
LaunchAgents. Tiers are opt-in, configured per profile from the Schedules tab, and
run as the logged-in user — never as root.

## What this is NOT

These are not LaunchDaemons. The app does not request `sudo` and does not install
anything outside `~/Library/LaunchAgents`. There is no system-wide service. If your
Mac is logged out, the tiers do not run.

## Tiers

| Tier | Cadence       | Collects                                                                                | When to enable                                          |
|------|---------------|-----------------------------------------------------------------------------------------|---------------------------------------------------------|
| HOT  | every 15 min  | overview, security summary, patch-status summary, update-status summary                 | Always — cheap and keeps the UI responsive              |
| WARM | every 4 hours | policies list, profiles list, scripts list, packages list, smart groups, ea-coverage    | Whenever you want the Data Sources + Generated tabs fresh |
| COLD | every 24 hours| full computers list, full mobile devices list, EA results, patch failure detail        | Production tenants where overnight freshness matters    |

When enabled, each tier writes a plist into `~/Library/LaunchAgents/` named
`com.jamfreports.<profile>.<tier>.plist` and runs `jamf-cli` against that profile.

## Enabling and disabling tiers

Schedules tab -> pick a profile -> toggle the tier. The toggle:

1. Writes the plist atomically.
2. Loads it into the per-user launchd domain.
3. Triggers an immediate first run so the cache is populated.

Disabling a tier unloads the agent and removes the plist. Cached JSON from prior runs
is preserved so reports continue to render until you re-enable.

## Where logs live

Each tier writes to `~/Library/Logs/JamfReports/<label>/`:

```
~/Library/Logs/JamfReports/
└── com.jamfreports.<profile>.<tier>/
    ├── stdout.log
    ├── stderr.log
    └── runs/
        └── 2026-05-07T031500.log     # one file per invocation
```

Per-run files contain the full streamed jamf-cli output. The `stdout.log` and
`stderr.log` files are rolling and truncated by the launchd `StandardOutPath` /
`StandardErrorPath` directives. Per-run files are rotated by the app itself: oldest
files are deleted when the directory exceeds `automation.log_retention_runs`
(default 200) per tier.

## Inspecting a tier

```bash
# List loaded JamfReports agents for the current user
launchctl list | grep com.jamfreports

# Print the plist for a specific tier
launchctl print "gui/$(id -u)/com.jamfreports.prod.warm"

# Tail the live log
tail -f ~/Library/Logs/JamfReports/com.jamfreports.prod.warm/stdout.log

# Force an immediate run
launchctl kickstart -k "gui/$(id -u)/com.jamfreports.prod.warm"
```

A tier that loads but never fires usually has a malformed `StartCalendarInterval` or
`StartInterval`. Inspect with `launchctl print` and look for warnings near the bottom.

## Disabling a stuck tier

```bash
launchctl bootout "gui/$(id -u)/com.jamfreports.prod.warm"
rm ~/Library/LaunchAgents/com.jamfreports.prod.warm.plist
```

Then re-enable from the Schedules tab to get a freshly written plist.

## Cost considerations

- HOT calls are summary endpoints and complete in seconds against most tenants.
- WARM list endpoints are pageable and complete in tens of seconds.
- COLD pulls full inventory and per-plan details. On a 5,000-device tenant this can
  take several minutes per run. Schedule it overnight if your service account has a
  rate limit.

The app does not throttle jamf-cli; it inherits whatever rate limits your tenant and
service account enforce. If you see HTTP 429 in the per-run logs, lower the COLD
cadence or split inventory collection into multiple profiles.
