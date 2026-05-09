# First Run Checklist

One page. Tick each box in order. If a step fails, jump to
[TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md).

## Prerequisites

- [ ] macOS 14 or later (`sw_vers -productVersion`)
- [ ] Homebrew installed (`brew --version`)
- [ ] `jamf-cli` installed (`brew install jamf-cli && jamf-cli --version`)
- [ ] Jamf Pro server URL on hand
- [ ] Jamf Pro API client ID and secret on hand
- [ ] Network reach to the Jamf Pro server confirmed (`curl -I <server-url>`)

## App install

- [ ] `JamfReports.app` copied into `/Applications`
- [ ] First launch passed Gatekeeper (right-click -> Open if unsigned)
- [ ] Onboarding sheet appeared

## Profile creation

- [ ] Profile slug chosen (lowercase, matches `^[a-z0-9][a-z0-9._-]*$`)
- [ ] Server URL entered
- [ ] Client ID entered
- [ ] Secret pasted (it is not stored by the app)
- [ ] Authentication succeeded (green check in Onboarding)
- [ ] First collect run completed (Run History tab shows a green entry)

## Verify on disk

- [ ] `ls ~/Jamf-Reports/<profile>/` shows `config.yaml` and `jamf-cli-data/`
- [ ] `ls ~/Jamf-Reports/<profile>/jamf-cli-data/` shows JSON files

## First report

- [ ] Generated tab opens without error
- [ ] **Executive** template selected
- [ ] Output format chosen (XLSX, HTML, or PDF)
- [ ] Generate clicked, Run History tab streamed output
- [ ] Artifact appears under `Generated Reports/`
- [ ] Artifact opens cleanly

## Optional but recommended

- [ ] Data Sources tab inspected; row counts match expectations
- [ ] Health Audit tab opened; no red findings on baseline
- [ ] Schedules tab: HOT tier enabled (15 min computer overview refresh)
- [ ] Schedules tab: WARM tier enabled (4 h policy / patch refresh)
- [ ] Schedules tab: COLD tier enabled (24 h full inventory refresh)
- [ ] Logs reviewed at `~/Library/Logs/JamfReports/<label>/`

## Hand-off ready

- [ ] Profile folder backed up or documented
- [ ] Service account credentials stored in your team password manager
- [ ] Owner identified for each enabled tier
