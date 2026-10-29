# Command Line

The app ships an included `jamf-reports` command-line interface. It is the same
binary as the GUI — when you run it with a recognized subcommand it executes
headlessly; with no arguments it opens the app. An unknown first word (one not
starting with `-`) prints an error and exits non-zero; a flag the system adds
(`-psn_…`) still opens the app. The CLI uses the native Swift report engine, so its
output matches what the app produces.

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
manages under `~/Jamf-Reports/<profile>/`), except `scaffold`, which writes a
standalone `config.yaml` (its `--csv` is optional — see below).

To point one command at a different workspaces folder than the app's Settings →
Workspace location, use `JRC_WORKSPACES_ROOT`:

```sh
JRC_WORKSPACES_ROOT="$HOME/Library/CloudStorage/OneDrive-Contoso/Team/Jamf Reports" \
  jamf-reports check --profile prod
```

The CLI, the app and its scheduled runs all read the Settings → Workspace location
setting, so the variable is needed only to point one command at a different folder. A
configuration profile that sets the workspace location wins over the variable (see
[Managed Preferences](https://github.com/tonyyo11/jamf-reports-community/wiki/14-Managed-Preferences)).

`--profile` takes the jamf-cli profile name exactly as jamf-cli spells it. Quote a
name with spaces or shell characters (`--profile 'Acme Prod'`), and join a name that
starts with `-` with an equals sign (`--profile=-lab`), since a separate value that
starts with `-` reads as another option. In `--exclude` lists, write a comma inside a
name as `%2C` and a percent sign as `%25`.

| Command | What it does | Key options |
|---------|--------------|-------------|
| `generate` | Generate an `.xlsx` workbook from cached snapshots (and the HTML report beside it when `html.with_workbook` is `true`); a Jamf School workspace gets the School workbook | `--profile`, `--output <path>`, `--template <id>`, `--csv-folder` |
| `collect` | Collect fresh `jamf-cli` snapshots (Jamf Pro, Jamf School, and Jamf Protect when connected) | `--profile`, `--tiers refresh,inventory,scan`, `--force` |
| `html` | Generate the self-contained HTML report (the Full Instance layout: figures and attention list first, collapsed detail groups, audit appendix); refuses a Jamf School workspace | `--profile`, `--output <path>` |
| `backup` | Back up Jamf Pro config objects (`jamf-cli pro backup`), and Jamf Protect's (`jamf-cli protect backup`) when the workspace has Protect connected and is not on shared storage | `--profile` |
| `scaffold` | Write a minimal jamf-cli-only `config.yaml`; with a Jamf Pro CSV export, also add its extra columns as `custom_eas` (read once) | `--csv <path>` (optional), `--out <path>` |
| `check` | Run every config, data-accuracy and workspace check, with a fix for each finding | `--profile`, `--json` |
| `capabilities` | Report which `jamf-cli` commands are available | `--json` |
| `diagnostic-bundle` | Build a redacted diagnostic zip | `--profile` |
| `device` | Print one device's detail JSON (Jamf Pro profiles only) | `--profile`, `--id <serial-or-id>` |
| `school-check` | Validate a Jamf School workspace; refuses a profile that is not one | `--profile` |
| `schedules` | List, add, remove, or run hand-built schedules (managed ones come from the Automation policy and are not editable here) | `list`, `add …`, `remove <label>`, `run <label>` |
| `verify` | Check a report run's manifest: every file's size and SHA-256, and the RFC 3161 timestamp beside it when there is one; exits `1` when anything differs | `<stem>.manifest.json` |

### Gating a job on config health

`check` runs every validation the app has, not just "does `config.yaml` parse":
baselines pointing at extension attributes
nobody collects, tracked extension attributes with no collected values, malformed alert rules, data accuracy, and the state of the
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

- With `html.with_workbook: true` in `config.yaml`, `generate` also writes the HTML report
  beside the workbook, with the same name and a `.html` extension and the template's HTML
  sections. The HTML report's own log lines print before the workbook path, which stays the
  last line on stdout. If the HTML report cannot be written, `generate` still exits `0` with
  the workbook and prints a `[warn] HTML report not written: …` line to stderr. `html` is a
  separate command and always writes one HTML report.
- `generate --csv-folder` (or `output.csv_folder: true` in `config.yaml`, which scheduled runs
  follow) also writes one CSV per workbook tab into a folder beside the workbook, named like
  it with `_csv` added. It holds the rows the workbook tabs hold, honours `sheets.only`,
  `skip` and `order`, and moves to the archive with its workbook. A failure prints a
  `[warn] CSV folder not written: …` line and leaves the workbook as it is.
- Every workbook run (`generate`, the app, a schedule) and every Generate run in the app also
  writes `<name>.manifest.json`, named after the workbook (else the run's first file): the size
  and SHA-256 of the workbook, its HTML report, each CSV in its CSV folder, and the HTML, PDF
  and CSV formats the Generate run wrote with it. Chart PNGs and the period and fleet reports
  are not listed. `jamf-reports verify <manifest>` prints `OK`, `CHANGED`, `MISSING` or
  `UNREADABLE` for each, `EXTRA` for a file added to a listed folder (Finder's `.DS_Store`
  excepted), and exits `1` unless all match. With `output.timestamp_authority: "https://…"`
  the manifest's SHA-256, a random nonce and fixed request headers (`User-Agent: JamfReports`)
  are sent to that RFC 3161 time-stamp authority, nothing else, and its signed reply saved as
  `<name>.tsr`; `verify` then checks the reply signs this manifest and prints the authority's
  time, its certificate's SHA-256 fingerprint and whether this Mac trusts its certificate
  chain. Compare that fingerprint with the one the authority publishes: a self-signed
  certificate can name itself anything. A failed request is a `[warn] report timestamp not
  saved: …` line; the reports stand. On a shared workspace the address is used on a Mac only
  once it is confirmed there (Config Doctor). `https://freetsa.org/tsr` is a free test service,
  not a qualified authority. To check a reply without this app, macOS's own LibreSSL (3.3.6,
  macOS 15 and later) does it:
  `openssl ts -verify -data <stem>.manifest.json -in <stem>.tsr -CAfile <authority CA>.pem`.
- A Jamf Pro `collect` runs at most once per profile per day; a second run the same day
  exits successfully without re-collecting. A Jamf School workspace collects each source at
  most every 12 hours instead. Pass `--force` to override either.
- `generate` on a Jamf School workspace (`school_cli.enabled: true`) writes the School
  workbook and ignores `--template`; `html.with_workbook` writes no HTML beside it, since
  there is no School HTML report. `html` refuses a School workspace with a message that points
  at `generate`.
- Product guard (2.11): a Jamf Pro command never runs on a profile that belongs to another
  product. `backup` and `device` refuse a Jamf School, Jamf Protect or Security Cloud
  profile and an organization-level Platform API profile; `collect` refuses a Jamf Protect or
  Security Cloud profile and an organization-level one (a School workspace collects School
  data), and `schedules add` refuses them for a per-profile schedule, as well as `--mode backup`
  for a School workspace. Each prints
  the reason once on stderr and exits `1`, before any lock, Run History record or workspace
  file is created. `school-check` refuses a workspace that is not a Jamf School one the same way.
  A scheduled run of such a profile (`--scheduled-run` or the background item) instead prints a
  `[skip]` line and exits `0`, so nothing retries it and no failure webhook is sent.
- `backup` also backs up Jamf Protect into the same backup folder when the workspace has
  Protect connected.
  When only the Protect part falls short, the Jamf Pro backup stands: the command prints
  warnings and exits `0`.
- `scaffold` **overwrites** the `--out` file if it already exists — it's an
  initial-setup command. It copies the existing file to `<out>.bak-<date-time>`
  first and prints the path on stderr. To add extension attributes to an existing
  `config.yaml`, use **Adopt EAs** in the app, which keeps your other settings. This applies
  whether or not `--csv` is given.
- `scaffold --csv <path>` reads the export once and writes only `custom_eas` for its
  columns Jamf Reports does not already know. No `columns` mapping is written, and the CSV is
  not read again by `generate`, `collect` or any schedule.
- `collect` tolerates a missing `config.yaml` and proceeds with defaults; `generate`
  and `html` require one to exist and fail without it. `scaffold --out <path>` with
  `--csv` omitted writes a minimal jamf-cli-only `config.yaml` — the same starting
  point the GUI onboarding's Workspace step writes — so a `config.yaml` can
  be created headlessly with no CSV export at all.
- `collect` and `generate` surface the app's automation-trust signals. A successful
  `collect` evaluates metric alerts and posts the `notify:` webhook digest (just like a
  snapshot-only scheduled run); `generate` posts its digest like a jamf-cli-only run (from
  cache, so no alerts). Both record to Run History under a `cli-collect` / `cli-generate`
  label, and a failure posts the failure card. These signals are best-effort and additive —
  a webhook or recording failure never changes the exit code or the command's stdout. `html`
  does not emit these signals.
- Every `jamf-reports` command, read-only ones like `check`, `capabilities` and `--version`
  included, first does the background-item setup an app launch does: the one-time import of
  schedules from an older install's `~/Library/LaunchAgents` files (archiving and removing
  the managed ones), then registering the background item if **Manage automation** is on or
  a hand-built schedule exists. A command never unregisters the item, and never turns one
  back on that was switched off under **Login Items › Allow in the Background**.

### Templates

`generate --template <id>` selects which sheets to include. The default is
`full-instance` (every sheet). Available ids: `full-instance`, `executive`,
`operational`, `compliance`, `asset`, `security-posture`, `school`.

### Jamf School commands

`school-check` validates a Jamf School workspace and exits `1` on a profile that is not one.
`collect` and `generate` handle a School workspace as described above. If you run Jamf School,
please [open an issue or pull request](https://github.com/tonyyo11/jamf-reports-community/issues)
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
`"Weekdays 09:00"`, and `"Day 15 06:20"` (a day of the month).

`--mode` takes `snapshot-only`, `jamf-cli-only`, `jamf-cli-full` or `backup`. The retired
`csv-assisted` mode (2.11) is refused with a message that names `jamf-cli-full`; a schedule
saved earlier with it runs as `jamf-cli-full`, and `schedules list` prints it as
`jamf-cli-full (was csv-assisted)`. See
[Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation)
for what each mode does. A schedule added this way is
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
convention where the command passes jamf-cli's exit code through: `backup` exits with
jamf-cli's own code, so `3` means expired or invalid credentials (re-authenticate the
profile). `collect`, `generate`, `html`, `device` and the other commands exit `1` on any
failure, expired credentials included, and print `error: …` or `Error: …` with the cause
and the re-authentication command. Argument and usage errors exit `64`. Exit code `75` means the command did
not run because a collect, a report or a scheduled run on this Mac holds the lock; run it
again when that finishes. This makes the commands safe
to gate on in a shell script:

```sh
jamf-reports collect --profile prod && jamf-reports generate --profile prod
```

`collect`, `generate`, `html`, `backup` and `--scheduled-run` take the lock and exit `75`
when it is held; `schedules run` exits `75` when its run is queued for the background
item's next wake. Read-only commands such as `check` and `device` take no lock.

## Scheduling

The app's built-in **Automation** schedules unattended runs from one bundled background
item (see [Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation))
rather than through the CLI. The CLI is for interactive use, for building your own
automation, and — via `jamf-reports schedules` above — for editing the very same hand-built
schedules the background item runs. PDF output is GUI-only; the CLI produces `.xlsx` and
HTML.

A schedule added with `jamf-reports schedules add` behaves exactly like one built in the
GUI: the background item picks it up on its next wake, gives it the same missed-fire
catch-up, and covers it with the dead-man switch.

The background item is registered when something is scheduled: **Manage automation** is
on, or a hand-built schedule exists. Launching the app from its bundle registers or
unregisters it to match; a `jamf-reports` command only ever registers it, as noted above.
If the CLI was installed as a symlink, confirm under **Login Items › Allow in the
Background** that JamfReports is listed. A schedule you instead build yourself
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
