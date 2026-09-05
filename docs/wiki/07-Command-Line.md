# Command Line

The app ships an included `jamf-reports` command-line interface. It is the same
binary as the GUI — when you run it with a recognized subcommand it executes
headlessly; with no arguments it opens the app. The CLI uses the native Swift
report engine, so its output matches what the app produces.

Use it to script report generation, collect snapshots on a schedule of your own,
or wire report generation into other automation.

## Installing the `jamf-reports` command

Open **Settings → Command-line tool → Install command-line tool**. The app links
itself into `/usr/local/bin/jamf-reports` (on the default `PATH`).

The app never uses administrator rights. If `/usr/local/bin` isn't writable by
your account, the button shows the exact command to run yourself, for example:

```sh
sudo mkdir -p "/usr/local/bin" && sudo ln -sf "/Applications/JamfReports.app/Contents/MacOS/JamfReports" "/usr/local/bin/jamf-reports"
```

Open a new Terminal window afterward so the updated `PATH` takes effect, then:

```sh
jamf-reports --help
```

## Commands

Every command operates on a workspace **profile** (the same profiles the app
manages under `~/Jamf-Reports/<profile>/`), except `scaffold` and
`school-scaffold`, which work on standalone CSV files (`scaffold`'s `--csv` is
optional — see below).

If the workspace has been moved off its default location (Settings → Workspace
location), point the CLI at it with `JRC_WORKSPACES_ROOT`:

```sh
JRC_WORKSPACES_ROOT="$HOME/Library/CloudStorage/OneDrive-Contoso/Team/Jamf Reports" \
  jamf-reports check --profile prod
```

Set it in the script or launchd job that calls the CLI. Scheduled runs the app
creates carry it automatically; a cron job or script you wrote yourself does not,
and without it the CLI reads the default `~/Jamf-Reports` and reports an empty
workspace rather than failing.

| Command | What it does | Key options |
|---------|--------------|-------------|
| `generate` | Generate an `.xlsx` workbook from cached snapshots | `--profile`, `--output <path>`, `--template <id>` |
| `collect` | Collect fresh `jamf-cli` snapshots | `--profile`, `--tiers refresh,inventory,scan`, `--force` |
| `html` | Generate the self-contained HTML report | `--profile`, `--output <path>` |
| `backup` | Back up Jamf Pro config objects (`jamf-cli pro backup`) | `--profile` |
| `scaffold` | Build a `config.yaml` from a Jamf Pro CSV export, or a minimal jamf-cli-only config with no CSV | `--csv <path>` (optional), `--out <path>` |
| `check` | Run every config, data-accuracy and workspace check, with a fix for each finding | `--profile`, `--json` |
| `capabilities` | Report which `jamf-cli` commands are available | `--json` |
| `diagnostic-bundle` | Build a redacted diagnostic zip | `--profile` |
| `device` | Print one device's detail JSON | `--profile`, `--id <serial-or-id>` |
| `school-check` | Validate a Jamf School profile | `--profile` |
| `school-scaffold` | Build a Jamf School `config.yaml` from a CSV | `--csv <path>`, `--out <path>` |
| `schedules` | List, add, remove, or run hand-built schedules (managed ones come from the Automation policy and are not editable here) | `list`, `add …`, `remove <label>`, `run <label>` |

### Gating a job on config health

`check` runs every validation the app has, not just "does `config.yaml` parse":
column mappings against your CSV, baselines pointing at extension attributes
nobody collects, malformed alert rules, data accuracy, and the state of the
workspace folder — including whether more history for the profile sits in
another folder, and whether this is a new workspace still on default settings.
On a shared workspace it also lists the other Macs writing there. Each finding
carries a concrete fix.

`check --json` emits the same findings as a structured document. `passed` and the
exit code always agree, so either can drive a CI step or a monitoring probe:

```sh
jamf-reports check --profile prod --json > check.json || echo "config needs attention"
```

The document carries `profile`, `passed`, a `counts` object
(`pass`, `suggest`, `warn`, `fail`), and a `findings` array whose entries have
`id`, `severity`, `title`, `detail`, and the same `fix` text a human sees.

Only genuine failures set a non-zero exit. Warnings are reported but do not fail
the run — a warning is something to look at, not a reason to break a pipeline.
Scheduled runs record failing checks in their own run log too, so a run that
collected happily against a broken config does not look clean in Run History.


Run `jamf-reports help <command>` (or `jamf-reports <command> --help`) for the
full option list of any command.

A few behaviors worth knowing:

- `collect` runs at most once per profile per day; a second run the same day
  exits successfully without re-collecting. Pass `--force` to override.
- `scaffold` **overwrites** the `--out` file if it already exists — it's an
  initial-setup command. To safely update an existing `config.yaml`, use the
  app's re-scaffold (which merges non-destructively) instead. This applies whether
  or not `--csv` is given.
