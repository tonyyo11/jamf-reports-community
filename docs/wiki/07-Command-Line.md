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
`school-scaffold`, which work on standalone CSV files.

| Command | What it does | Key options |
|---------|--------------|-------------|
| `generate` | Generate an `.xlsx` workbook from cached snapshots | `--profile`, `--output <path>`, `--template <id>` |
| `collect` | Collect fresh `jamf-cli` snapshots | `--profile`, `--tiers refresh,inventory,scan` |
| `html` | Generate the self-contained HTML report | `--profile`, `--output <path>` |
| `backup` | Back up Jamf Pro config objects (`jamf-cli pro backup`) | `--profile` |
| `scaffold` | Build a `config.yaml` from a Jamf Pro CSV export | `--csv <path>`, `--out <path>` |
| `check` | Validate a profile's `config.yaml` and `jamf-cli` auth | `--profile` |
| `capabilities` | Report which `jamf-cli` commands are available | `--profile`, `--json` |
| `diagnostic-bundle` | Build a redacted diagnostic zip | `--profile` |
| `device` | Print one device's detail JSON | `--profile`, `--id <serial-or-id>` |
| `school-check` | Validate a Jamf School profile | `--profile` |
| `school-scaffold` | Build a Jamf School `config.yaml` from a CSV | `--csv <path>`, `--out <path>` |

Run `jamf-reports help <command>` (or `jamf-reports <command> --help`) for the
full option list of any command.

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
LaunchAgents (see [Scheduling & Automation](05-Scheduling-and-Automation)) — that
path is unchanged. The CLI is for interactive use and for building your own
automation. To schedule the CLI yourself, point a `launchd` job or `cron` entry
at the installed `jamf-reports` command. PDF output is GUI-only; the CLI produces
`.xlsx` and HTML.
