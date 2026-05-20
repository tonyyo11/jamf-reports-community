# Troubleshooting

Most likely failure modes, what they mean, and the recovery path. Walk this list in
order before opening an issue.

## What this is NOT

Not an exhaustive error reference. The Run History tab streams full jamf-cli output
for any generation; if a failure is not listed here, copy that output into the issue.

## jamf-cli not on PATH

Symptom: every run fails immediately with `jamf-cli: command not found` or the app
shows a red banner on launch saying "jamf-cli not detected".

Cause: the binary either is not installed, or it is installed under a Homebrew prefix
not on the GUI app's `PATH` (Apple Silicon Macs install brew under `/opt/homebrew`,
which is not always inherited by GUI apps launched from Finder).

Fix:

```bash
brew install jamf-cli
which jamf-cli                              # confirm path
sudo ln -s "$(which jamf-cli)" /usr/local/bin/jamf-cli   # only if app still cannot find it
```

Relaunch the app after symlinking.

## Expired token

Symptom: collect runs fail with `401 Unauthorized` or `token expired`.

Cause: the OAuth token jamf-cli stored in its keychain has expired or been revoked
on the server.

Fix:

```bash
jamf-cli auth login --profile <slug>
```

Re-enter the client ID and secret. The app does not need to be relaunched.

## Profile slug rejected

Symptom: Onboarding refuses the slug with "Invalid profile name".

Cause: slug does not match `^[a-z0-9][a-z0-9._-]*$`. Spaces, capitals, or leading
non-alphanumeric characters are rejected to keep the workspace path safe.

Fix: pick a slug like `prod`, `cbp-prod`, or `tenant.east`.

## Full-disk warning

Symptom: collect runs fail with `no space left on device`, or a yellow banner appears
warning that `~/Jamf-Reports/` is over the configured size budget.

Cause: COLD tier inventory archives accumulate. Default `keep_latest_runs` is 10 but
COLD JSON for a large tenant can be 100 MB+ per run.

Fix:

```bash
du -sh ~/Jamf-Reports/<profile>/*
```

Lower `output.keep_latest_runs` in `config.yaml`, or move old runs out of the
`archive/` directory.

## Log rotation

Per-run logs in `~/Library/Logs/JamfReports/<label>/runs/` are rotated automatically
once the count exceeds `automation.log_retention_runs` (default 200). To rotate
manually:

```bash
ls -t ~/Library/Logs/JamfReports/com.jamfreports.prod.warm/runs/ | tail -n +101 | \
  xargs -I{} rm "~/Library/Logs/JamfReports/com.jamfreports.prod.warm/runs/{}"
```

The rolling `stdout.log` and `stderr.log` are managed by launchd itself; truncate
with `: > stdout.log` if they grow unreasonably large between rotations.

## "[skip]" lines in run output

Lines like `[skip] patch-failures: cached data older than 24h, awaiting next COLD run`
mean a sub-step decided not to run because the cached data it needed was stale or
absent. This is normal during the first 24 hours after enabling tiers and after any
extended period of the Mac being asleep.

If `[skip]` lines persist after a full HOT/WARM/COLD cycle, the relevant cached JSON
file is missing. Force a manual collect:

```bash
launchctl kickstart -k "gui/$(id -u)/com.jamfreports.<profile>.cold"
```

## Health Audit shows red EAs

Symptom: Health Audit tab shows one or more Custom EAs in red with "column not found
in cached data".

Cause: the EA name in `config.yaml` does not match the canonical name jamf-cli
returns. Common reasons: the EA was renamed in Jamf Pro, has trailing whitespace,
or was deleted.

Fix: open the Customization Wizard, re-discover EAs, and tick the corrected name.
The wizard rewrites the entry; manually fix the `column:` value if scripting.

## Data Sources tab shows zero devices

Symptom: counts on the Data Sources tab read zero across the board.

Cause: cached JSON exists but the active profile points at a different `data_dir`,
or the profile was switched in the sidebar without a refresh.

Fix:

1. Confirm the sidebar profile chip shows the right slug.
2. Check `jamf_cli.data_dir` in `config.yaml` resolves to a populated directory.
3. Generated tab -> any template -> Generate; the run will refresh the cache.

## Notarization warning on first launch

Symptom: macOS refuses to open the app with "JamfReports cannot be opened because
the developer cannot be verified".

Cause: the build is ad-hoc signed (developer build), not Developer-ID signed and
notarized.

Fix: right-click the app in Finder, choose Open, confirm at the dialog. macOS
remembers the choice. For fleet deployment, request a notarized build from your
JamfReports distributor.
