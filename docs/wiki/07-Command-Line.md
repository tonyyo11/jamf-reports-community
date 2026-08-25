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

### Gating a job on config health

`check --json` emits the findings as a structured document. `passed` and the
exit code always agree, so either can drive a CI step or a monitoring probe:

```sh
jamf-reports check --profile prod --json > check.json || echo "config needs attention"
```

Only genuine failures set a non-zero exit. Warnings are reported but do not fail
the run — a warning is something to look at, not a reason to break a pipeline.


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

The app's built-in **Automation** still schedules unattended runs through
LaunchAgents (see [Scheduling & Automation](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation)) — that
path is unchanged. The CLI is for interactive use and for building your own
automation. To schedule the CLI yourself, point a `launchd` job or `cron` entry
at the installed `jamf-reports` command. PDF output is GUI-only; the CLI produces
`.xlsx` and HTML.

A schedule you build yourself around the CLI **does** get most of the app's automation-trust
machinery: `collect` and `generate` evaluate metric alerts (collect only), post the `notify:`
webhook digests, and record to Run History under a `cli-collect` / `cli-generate` label. The
one exception is the **dead-man switch** — it can only measure "overdue" against a LaunchAgent
`StartCalendarInterval`, which a cron/launchd job you write yourself does not expose, so it
cannot tell that your own timer stopped. See
[Automation Trust → What counts as a scheduled run](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust#what-counts-as-a-scheduled-run)
for the exact boundary. If you want dead-man coverage too, let the app's Automation screen
manage the LaunchAgent instead of a self-written cron/launchd job.