- `collect` tolerates a missing `config.yaml` and proceeds with defaults; `generate`
  and `html` require one to exist and fail without it. `scaffold --out <path>` with
  `--csv` omitted writes a minimal jamf-cli-only `config.yaml` — the same starting
  point the GUI onboarding's **Skip for now** step writes — so a `config.yaml` can
  be created headlessly with no CSV export at all.
- `collect` and `generate` surface the app's automation-trust signals. A successful
  `collect` evaluates metric alerts and posts the `notify:` webhook digest (just like a
  snapshot-only scheduled run); `generate` posts its digest like a jamf-cli-only run (from
  cache, so no alerts). Both record to Run History under a `cli-collect` / `cli-generate`
  label, and a failure posts the failure card. These signals are best-effort and additive —
  a webhook or recording failure never changes the exit code or the command's stdout. `html`
  does not emit these signals.

### Templates

`generate --template <id>` selects which sheets to include. The default is
`full-instance` (every sheet). Available ids: `full-instance`, `executive`,
`operational`, `compliance`, `asset`, `security-posture`, `school`.

### Jamf School commands

`school-check` and `school-scaffold` are first-class commands, but they ship
**untested** — the maintainer has no Jamf School tenant to validate against. If
you run Jamf School, please try them and
[open an issue or pull request](https://github.com/tonyyo11/jamf-reports-community/issues)
with feedback.

### Hand-built schedules from the command line

`jamf-reports schedules` reads and writes the same store the Schedules screen shows,
so a schedule added here appears there and vice versa. Managed schedules (from the
Automation policy) are derived, not stored, and are not editable through this command.

```sh
# List every hand-built schedule
jamf-reports schedules list

# Add a daily snapshot-only schedule for one profile
jamf-reports schedules add --name "Prod daily" --profile prod \
  --mode snapshot-only --cadence "Daily 06:20"

# Add a weekly, all-profiles backup, skipping one profile
jamf-reports schedules add --name "Weekly backup" --profile prod --all-profiles \
  --exclude sandbox --mode backup --cadence "Mon 07:00"

# Remove a schedule by the label `schedules list` prints
jamf-reports schedules remove com.github.tonyyo11.jamf-reports-community.prod.prod-daily

# Run a schedule (hand-built or managed) right now and wait for it to finish
jamf-reports schedules run com.github.tonyyo11.jamf-reports-community.multi.managed-freshness
```

`--cadence` accepts four forms: `"Daily 06:20"`, `"Mon 07:00"` (any weekday name),
`"Weekdays 09:00"`, and `"Day 15 06:20"` (a day of the month). A schedule added this way is
picked up by the bundled background item on its next wake, gets the same missed-run
catch-up as one built in the GUI, and shows up in the dead-man switch.

## Examples

```sh
# Collect everything, then generate the default workbook
jamf-reports collect --profile prod
jamf-reports generate --profile prod

# Collect only the fast refresh tier
jamf-reports collect --profile prod --tiers refresh

# Generate just the executive summary to a specific path
jamf-reports generate --profile prod --template executive --output ~/Desktop/exec.xlsx

# Self-contained HTML report
jamf-reports html --profile prod

# What can the installed jamf-cli do? (machine-readable)
jamf-reports capabilities --json

# Validate a profile before scheduling it
jamf-reports check --profile prod
```

## Exit codes

Commands exit `0` on success and non-zero on failure, following the `jamf-cli`
convention — notably exit `3` for expired or invalid credentials (re-authenticate
the profile). Argument and usage errors exit `64`. This makes the commands safe
to gate on in a shell script:

```sh
jamf-reports collect --profile prod && jamf-reports generate --profile prod
```

## Scheduling

The app's built-in **Automation** schedules unattended runs from one bundled background
item (see [Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation))
rather than through the CLI. The CLI is for interactive use, for building your own
automation, and — via `jamf-reports schedules` above — for editing the very same hand-built
schedules the background item runs. PDF output is GUI-only; the CLI produces `.xlsx` and
HTML.

A schedule added with `jamf-reports schedules add` behaves exactly like one built in the
GUI: the background item picks it up on its next wake, gives it the same missed-fire
catch-up, and covers it with the dead-man switch. A schedule you instead build yourself
around the CLI — a `launchd` job or `cron` entry calling `collect`/`generate` directly —
**does** get most of the app's automation-trust machinery: metric alerts (collect only),
the `notify:` webhook digests, and Run History under a `cli-collect` / `cli-generate` label.
The one exception is the **dead-man switch**, which can only measure "overdue" against a
schedule the app itself knows about; a cron/launchd job you write yourself is not one, so it
cannot tell that your own timer stopped. Likewise, an external scheduler calling
`--scheduled-run` directly gets Run History and webhooks but not the tick's catch-up, since
only the background item's own wake evaluates missed fires. See
[Automation Trust → What counts as a scheduled run](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust#what-counts-as-a-scheduled-run)
for the exact boundary. If you want dead-man coverage and catch-up without touching the GUI,
use `jamf-reports schedules add` instead of a self-written cron/launchd job.
