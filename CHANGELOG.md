# Changelog <!-- markdownlint-disable MD024 -->

All notable user-visible changes to this project should be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions in this repository map to git tags.

## [Unreleased]

### Added

The whole workspace can now live on a shared team folder, so several Macs
covering the same Jamf Pro tenants build one pooled history instead of a
separate one each. Choose the folder in **Settings → Workspace location**;
OneDrive, SharePoint, Box, Dropbox, Google Drive and mounted shares all work.
Coordination switches itself on when the folder is a synced one: a scheduled
collect stands down when another Mac collected recently — naming which and when
— and each run publishes a short claim so a second machine can see one is
already working. Pressing Refresh always collects anyway. Tune it per workspace
with the new `shared_workspace` block, or leave it alone and it decides for
itself.

If you only want colleagues to read the reports, the narrower option is still
there and still preferred: keep the workspace local, set
`output.allow_absolute_paths: true`, and point `output.output_dir` at the shared
folder. One thing a shared workspace cannot do for you is decide who should see
raw device data — serials, usernames and email addresses sit in clear text in
the snapshots and run logs, and folder permissions are the sync provider's, not
this app's. Run check says so every time.

Choosing a shared folder now asks you to confirm it, naming what becomes
readable — device serials, usernames, email addresses and any configured webhook
URL — and pointing at the narrower publish option if the audience for the
reports is wider than the audience for raw inventory. Picking a local folder is
unchanged.

On a shared workspace, Overview says when another Mac is mid-run, so Refresh
doing nothing reads as "someone else is working" rather than a bug. Each day's
summary records which machine collected it. Backup retention works again on a
shared folder: each backup records the Mac that made it and each machine prunes
only its own, instead of retention being switched off entirely.

`jamf-reports check --json` emits the same findings as a structured document,
so a CI job or monitoring probe can gate on config health. A scheduled run now
records failing config checks in its own log, so a run that collects happily
against broken column mappings no longer looks clean in Run History.

**Run check** (Config screen, and `jamf-reports check` from Terminal) now runs
every validation the app has instead of only confirming that `config.yaml`
parses. It reports column mappings that no longer match your CSV, baselines
pointing at extension attributes that aren't collected, malformed alert rules,
data-accuracy problems, and the state of the workspace folder — with a concrete
fix under each finding. On a shared workspace it also lists which other Macs
write there, when each last collected, whether their clocks and app versions
agree, and any leftover claim or sync-conflict file.

Comparing two backups now shows a summary of what actually changed instead of the
full configuration of every changed object. Objects taking the same update collapse
into one line, and objects that changed the same field to different values collapse
into one card with a line each — on a real pair of production backups that turns
ten screens of JSON into two lines. The old output is still one click away under
**Raw**, the whole diff can be copied, and the sheet finally has a Done button
(Escape works too) and lets you select text across lines.

### Fixed

Reports that jamf-cli refuses now say why. A non-zero exit was reported as a
bare number, so "exit 2" was all you got when the real answer — printed by
jamf-cli itself — was that the command wanted credentials for a different
product. Its own message is now included in the warning.

The Patch Failures sheet came back. jamf-cli 1.24 and later print a section
header before the JSON when asked for patch failures, which made the whole
snapshot unparseable and dropped the sheet silently. Any such text ahead of the
payload is now skipped. Output that is genuinely broken or truncated is still
rejected rather than half-read.

Three crashes found in production testing on a shared workspace.

A tenant with two extension attributes sharing a display name crashed the app
outright. Extension-attribute names come from the server and are not unique, and
the code assumed they were. This took down scheduled runs in particular, because
those now run the config checks.

Writing a run-history log line could abort the whole process when the workspace
is on a sync provider. The write API in use reported failure in a way that could
not be caught, so a file the provider had evicted or a share that had gone
offline killed the collect instead of losing one log line. Log lines are now
dropped with a warning; the collect continues.

A CSV export with two columns whose names differ only in punctuation or case
("Serial Number" and "serial_number") crashed device inventory. The first column
now wins.



Overview tiles now name the day their change figure compares against ("vs Aug 20")
instead of leaving it unstated. The comparison is against the previous collection,
not a fixed week, so a missed run can make that gap days or weeks — and because a
metric that went unmeasured on some day is skipped, two tiles on the same screen can
legitimately be comparing against different days. The drill-down's Previous and
Change tiles name their dates too.

Old scheduled backups could be deleted in the wrong order — potentially removing
the newest ones — on a cloud-synced or network volume, because the sort used
modification dates that sync providers rewrite. Backups are now ordered by the
timestamp in their folder name, any folder whose name can't be read aborts the
whole cleanup rather than guessing, and automatic pruning is skipped entirely
while the backups folder is synced (that folder may hold another Mac's backups).

Dashboards could disagree about which day of data they were showing on synced
storage: some read the newest snapshot by filename and others by modification
date. They all use the filename now. Duplicate files a sync provider leaves
behind (`… 2.json`, `… (1).json`) are ignored everywhere rather than being
mistaken for the newest snapshot, and duplicate daily summaries no longer produce
double points in Trends.

- Device Lookup and the Devices detail panel's jamf-cli section work again.
  jamf-cli's `pro device` command accepts `--out-file` but prints its JSON to
  the terminal instead of writing the file (an upstream bug present through
  jamf-cli 1.26.0), so the app saw a successful exit with no data and showed
  every device's live detail as unavailable. The app now captures the
  command's output directly and no longer depends on the file, which also
  keeps working once jamf-cli fixes the flag.

## [2.6.1] - 2026-08-14

### Security

A verified security review covered the reporting services, then the report
engine, and then the app's scheduled-run entry point and command-line tool.
Everything those reviews turned up is fixed here. None of it can be triggered
remotely on its own, and the two worth reading are the webhook one (it needs an
action from you) and the risk scorer (it was under-reporting devices you'd want
to see).

The third review — covering the unattended scheduled-run path, every webhook
the app sends, and the bundled `jamf-reports` command-line tool — found **no
new security issues**. What it did find was a set of accuracy and reliability
problems, several of which caused a run that had not done its job to look like
one that had; those are under Fixed below.

- Diagnostic bundles no longer carry your Teams or Slack notification webhook
  URL. The bundle exists to be shared, and its redaction pass promised
  "secrets always removed" — but it looked for a key named `webhook_url`,
  while the app stores the webhook under `notify:` as `url`. Masking the
  hostname wasn't enough either: for both providers the secret travels in the
  URL path. An incoming-webhook URL is a posting credential, so anyone holding
  an affected bundle could post messages into that channel as your reporting
  bot. **If you have notifications enabled and have shared a diagnostic bundle,
  rotate the webhook URL in Teams or Slack.** The same gap in log exports and
  webhook error text is fixed alongside it.
- A device's own name or serial can no longer be read as a command-line flag
  when fetching device details. Those values come from the fleet rather than
  from you, so a renamed Mac could put a flag where an identifier belonged.
- The checksums file downloaded during a jamf-cli install or update is now
  written to a fixed local filename, and every download is confined to its
  temporary directory, so a name supplied by the release server can't place a
  file elsewhere before verification runs.
- An unusually large number arriving in Jamf data can no longer stop the app
  mid-run. Two places converted such a number in a way that aborted the process
  outright, and because the data is cached, a single bad value could keep
  ending every later run until the cached copy was deleted by hand. The most
  likely cause was always a misbehaving Extension Attribute script rather than
  anything deliberate.
- A patch title identifier supplied by your Jamf Pro server can no longer be
  read as a command-line flag when release dates are collected, matching the
  guard already applied to device names.

### Fixed

- Devices reporting FileVault, SIP, Gatekeeper or the firewall as "Not
  Enabled" / "Not Encrypted" are no longer scored as healthy. The risk scorer
  matched the word "enabled" inside "not enabled", so an unprotected Mac could
  score Clean and be filtered out of the Devices "Priority" list — the screen
  meant to surface exactly those devices. Underscore forms (`NOT_ENCRYPTED`)
  and "Off" are now recognised too. Expect some devices to appear in Priority
  that previously did not; that is the correction, not a regression. A control
  the tenant never reported still counts as unknown rather than failing.
- The "Require snapshot manifest" setting description (Configuration →
  jamf-cli Cache) overstated what it does. It now says what actually happens:
  only tampered snapshots (a hash mismatch or a corrupt manifest) are
  hard-failed. Missing or legacy manifests are tolerated, not blocked.
- Workbooks can no longer be produced in a state Excel refuses to open. A
  custom Extension Attribute whose name contained an invisible control
  character, or two whose names matched over their first 31 characters, would
  produce a sheet name Excel rejects — and because the workbook is what gets
  emailed or put on a shared drive, the failure landed on everyone who opened
  it, not just whoever generated it.
- With the snapshot manifest check enabled, it now verifies the same snapshot
  the report actually renders. It picked the newest file by modification time
  while the report picked by the date in the filename, and on synced storage
  those two disagree.
- Re-detecting column mappings from a CSV export no longer freezes the window
  while the file is read, and building the trend comparison no longer parses
  the same export three times.
- A scheduled run that crashed, was killed, or lost power partway through no
  longer appears in Run History as a successful run. Such a run never gets to
  write its closing line, and the missing line was being read as "exited
  cleanly" — so the row showed OK and EXIT 0 for a run that never finished. It
  now shows a warning and no exit code. The overdue banner already caught this
  case about an hour later; the run list was the surface still claiming success.
- A report that failed to write some of its sheets no longer shows as fully
  healthy. The Schedules "Last Run" column and Automation Health read only a
  success flag and ignored the failed-sheet count sitting beside it, so a
  workbook missing sheets reported the same green state as a complete one. Both
  now show the run as partial, and the command-line `generate` records the same
  partial marker the scheduled path always has.
- A fleet-health alert whose webhook post fails is now retried on the next run.
  The app was marking the alert as sent before knowing whether it had been, so
  a brief network problem silenced that alert for the rest of the day. This is
  the same "only claim it once it's delivered" rule the overdue digest already
  followed.
- `jamf-reports collect` now collects Jamf Protect data. The bundled
  command-line tool skipped the Protect step that the app and its scheduled
  runs perform, then reported success — so anyone collecting via their own cron
  job had Protect dashboards quietly going stale with nothing to indicate it.
  Jamf School profiles invoked this way are now routed correctly too.
- A column name containing an invisible line-break character can no longer
  corrupt `config.yaml` when mappings are scaffolded from a CSV export. Certain
  Unicode separators were written through unescaped and were later read as real
  line breaks, which could silently add settings nobody typed. This affects both
  the Jamf Pro and Jamf School scaffolders.
- A monthly report schedule no longer tears itself down and reinstalls on every
  single run. The app wrote the schedule's date one way and read it back
  another, so it never recognised its own agent as unchanged.
- Changing the excluded-profiles list in Automation now takes effect. The app
  compared schedules by settings that did not include exclusions, so an
  exclusions-only change was accepted in the UI and never reached disk.
  Excluded profiles are also no longer listed in the overdue notification.
- The overdue notification now names which profile each late schedule belongs
  to. It evaluates every profile on the machine, but the detailed card listed
  bare schedule names — so on a multi-profile Mac there was no way to tell whose
  schedule was late. Fleet-wide schedules are labelled as such.
- Backups that finish with a partial export are now pruned by retention instead
  of accumulating, from both the app and the command line.
- Cached collection data is now written atomically, so a crash or a full disk
  mid-write cannot leave a half-written file behind for the next report to read.
- Unattended runs now report problems they previously swallowed: a failure to
  apply an automation change, a failure to rotate a log, and the case where a
  schedule is overdue but no profile has a webhook configured to say so.
- Error messages no longer tell you to check Run History for failures that
  never reach it — the command-line tool does not record there.
- The launch-time audit refresh can no longer start a second copy of itself.
  Switching profiles quickly at launch could kick off overlapping background
  audit runs of the same data; at most one now runs at a time.
- The device detail panel now shows every section instead of silently stopping
  at five — Policy History was the usual casualty on devices with rich data.
- The Getting Started checklist's "Set up a schedule" step now ticks under
  managed automation. It only counted a schedule built by hand for that exact
  profile, so operators using the recommended managed automation never saw the
  step complete. A profile excluded from managed automation still requires its
  own schedule to tick.

### Changed

- jamf-cli's daily "newer release available" check is switched off in every
  jamf-cli process the app launches. It could stall first-time setup for a
  couple of seconds on restricted networks, and update guidance in this app
  comes from Settings, not from mid-command hints.

### Removed

- The HTML report's Warranty section, and the `columns.warranty_expires`
  config key that fed it. Jamf Pro's API does not return purchasing or
  warranty data (jamf-cli declined sourcing it from GSX), so the section
  rendered an empty state on every tenant with advice that could not fix it.
  Warranty tracking needs a data source Jamf doesn't provide; the Asset
  template keeps its asset-tag, purchase-date, and location breakdowns.

## [2.6.0] - 2026-07-25

### Added

- Managed-device count history: Trends gains a "Managed Devices" metric
  charting the fleet's total computer and mobile-device counts over time, and
  Overview gains a matching tile with the computer/mobile split — so you can
  answer "how many managed Macs did we have on a given date?" from the app's
  own archived daily summaries (something Jamf Pro itself can't report).
  Computer counts are already present in every summary the app has ever
  written, so that history appears retroactively; mobile counts start
  recording with the first collect on this version.
- Duplicate-serial detection (jamf-cli 1.23+): collection now gathers the new
  `pro report duplicate-serials` data, and the Health Audit screen gains a
  "Duplicate serials" section listing the affected records (serial, record IDs,
  names, last contact). Duplicated serial numbers silently corrupt any report
  that joins device records by serial, so surfacing them is a data-integrity
  check. On older jamf-cli versions the section explains what it needs instead
  of rendering empty. jamf-cli's own `pro audit` duplicate-serials check also
  appears among audit findings automatically once the binary is updated.
- Metric-threshold webhook alerting (opt-in): a new `alerts:` config block defines
  rules like "FileVault below 90%" or "patch compliance drops more than 5 points
  week-over-week", evaluated against each scheduled run's daily summary. When a
  rule trips, an attention card posts to the existing `notify:` webhook — no rule
  tripped, no message. Off by default; requires the notify webhook.
- Scheduled-run dead-man switch: the app now notices when a scheduled run *should*
  have fired but didn't. Overview shows an "overdue" banner naming the schedule and
  when it last succeeded, the Automation screen gains an Automation Health section,
  and (when the notify webhook is configured) one overdue digest posts per day.
- Per-kind data freshness on operational screens: Patch, Security Posture, Updates,
  and Devices show compact chips with the age of each underlying data source, so a
  screen mixing fresh and week-old inputs no longer reads as uniformly current.
  Devices previously had no freshness surface at all and now also gets the
  "Collect now" banner.
- Snapshot integrity manifests are now written by the app: with
  `jamf_cli.require_manifest: true`, every collected snapshot is recorded in a
  per-kind `manifest.json` (SHA-256), making tamper detection in the Health Audit
  fully functional end-to-end.
- Webhook notifications are now configurable in the app: the Automation screen
  gains a Notifications section (per profile) with the enable toggle, Teams/Slack
  picker, webhook URL, payload-detail level, and a "Send test notification"
  button — no more hand-editing `notify:` in config.yaml (which still works).
- Patch velocity: adoption measured against release dates. The Patch screen
  gains a "Days Behind" column and a velocity card charting the five
  slowest-adopting titles' adoption curves with "days to 50% / 90%" figures,
  and reports gain a "Patch Velocity" sheet. Computed entirely from the dated
  patch history the app already collects — curves fill in as history
  accumulates; velocity figures are only shown when the crossing was actually
  observed, never estimated.

### Fixed

- A failing scheduled backup now says why. The exit code was recorded to disk on
  every run and never read back, so the Automation Health row could only ever say
  "Last run reported failure" — the cause was reachable only by finding the right
  log in Run History. The row now names the cause and its remedy in plain language
  (expired credentials, missing privileges, throttling), shows when the run
  failed, and offers a Run History button. The scheduled and command-line backup
  paths get the same plain-language explanation the Backups screen already showed.
- Scheduled backups no longer run against profiles that can't be backed up.
  `pro backup` is a Jamf Pro command, but the all-profiles backup schedule ran it
  for every profile including Jamf School ones, which failed every week and left a
  warning no action could clear — re-running produced the identical failure. Those
  profiles are now skipped with an explanation, and a skip is not a failure.
- A partial backup is no longer discarded. When jamf-cli reports partial success
  (some configuration object types exported, others refused), the exported subset
  is now kept and flagged as partial instead of being deleted and reported purely
  as a failure. Retention counts these, so they can't accumulate unpruned.
- Two backups finishing in the same second no longer collide, which previously
  deleted the completed backup and reported a failure.
- A failing scheduled backup now posts to the configured notification webhook.
  Backups returned before the notification step, so operators watching a webhook
  for unattended failures saw every collect failure and silence for every backup
  failure — silence that reads as success.
- The Automation Health row now says that a manual backup won't clear a managed
  schedule's failure, and to use Run now instead. The behavior was already
  deliberate; it just wasn't explained, so the obvious remedy looked broken.

- A single endpoint returning 401 can no longer be misread as expired
  credentials: before declaring authentication dead (the hard-fail that
  raises the Failing banner and asks you to re-authenticate), the collect now
  runs one `pro auth token` confirmation probe. If credentials are valid, the
  run completes with a clear warning naming the affected data kinds instead —
  the 401 is endpoint-specific (commonly a token expiring inside jamf-cli's
  long per-device commands on older versions). Genuine credential death
  behaves exactly as before. Failing scheduled runs are also now recoverable
  on the spot: failing or overdue managed schedules in Automation Health gain
  a "Run now" button that re-runs the real agent under its own identity, so a
  success genuinely clears the health state — previously a failed weekly
  schedule stayed red for a week with no way to retry it.
- Scheduled collects no longer report "server unreachable" — with a failing
  banner and a webhook alert — when the only data kinds that were actually due
  are ones that chronically fail (for example Platform-API kinds a tenant's
  API role can't access, or a command the installed jamf-cli doesn't have
  yet). If healthy kinds were skipped because their data was already fresh,
  that freshness is proof the server was recently reachable, so the run now
  completes as a normal partial outcome; and a "command doesn't exist"
  failure never counts toward an unreachable verdict at all.
- Automation Health no longer lets one profile's successful run hide another
  profile's failure of the same managed schedule: on multi-profile
  installations, each profile's screens now read that profile's own run
  status, so a genuine failure stays visible until that profile's next run
  succeeds. (The fleet-wide overdue digest keeps its across-profiles view.)
- Managed automation now repairs itself without the app: every scheduled run
  finishes by reconciling the managed LaunchAgents, so a machine whose agents
  were written by an older build (or deleted) is healed by the next run
  instead of waiting for someone to open the app. A running agent never
  reloads its own job (its plist is updated on disk and takes effect at next
  login), and the one-time RunAtLoad migration is now only marked complete
  when the rewrite verifiably succeeded, so a failed attempt retries.
- A batch of layout and copy fixes from field screenshots: the Devices filter
  control and the Generated / Run History / Backups header buttons no longer
  wrap letter-by-letter at narrow window widths; the Trends compliance
  headline no longer overlaps its delta badge; the compliance band legend
  only appears under the compliance band chart; stat-tile arrows now match
  the sign of their delta; Device Lookup no longer claims "no cached
  inventory" while inventory exists (its cache probe never refreshed after
  first render); and the workbook preview footer dropped a Python-era
  "matplotlib" mention and a wildly wrong size estimate.
- Buttons inside the Fleet Overview per-profile drill-down ("Open Trends",
  "Open Patch Compliance", and the other issue and Summary Details actions) did
  nothing since v2.3.0 (#203). The Overview screen's metric drill-downs had the
  same defect. Both pages kept their own navigation stack from before the
  v2.3.0 toolbar rework, which left it nested inside the app shell's stack —
  unsupported in SwiftUI — so the target screen rendered underneath the
  drill-down page instead of replacing it. Drill-downs are now plain
  state-driven pages; the breadcrumb returns to the parent screen as before.
- Fixed a crash that could take down the whole Patch screen (and the velocity
  report sheet) when the patch-release-dates snapshot contained two entries for
  the same title id — possible with duplicated patch title configurations or a
  sync-merged file.
- The daily digest now picks and ages cached snapshots by the timestamp in the
  snapshot's filename instead of the file's modification time, matching every
  other reader. On cloud-synced storage (iCloud/SharePoint), sync re-stamps
  modification times, which could make the digest report a data kind as absent
  — or serve older content — while the posture screens showed full data from
  the same folder.
- mSCP failure counts arriving as float-formatted strings ("3.0") from an audit
  EA now band correctly instead of being dropped to No Data; genuinely
  fractional counts ("3.9") are still rejected rather than silently truncated.
- The fleet patch-compliance average no longer counts titles with zero enrolled
  devices (some jamf-cli builds report those as a parseable "0%", dragging the
  average down).
- Patch adoption can no longer chart above 100% when jamf-cli double-counts
  devices across patch policies.
- A "drops more than" alert now compares against a summary genuinely as old as
  its lookback window. Previously, with sparse history it silently fell back to
  the most recent prior summary — firing a "7-day drop" rule on a 1-day wobble,
  or on a month-old baseline. With no old-enough summary the rule simply
  doesn't fire.
- Managed automation schedules no longer read as permanently overdue: the
  dead-man switch now finds the per-profile run records the all-profiles
  scheduled runs actually write, so a healthy managed setup stops producing a
  daily false "overdue" banner and webhook.
- A mistyped alert rule (unknown metric or operator, bad threshold) is no longer
  silently ignored: it's flagged in the Config Doctor's new Alerts checks, logged,
  and recorded in Run History. The doctor also warns when alerts are enabled
  without a usable webhook — previously that combination was total silence.
- Alert cards are no longer duplicated when two scheduled runs collect on the
  same day; each tripped rule now cards at most once per day (a rule tripping
  for the first time later the same day still alerts).
- A compliance "drops more than" alert no longer false-fires when the compliance
  measurement changes basis (the built-in proxy vs. real mSCP baselines) between
  the compared days.
- Headless deployments now get dead-man coverage: scheduled runs themselves check
  sibling schedules for overdue runs and post the once-daily overdue digest, so
  the switch no longer requires the app window to be opened. The once-per-day
  gate is shared with the app, and the day is only marked sent after a successful
  delivery (a failed send retries instead of silently skipping the day).
- Automation health re-evaluates when the Mac wakes or the app returns to the
  foreground, not just at launch — an ops console left open for days now notices
  a dead schedule.
- Freshness chips now show an explicit red "never" chip for a data kind the
  screen expects but that has never been collected, instead of the kind silently
  vanishing from the row (kinds intentionally skipped via "Skip expensive
  collections" are excluded). The chip row also wraps instead of overflowing at
  narrow widths.
- The Patch screen's velocity card and the "Patch Velocity" report sheet now say
  when release dates are unavailable (the `patch-release-dates` snapshot hasn't
  been collected) instead of showing bare "—" everywhere.
- A snapshot-manifest write failure under `require_manifest` is now an error in
  Run History naming the affected kind, instead of a buried log warning.
- Retention no longer counts `manifest.json` as a snapshot: it can't occupy a
  keep-count slot or be archived/deleted out from under integrity verification.
- A webhook URL typed just before closing the Automation screen is now saved
  (the debounced save flushes on dismissal).

- Update Jamf Pro credentials without Terminal: the Data Sources screen's
  Connection health card gains an "Update credentials" sheet (OAuth2 or
  Platform Gateway) for the active profile — for rotated secrets, expired API
  clients, or profiles first created with placeholder values. Secrets follow
  the same discipline as onboarding: entered into the system via jamf-cli
  only, never persisted or logged by the app, wiped on cancel.
- Jamf School-only districts get a real front door: the Welcome screen gains
  a "Connect Jamf School" card with its own onboarding path (no Jamf Pro
  credentials involved) ending in a first School workbook. Like the School
  CLI commands, this path ships community-validated — the maintainer has no
  Jamf School tenant to test against.
- Per-kind freshness chips now cover the remaining data screens — Policies &
  Profiles, Extension Attributes, Protect, and Mobile Fleet — completing the
  rollout that started with Patch, Security Posture, Updates, and Devices.
  Protect and Mobile Fleet only expect their kinds when the product is
  actually detected, so a Pro-only or Mac-only tenant never sees a false
  "never" chip.
- The webhook Notifications editor is now available in unmanaged mode too:
  the Schedules screen gains the same card the Automation screen has, so
  hand-built-schedule operators no longer have to edit the notify: block by
  hand.
- The `jamf-reports` command-line tool now participates in automation trust:
  `collect` evaluates metric alerts and posts the webhook digest like a
  scheduled snapshot run, `generate` posts its digest, both record into Run
  History, and failures post the failure card — so a self-managed cron or
  launchd job is no longer invisible. Exit codes and output are unchanged;
  the dead-man switch still tracks only app-written schedules (a cron job has
  no schedule for it to compare against).
- `jamf-reports scaffold` no longer requires a CSV: omit `--csv` to write the
  same minimal jamf-cli-only config the app's onboarding "Skip for now" path
  creates — a pure-CLI setup can now bootstrap a workspace headlessly.
- Truncated snapshot files in the `{"results": [...]}` envelope shape are now
  salvaged like bare-array files (complete rows recovered, day marked
  salvaged) instead of vanishing from charts entirely.
- A "drops more than" alert comparing against sparse history now prefers a
  prior summary that actually carries the rule's metric, so a data-absent day
  at the lookback boundary can't silently disarm the rule.
- Text no longer renders one character per line: the packaged app now bundles
  its monospace fonts correctly, so tracked headers, status chips, segmented
  controls, and timestamps render crisply instead of falling back to a wider
  system font that overflowed fixed-width controls.
- In-app guidance tips no longer render as an oversized empty box — each tip now
  appears inline beside the control it describes.
- Stale-device counts now agree across Overview, Fleet Overview, Devices, and
  Offline Outreach, and honor `thresholds.stale_device_days` everywhere
  (previously the Devices and Offline Outreach screens used a fixed 30 days, and
  the summary counted 0 when jamf-cli reported staleness under a newer field).
- The Devices FileVault tile now reports the true encryption rate instead of
  rounding a single unencrypted device away as 100% / "0 security gaps".
- Mobile Fleet classifies iPad vs iPhone by hardware model rather than OS
  family, so the per-device-type breakdown is no longer 0/0 on an iOS fleet.
- The mSCP compliance tile no longer wraps a long baseline label mid-word.
- The Trends relative-change figure no longer shows an absurd percentage (e.g.
  8200%) when the comparison baseline is at or near zero — it omits the
  parenthetical and shows the absolute change.
- The Generated screen header now reads "N reports" instead of "N reports
  archived" (these are generated outputs, not archives).
- The AI Insights card now names the model it will actually use — a config
  locked to on-device no longer claims Private Cloud Compute.
- The Overview automation-health banner and Getting-Started checklist no longer
  present fleet-wide or another profile's state as the active profile's own: the
  banner labels fleet-wide managed automation as "Managed automation (all
  profiles)", and "Set up a schedule" reflects a schedule for the current
  profile rather than the global managed-automation switch.
- The onboarding step progress no longer wraps step labels one character per
  line — the strip scrolls horizontally when the steps don't fit.

### Security

- Webhook cards can now be minimized for high-security deployments: new
  `notify.detail: minimal` sends event facts only ("2 alert rules tripped",
  "run failed", "1 schedule overdue") with no metric values, error text, or
  schedule names — the webhook becomes a doorbell, not a data channel. The
  default (`full`) is unchanged.
- The failure webhook's error text is now redacted (secrets and PII, including
  server hostnames) before it leaves the machine — previously a network error
  could embed the Jamf server address in the card.
- Webhook titles and facts are sanitized against Slack mention/link injection
  (`<!channel>`, `<@user>`, disguised links) across all card types.
- Hardened the new `alerts:` config parsing: a malformed rule (fractional,
  quoted, negative, or garbage threshold) can no longer break loading of the
  whole `config.yaml` — bad rules are dropped individually and decimal
  thresholds like `90.5` now work.
- Snapshot integrity manifests are excluded from every "newest snapshot"
  reader, so enabling `jamf_cli.require_manifest` can't cause the manifest
  file itself to be read as data.
- The Config Doctor now reports "EA coverage drift unavailable" (naming the
  reason, e.g. truncated snapshots) instead of a green "stable" row when it
  lacks the data to actually check.

### Changed

- "Active Devices" now means truly active: the Overview tile and Trends metric
  report managed devices minus stale ones (per your configured
  `thresholds.stale_device_days`), instead of duplicating the total. The tile
  says what it counts ("Checked in within Nd"); when staleness has never been
  measured the value honestly shows as unknown rather than overstating.
  Alongside the new Managed Devices tile, the pair now distinguishes "how many
  devices we manage" from "how many are actually checking in." A summary
  written earlier in the day also picks up the mobile-device count on the next
  collect instead of waiting for tomorrow.
- Tracks jamf-cli v1.25.1 (was v1.22.0). Updating the binary also enriches
  device drill-downs for free: MDM-command and policy history rows now carry
  completion dates and accurate command states (jamf-cli 1.23+). One upstream
  behavior change to be aware of: `--serial`-based lookups on a duplicated
  serial now error instead of silently picking an arbitrary record (the app
  itself resolves devices by ID and is unaffected). Everything added in 1.24
  and 1.25 is additive — new commands and flags this app doesn't call — so
  older binaries down to the 1.18 floor keep working.
- On macOS 26 and earlier the AI Insights surfaces (Overview card, Settings
  panel) are now hidden entirely instead of explaining that they need
  macOS 27 — the feature can never run there, so the app no longer
  advertises it. Nothing changes on macOS 27.
- Private Cloud Compute is no longer offered in Settings: it requires an
  Apple-granted entitlement tied to App Store distribution that official
  builds can't carry, so the model picker is replaced by a plain
  "On-device" row. Builds that do carry the entitlement (e.g. a qualifying
  fork) get the picker back automatically. On-device AI is unaffected.
- Cached data now has a shelf life: new `jamf_cli.max_cache_age_hours` (default
  168 — 7 days). When live collection fails and the newest cached snapshot is older
  than the limit, the daily digest reports that kind as absent (with a log line
  naming the age) instead of silently presenting week-old data as current. Set to
  `0` to keep the previous keep-forever behavior.
- Days recovered from truncated snapshot files ("salvaged") are now marked on the
  compliance band trend chart with a warning marker and excluded from EA
  coverage-drift comparisons, so a partially-recovered day never reads as a real
  fleet change.
- Managed data-collection schedules now catch up at login: the collect agents run
  when you log in, so a Mac that was asleep or logged out at the scheduled time
  gathers its data as soon as you're back — repeated logins do no redundant work
  (a collect that isn't due is skipped). Report and backup schedules stay on their
  calendar. These remain user LaunchAgents, so they still don't run while no user
  is logged in.

### Removed

- The dormant smart-group creation feature (the "Create smart group" affordances
  wired into the Outreach, Security Posture, Compliance Posture, and Updates
  screens). It depended on a jamf-cli smart-group-templates command that was
  proposed upstream but never shipped, so the buttons could never appear on any
  real installation. Removed entirely rather than left as dead weight; smart-group
  *reporting* (the read-only group inventory surfaces) is unaffected.

## [2.5.0] - 2026-07-06

### Added

- On-device AI fleet insights (macOS 27+, opt-in): a new `ai:` config block turns
  the daily fleet digest into a plain-language insight card on Overview, adds an
  "Explain this run" action for failed scheduled runs (analyzed on-device only,
  after full log redaction), and can prepend an AI executive-summary paragraph to
  GUI-generated reports. Off by default and completely inert below macOS 27.
  Model choice is Apple's on-device Foundation Model or Private Cloud Compute;
  `lock_on_device: true` refuses any non-on-device model for high-security
  environments. Settings gains an "AI Insights" panel.
- Multi-baseline mSCP compliance tracking: configure one baseline per OS (or per
  framework — CIS, DISA STIG, NIST) under `compliance.baselines`, and each gets its
  own compliance-band donut and Trends band series. A baseline picker appears on the
  Trends band charts when more than one baseline is configured.
- Data-accuracy review layer: per-EA parse health (how much of the fleet's data
  actually parses under each configured EA type, with privacy-safe samples of what
  doesn't), CSV-vs-snapshot device-count reconciliation and CSV freshness checks in
  the Config Doctor, and EA coverage-drift detection that flags an extension
  attribute whose fleet coverage suddenly drops between collects.
- mSCP failure counts are now validity-bounded: set `rule_count` on a baseline and
  counts above it (a broken EA script) are treated as No Data instead of banding the
  device High. An optional per-baseline `failures_list_column` enables a
  count-vs-list cross-check that reports devices whose two compliance EAs disagree.

### Changed

- Recovered (truncated) `ea-results` snapshots now announce themselves in the log
  ("salvaged N rows"), so a partially recovered day is never silently mistaken for
  a complete one in compliance-band history.
- Tracked jamf-cli dependency updated to v1.22.0. No code changes required for
  existing functionality. Notable upstream changes in v1.22.0:
  - New `pro jamf-protect-deployment-tasks retry-failed` command for retrying
    failed Jamf Protect deployment tasks by serial, management ID, UDID, or
    failure status. Future integration candidate for the ProtectView "Plans"
    card.
  - New `-o ndjson` line-delimited JSON output format for programmatic
    consumers. Existing `-o json` output used by the app is unchanged.
  - 403 error responses now surface the specific required Jamf privileges in
    the error detail — these flow through `CLIBridge.explainExit` exit-code-5
    handling and will appear automatically in remediation messages.
  - New `agent-context` command providing operating guidance for AI agents
    (exit codes, conventions). Not used by the app.
  - Determinate pagination progress for `--all` operations in interactive
    terminals; silent/piped mode is unchanged.

- The Extension Attributes screen no longer grades EAs by "coverage %". Extension
  attributes carry custom, often legitimately sparse data — a serial-number EA
  populating 11 devices means 11 Macs run that app, not a broken EA. The list now
  shows neutral devices-reporting counts (sortable by devices or name), and the
  coverage-percentage tiles and red judgment bars are gone. Sharp *drops* in an
  EA's own reporting base (a broken EA script) are still flagged by the
  coverage-drift check.
- The Health Audit no longer shows a standing "unverified snapshots" warning card
  for the not-yet-shipped snapshot manifest feature — no manifests are written
  yet, so every snapshot registered as unverified and the warning could never
  clear. It now shows a neutral note instead, and only warns when a manifest
  actually mismatches or a snapshot is corrupt.
- Config Doctor parse-health warnings for a percentage-typed EA whose values are
  mostly raw counts now name the likely cause (the EA is probably mistyped)
  instead of a generic "check the EA type or source column" hint.

### Fixed

- The Extension Attributes screen showed "0 devices" against jamf-cli data: device
  counting only recognized the legacy `computer_id` field, not the `device` field
  current snapshots carry. It now uses the same identity fallback chain as the
  mSCP compliance join.
- Historical mSCP band trends no longer render as a garbled single-color mass. Three
  fixes: truncated `ea-results` snapshots (cut off mid-write by a since-fixed
  collector bug) are now salvaged instead of discarded — recovering weeks of band
  history; days where a baseline has only No-Data are skipped instead of charting as
  zero; and the stacked band charts use a corrected rendering that stacks bands
  properly.
- The daily summary now uses the same robust `ea-results` decoder as the dashboards,
  so a malformed snapshot can no longer silently freeze the compliance figure on the
  4-control proxy value while Compliance Posture shows real mSCP data.
- Jamf School and Jamf Protect collects now validate CLI output is JSON before
  caching it, matching the Jamf Pro collect path.
- Scheduled tier-scoped collects (for example, the weekly scan tier) were being
  skipped whenever the day's freshness collect had already run and written a
  summary. The skip-if-already-collected-today guard now only applies to a full
  collect, so a tier-scoped collect always runs on its own schedule.
- The in-app log viewer showed "Couldn't read the log store" in signed builds. It
  now reads an in-app log buffer fed by live collect activity instead of the macOS
  log store, which fails with a generic error in signed, hardened-runtime builds.
- The AI Fleet Insight card could briefly show the previous profile's insight after
  switching profiles mid-generation. Insight updates are now discarded if the
  profile changes before generation finishes.
- The Config Doctor's data-accuracy checks could compare different snapshot days
  than the coverage-drift check on cloud-synced workspaces, and could pick up
  `manifest.json` as if it were a data snapshot. All of the accuracy checks now
  pick the newest snapshot the same way (by the date in its filename, excluding
  the manifest), so they always compare the same day.
- Compliance failure-count columns encoded as decimal numbers (for example,
  "2.0") no longer trigger a false "parses poorly" warning in the Config Doctor.
- Multi-baseline compliance trend history now survives renaming a baseline's
  display name — band history is additionally matched by the baseline's stable
  EA column, not just its display name.

### Removed

- Config keys that were never read by the app have been removed from
  `config.example.yaml`: the `inventory_csv`, `report_families`, `school`, and
  `sofa` sections, `jamf_cli`'s multi-profile and timeout keys,
  `experimental.protect_features_enabled`, and `platform.audit_platform`.
  (`school_columns` stays for now — the `school-scaffold` command still writes
  it; wiring a reader or retiring it together is a tracked follow-up.)

## [2.4.0] - 2026-06-25

### Added

- Consolidated fleet reports now emit a multi-sheet `.xlsx` workbook — Fleet
  Summary, Per-Profile Breakdown, Security Posture, Compliance, and Fleet Trend,
  with embedded charts — alongside the existing machine-readable CSV.
- A new included `jamf-reports` command-line tool. The app binary now doubles as a
  CLI — generate reports, collect snapshots, back up Jamf Pro config, run checks, and
  build redacted diagnostic bundles from Terminal or a script, using the same engine
  as the app. Install it from Settings → Command-line tool (no administrator rights
  required). Produces `.xlsx` and HTML reports; PDF remains a GUI feature.
- Settings → Diagnostics gains a **Logging** panel: turn on verbose (debug/info)
  logging, read recent log entries in the app — filter by level, time window, and
  search, with a redacted export — and reveal a bundled debug-logging configuration
  profile (`.mobileconfig`) for org-wide deployment via Jamf. Logs are split across
  eight categories for easier filtering in Console; private values (serials,
  hostnames, usernames) stay redacted by default.

### Changed

- Updated jamf-cli dependency tracking to v1.21.1 and added handling for exit code 7
  (partial failure, v1.19+): when some sub-operations fail but valid JSON is
  returned for the rest, the partial data is now saved with a warning instead of
  discarded. Backward-compatible — v1.18.x never emits exit code 7.
- Errors are clearer in the live refresh paths: a failed collect, refresh, generate,
  or backup now shows the `jamf-cli` cause and a fix (re-authenticate, grant API
  privileges, or wait when throttled) instead of a raw error string. A dashboard that
  reads a snapshot which exists but cannot be parsed now shows a distinct error state
  with a Retry, separate from the normal "no data collected yet" empty state.
- The consolidated fleet report now reports SIP %, Firewall %, and Gatekeeper %
  and no longer blends a single fleet-wide Compliance % across profiles.
  Compliance is reported per security baseline in the new workbook's Compliance
  sheet, because mSCP/STIG baselines (e.g. NIST 800-53 vs CIS) are not comparable
  when summed across different frameworks.

### Removed

- The standalone Python CLI engine (`jamf-reports-community.py`) and its test
  suite have been removed. The native macOS app is now the single report engine —
  all generation, collection, scheduling, and diagnostics run through it. macOS is
  the only supported platform.

## [2.3.0] - 2026-06-17

### Added

- The app now adopts macOS 26 (Tahoe) **Liquid Glass** for its window chrome:
  the title, sidebar toggle, jamf-cli status chip, and per-view search share one
  system toolbar that renders as Liquid Glass, with content refracting under it
  as you scroll. On macOS 14 and 15 this is a standard titled window — no change,
  and no new minimum OS.
- Data Sources gains a "Connection health" check (jamf-cli `doctor`): on demand,
  it diagnoses the active profile's credential resolution and runs a live server
  reachability probe, then shows a plain verdict (healthy, credentials
  unresolved, unauthorized, unreachable, or no profile) — useful when a collect
  returns 401 or no data.
- Diagnostic bundles now include a redacted `doctor.json` (resolved profile,
  credential-resolution state, environment, and server reachability) so a shared
  bundle carries the live connection context it previously lacked. The server
  hostname is redacted like every other PII field; credentials were already
  fingerprinted by jamf-cli.
- The Jamf Protect screen now lists configured Protect plans (threat-prevention
  strategy, log level, profile version, auto-update and telemetry state) — this
  data was already collected and in the workbook but wasn't shown in the app.
- The CSV → EA guide can now adopt a detected column as a **Security Agent**
  (not just a Custom EA): each candidate has an "Adopt as" choice, and Security
  Agent reveals a "Connected value" field (pre-filled, with guidance on what the
  value should be).
- Config errors are clearer everywhere: jamf-cli failures (reports, audit,
  backups, smart-group apply) translate the exit code into plain language with a
  fix (re-authenticate / grant API privileges / wait — throttled / check Run
  History) instead of showing a bare exit number; cadence, import, diagnostic-
  bundle, config-check and inbox errors now name the operation and a remediation.
- "Reveal in Finder" / "Open" now shows a toast when a path is outside the app's
  allowed folders instead of doing nothing; a chart export that fails now reports
  it.
- "Restore default config" and "Re-scaffold from CSV" now state exactly what will
  change (named counts, per profile) and how to rebuild.
- **Refresh data on demand, anywhere.** A new "Refresh all data" button in the
  window toolbar fetches every report immediately, and the "stale data" banner on
  each screen now offers a "Collect now" button that refreshes just that screen's
  data — previously the banner only offered to collect when nothing had ever been
  fetched, leaving stale pages with no way to update them.

### Changed

- **Collection cadence is now a single fixed schedule; the on-prem/cloud preset
  is gone.** Reports collect on the faster (former "cloud") cadence by default —
  twice-daily headline KPIs, inventory every two days, deep scans weekly — and the
  Settings/Onboarding preset picker has been removed. The goal is the freshest data
  the server can provide; a self-hosted Jamf Pro that struggles with the load
  should be given more memory. An on-demand refresh always fetches immediately,
  regardless of the scheduled cadence.
- The Overview "data is getting old" prompt now appears after 2 days (was 7), in
  line with the faster inventory cadence.

- **Re-scaffold from CSV now merges** into the active profile's config instead of
  overwriting it: empty column mappings are filled, mappings whose CSV column was
  renamed are repaired, and existing mappings, security agents, custom EAs and
  thresholds are kept. Safe to re-run as the CSV changes over time.

### Fixed

- Fixed a crash when adding then removing a Security Agent, Custom EA, or
  Compliance Benchmark row in Config.
- Fixed a recurring "Configuration file problem" error after adopting a
  percentage EA: an empty threshold was written in a form the report engine
  rejected. Re-saving the config from the app repairs an already-affected file.
- Fixed the jamf-cli status chip rendering a doubled background (a rounded
  rectangle nested inside the toolbar pill) on the macOS 26 Liquid Glass toolbar.

## [2.2.2] - 2026-06-12

### Added

- The Fleet Overview "N Issues" badge now opens a popover listing each flagged
  profile and exactly what tripped it; clicking a profile opens its drill-down,
  which gains an "Issues on this profile" card explaining every condition and
  linking to the screen where it can be acted on.
- Health Audit findings gain "Take action" buttons that open the screen holding
  the records behind the finding (Security Posture, Offline Outreach, Policies &
  Profiles, …) plus a shortcut to Generated reports for per-device detail.
- "Collect now" is available on every snapshot-driven screen's data banner
  (OS Updates, Patch, Extension Attributes, Policies & Profiles, Mobile Fleet,
  posture and trends screens) — empty states no longer point at a refresh
  button that didn't exist.
- Data Sources explains snapshot archive families (summaries plus dated CSV
  archives) and no longer renders empty filler rows under the table.
- Overview, Trends, and Fleet Overview now carry a provenance chip stating that
  their numbers come from the once-a-day summary digest (with its date), and —
  when the digest was built from cached or missing sources — say so instead of
  letting stale data wear a fresh date. Each daily summary now records where
  every input came from (live, cached, or absent), in both engines.
- New wiki page, Data Provenance, documents the three data tiers (per-device
  records, server-side aggregates, daily digest) and every screen's data source.

### Changed

- Unknown is no longer reported as zero. When device check-in data was never
  collected, the stale-device count is omitted (shown as "—") instead of a
  false "0 stale devices", in both engines. The Stability Index drops
  unmeasured components and renormalizes over what was actually measured, and
  security controls the report marks NOT_COLLECTED no longer count as failing
  in the compliance proxy — a partially-collected tenant no longer reads as 0%
  compliant. Trend values can shift on fleets where data was previously
  missing; the new numbers reflect measured data only.

### Fixed

- Clicking Profiles in Policies & Profiles crashed the app (issue #185). The screen
  decoded the `profile-status` report against a data shape jamf-cli never produces,
  creating a phantom row whose identity changed on every read — fatal to the table
  on recent macOS. The tab now reads the real report and shows per-profile
  installation failures (errors, devices affected, most common error), matching the
  Excel report's Profile Status sheet. A tenant with no failures shows a healthy
  state instead of an empty one.
- The Fleet Overview "N Issues" badge now explains itself (issue #184). Clicking it
  opens a popover naming each flagged profile and what tripped it (stale devices,
  FileVault below 90%, patch below 80%, low stability), and each flagged card
  carries the same reasons with a link to the screen where they can be acted on.
- Finishing the existing-jamf-cli setup no longer reports success when a scheduled
  automation agent failed to install — a warning toast points at the Automation tab.
- "Collect now" and setup-screen collections now write a Run History entry, so the
  "see Run History" guidance in their failure messages leads to the actual
  per-command output instead of an empty list.
- Restoring the default config now always names the `config.yaml.broken-<timestamp>`
  backup in its error message, even when reseeding fails partway.
- A missing config.yaml is reported as "file not found" instead of "may be corrupt".
- Collecting macOS configuration profiles called a jamf-cli command that no longer
  exists (`classic-macos-profiles` was renamed `classic-macos-config-profiles`
  upstream), which silently saved jamf-cli's help text as the snapshot. The app now
  calls the current command and refuses to save any snapshot that is not JSON, so a
  future rename degrades to a warning instead of poisoning the cache.

### Security

- Inventory CSV export now refuses to write into system or sensitive home
  directories, matching the guard PDF export gained in 2.2.1.

## [2.2.1] - 2026-06-10

Patch release focused on the first-launch experience for admins who already use
jamf-cli (issue #181), plus security hardening from the post-2.2.0 review.

### Added

- Setup screen for existing jamf-cli users. If jamf-cli profiles exist but the app
  has no workspaces, first launch now walks through workspace setup, automated scan
  scheduling, and a first collection — with live per-command progress. It re-offers
  if all workspaces are later deleted; skipping it is permanent.
- "Collect now" button on the "No live data fetched yet" banner. Collect failures
  surface as a toast instead of failing silently in the background.
- Config recovery. An unparseable config.yaml now shows the exact problem location
  (e.g. `charts.compliance_trend.bands[0]: missing 'label'`) with "Open config.yaml"
  and "Restore default config" actions. The old file is always kept as
  `config.yaml.broken-<timestamp>`.

### Fixed

- Every workspace the app created failed "config.yaml could not be parsed" when
  generating a report: the built-in YAML reader could not read the flow-style
  compliance bands in its own seed file. Flow-style YAML now parses.
- A brand-new workspace had no way to run the per-device collections — the
  "Refresh now" prompt only appeared once week-old data already existed. It now
  appears for never-collected data too, and says "couldn't be collected in the
  last run" instead of "missing" when the tenant returned nothing.
- Collect-failure messages no longer blame credentials for non-auth errors.
- The scheduled-report GitHub workflow was invalid since 2.2.0 and logged a failed
  run on every push.

### Security

Post-release security review of 2.2.0 (Anthropic Claude, Fable 5, multi-agent);
all findings addressed:

- A collect where every live jamf-cli call fails now aborts loudly instead of
  reporting success from stale cache — both engines, including Jamf School.
- Failed scheduled runs now post to the optional Teams/Slack webhook, and partial
  report generations are recorded in Run History instead of passing silently.
- Python engine parity with the app: locked-down jamf-cli subprocess environment,
  0600 LaunchAgent plists, webhook URL redaction, and same-day trend-summary
  upgrades when a re-run produces better data.
- Path confinement: archive directories stay inside the workspace, snapshot
  symlinks cannot escape their directory, PDF export refuses sensitive paths, and
  diagnostic bundles are written 0700/0600.
- Supply chain: Swift dependencies pinned via committed Package.resolved,
  hash-pinned Python installs in CI, shellcheck on all build scripts, and
  jamf-cli code-signature verification before credentials reach it.
- All committed test fixtures replaced with fully synthetic data.

## [2.2.0] - 2026-06-08

### Added (v2.2.0 cycle)

- Multi-product onboarding: the Jamf Pro connection step offers Standard
  OAuth2 or Platform Gateway authentication (account.jamf.com API client +
  tenant ID — unlocks Blueprints, Compliance Benchmarks, and DDM Reports). A
  new optional "Add Products" step connects Jamf Protect (OAuth2) and Jamf
  School (Network ID + API key); both can also be added later from the
  Sources screen. All credential prompts run through jamf-cli's guided setup
  with the same keychain-backed security model as Jamf Pro.
- OS Currency reporting via the [SOFA](https://sofa.macadmins.io) feed: both
  engines now know the latest available macOS, iOS/iPadOS, tvOS, and watchOS
  versions (version, build, release date, days since release, actively
  exploited CVE count). A new "OS Currency" sheet/section joins this against
  the fleet — devices on the latest release, devices behind, and a red
  "Out of support (EOL)" row for devices older than every supported release.
  The app's Updates screen shows the same latest-version data. SOFA fetches
  are cached and degrade gracefully offline; a `sofa:` config block controls
  the feed (disable for air-gapped servers).
- Patch release dates: collection now captures each patch title's latest
  version release date (`jamf-cli pro patch-software-title-configurations
  definitions`). The Patch Compliance sheet and the app's Patch screen gain
  "Latest Released" / "Days Behind" columns — groundwork for adoption-lag
  trend charts.
- mSCP/STIG compliance real banding: when a `compliance.baselines` entry
  maps an EA column containing per-device failure counts, both engines derive
  real pass/low/medium/high distribution bands instead of the four-control
  proxy (FileVault/SIP/Firewall/Gatekeeper). New "mSCP Compliance" and
  "Compliance Trend" workbook sheets display band donuts and trend stackplots;
  the Compliance Posture screen shows real band distribution and per-device
  pass/fail status.
- Mobile-device CSV scaffolding: `scaffold` (Python CLI) and "Re-scaffold from
  CSV" / onboarding (app) now detect whether a CSV is a Jamf Pro computer or
  mobile-device export and populate the matching column mappings (`columns:`
  or `mobile_columns:`) — never both. Mobile exports get their own column
  hints (Display Name, OS Version, Jailbreak Detected as a suggested EA, …).
- Scheduled configuration backups: a new "Configuration Backup" schedule mode
  runs `jamf-cli pro backup` on a cadence, keeps the newest 10 scheduled
  backups, and sweeps abandoned backup staging folders. Backup runs appear in
  Run History like any other schedule.
- Overview score cards are no longer capped at 4 — choose any combination of
  the 9 metrics, and the selection now persists across launches.
- Launch freshness sweep: per-device data (Patch / Updates / EA results) older
  than a week surfaces a "Refresh now" prompt on the Overview screen, and
  Health Audit data older than a week refreshes automatically in the
  background. Heavy collections never run without the prompt's button —
  on-prem servers are not hammered at launch.
- "Include Health Audit" toggle in the Generate flow (both the Generate sheet
  and the Overview quick-generate): runs `jamf-cli pro audit` before
  generating so audit-derived report content is current.
- Exports and reports now carry a tenant + timestamp in every filename:
  `patch-compliance-<profile>-<date_time>.csv`,
  `report_<profile>_<date_time>.xlsx`, etc. Exports a second apart no longer
  overwrite each other, and reports remain attributable outside their
  workspace folder.
- Report sidecar archives: Excel, HTML, PDF, and CSV reports now write
  accompanying `.sha256` and `.manifest` metadata files for integrity checks and
  run attribution.
- Smart Groups and Computer/Mobile Groups collection: a new `groups` collection
  kind fetches jamf-cli 1.18+ smart-group templates and group lists (smart and
  static), fixing a stale-data issue where Group Hygiene and Computer Group
  Inventory sheets vanished on fresh profile installs awaiting first collect.
  Groups is included in the Standard collection tier.
- Per-sheet "Data as of" dates: every workbook sheet now displays the
  collection timestamp of the snapshot it reads (or empty state if the kind is
  missing), so stale data is visually identifiable without checking the
  report filename.
- First-run-of-day summary.json: when `summary_<today>.json` already exists,
  the collect step upgrades a stale proxy summary (4-control mSCP proxy) to
  real mSCP banding if a baseline EA is now configured.
- Managed automation ("set policy, not cron jobs"): a new **Automation** screen
  replaces hand-built per-profile schedules with a small set of global policies.
  Turn on "Manage automation" and the app keeps every profile's jamf-cli data
  fresh daily (everything except the two heavy per-device scans), runs a weekly
  deep scan, generates reports on your chosen cadence (Off / Daily / Weekly /
  Monthly), and optionally takes a weekly configuration backup — all across
  every profile, adjusting automatically as profiles are added or removed (the
  agents resolve the profile set at run time). A shared run time staggers the
  jobs so on-prem Jamf Pro isn't hit all at once, and a per-profile exclusion
  list skips a dummy/test tenant. **Off by default** — existing schedules are
  untouched until you opt in.
- Catch-up-on-wake: if a Mac sleeps through the scheduled run, the app collects
  the day's freshness snapshot on the next launch or wake (once per calendar
  day), so Trends and reports don't silently fall behind on laptops.
- Opt-in webhook digest: a scheduled run can post a short "report generated"
  summary to a Microsoft Teams **or** Slack incoming webhook. Configure it under
  `notify:` (provider + https URL) in config.yaml — **off by default**; the
  Python CLI also accepts `--notify <url>` as an override.
- Report groups + consolidated fleet report: group profiles together (combine
  prod/dev/sandbox into one "fleet", or make one group per customer) and each
  group emits a consolidated report — aggregated KPIs with **period-over-period
  delta columns**. Percentages are device-weighted across the group; counts are
  summed. Profiles in no group keep their per-profile report.
- Version-floor preflight: a scheduled run now aborts loudly (with a clear Run
  History entry) when the installed jamf-cli is below the supported floor,
  instead of silently writing data from an unsupported binary.
- `--exclude-profiles` (app `--all-profiles` runner) and `--multi-exclude`
  (Python `multi-launchagent-run`) skip named profiles from a multi-profile run
  at run time; the Python multi-runner also forwards `--tiers`.
- Admin-controlled snapshot retention (`retention:` config, both engines):
  **off by default — raw snapshots are kept indefinitely** (they're a reporting
  input for per-device history, and `~/Jamf-Reports` often lives on cloud
  storage). When enabled, `mode: archive` (default) **moves** old snapshots to
  an archive folder — still on disk, you decide whether to trash them — and
  `mode: delete` removes them. Tunable by age (`snapshot_keep_days`) and/or
  newest-N (`snapshot_keep_count`); trend summaries are never touched unless
  `include_summaries: true`. The sweep now runs once/day on every collect path,
  including headless scheduled runs.

### Changed (v2.2.0 cycle)

- Snapshot cleanup is now opt-in. Previously the app deleted raw snapshots older
  than 90 days, but only while it was open. It now keeps everything by default
  and only archives/deletes when you enable `retention:` — so per-device raw
  history (e.g. mSCP day-over-day) survives, and headless servers no longer grow
  unbounded once retention is configured.

- The **Schedules** tab is now **Automation** — the global policy screen above.
  (Migration that consolidates any existing hand-built schedules into the new
  model lands in a follow-up; until then existing schedules continue to run.)

- Stability Index and Compliance Benchmark now compute on jamf-cli-only
  tenants: missing components drop out and the remaining weights renormalize
  (the same approach the Security Score uses). The Compliance Benchmark trend
  is fed by a control-gap proxy (FileVault/SIP/Firewall/Gatekeeper), labeled
  as a proxy in the UI until a real compliance EA is configured.
- "CrowdStrike Installed/Connected" labels are gone: the EDR metric is named
  after your configured `security_agents` entry (e.g. "CrowdStrike Falcon
  Installed"), or the generic "EDR Agent" when none is configured.
- The per-device risk model's "Nessus Disconnected" factor is now a
  config-driven "Security Agent Disconnected" check: it reads the EA column
  and connected value from your first `security_agents` entry, labels the
  finding with that agent's name, and — for the first time — actually
  triggers when the agent reports disconnected. With no agent configured the
  factor stays dormant.
- OS Updates KPIs no longer report "0 failing plans" when the failure scan
  simply hasn't run — the count derives from plan states (matching the donut)
  and Error Devices shows "—" until a `--scan-failures` snapshot exists.

### Fixed (v2.2.0 cycle)

- Onboarding's Continue button now enables while typing the client secret —
  previously the secure field only registered its value after pressing
  Return or clicking away, leaving the button greyed out (RC1 feedback).
- Jamf Pro 11.28 computer CSV exports were detected as mobile-device exports
  in both engines (Jamf added `Managed`/`Supervised` to computer exports),
  generating Mobile Device Inventory/Stale sheets and silently skipping
  Security Controls and Compliance. CSV family detection now counts
  family-unique header discriminators (Computer Name, JSS Computer ID,
  FileVault 2 Status, … vs Display Name, JSS Mobile Device ID, IMEI, …) and
  no longer depends on which config sections are filled in.
- Jamf "export-only field" CSVs (multi-value Applications / Certificates /
  Groups / Printers data) inflated device counts: each multi-value item adds
  a continuation row with a blank identity cell, so a 97-device export counted
  as 607 devices in Security Controls percentages. Continuation rows are now
  dropped at load with a warning, in report generation, column checks, trend
  charts, and Fleet Drift comparisons.
- `scaffold` mapped `last_checkin` to "Last Inventory Update" even when the
  export contains "Last Check-in" — exact-match ties now follow hint priority
  order, so the MDM check-in timestamp wins over the inventory recon date.
- Corrupt `config.yaml` files written by pre-May-2026 GUI builds
  (`security_agents: []` followed by orphaned entries) are repaired on load
  and healed on the next save. Previously every config section after the
  corruption point was silently ignored.
- "Export Findings" on the Health Audit screen silently did nothing when the
  chosen folder was outside Documents/Downloads/Desktop. Save-panel choices
  are now honored everywhere, and write failures show an error.
- Run History now records native scheduled and manual runs (it previously
  only saw legacy Python-era logs), and the Schedules screen's "Last Run"
  column populates after each run.

### Added

- In-app diagnostic bundle: Settings → Diagnostics gains a "Generate diagnostic
  bundle now" button that builds the redacted diagnostic zip natively (no
  Terminal, no bundled-script execution) under
  `~/Jamf-Reports/<profile>/diagnostics/` and reveals it in Finder. Redaction
  matches the Python `diagnostic-bundle` command: credentials are always
  redacted, and hostnames/serials/emails/device names/usernames are replaced
  with stable `<kind>-<hash>` placeholders (random per bundle). The existing
  "Copy Diagnostic Command" clipboard flow is unchanged.
- Executive Summary: the Excel workbook now leads with an "Executive Summary"
  sheet, and the HTML instance report opens with a matching top card row. Both
  show headline fleet KPIs — total devices, a weighted security score
  (FileVault/SIP/Firewall), FileVault/SIP/Firewall/Gatekeeper percentages,
  fleet patch compliance, and active/stale device counts. These are pure
  aggregations of data the report already fetches (no new jamf-cli calls); rows
  whose source is absent are omitted so partial-data runs still produce a useful
  summary.
- jamf-cli capability matrix: the Data Sources screen shows which jamf-cli
  commands the app relies on are present in your installed version, parsed from
  `jamf-cli pro --help`. The `capabilities` CLI command gains a matching
  `jamf_cli_runtime` section.
- Stale-device outreach CSV: Offline Outreach can export a formula-injection-safe
  mail-merge CSV (device, serial, user, email, last check-in, tier).
- Generated reports: a toolbar search field, a profile/tenant filter, and
  Space-bar Quick Look on the Generated screen.
- Schedules: each row shows a plain-language summary of its run mode and cadence,
  plus a "Re-save to migrate" nudge for pre-PR-20 LaunchAgents whose meaning
  changed at PR-21.
- Keyboard navigation: Cmd-1..9 switch jamf-cli profiles; Cmd-[ / Cmd-] move
  between visible sidebar tabs.
- The stale-data freshness banner now also appears on the Extension Attributes,
  Audit, and Health Check dashboards.
- jamf-cli 1.18 support: adopts the `computer-groups-smart-groups` command rename
  (on-disk snapshot keys unchanged), version-gates `--no-hints` /
  `--no-version-check` on automated runs so older binaries keep working, surfaces
  the spec API version in Settings, and raises the minimum supported jamf-cli to
  1.18.0.
- Group & search reporting (jamf-cli 1.18): three new workbook sheets — "Advanced
  Mobile Searches", "Computer Group Inventory" (smart and static groups, adding the
  static-group visibility the modern smart-groups API omits), and "Mobile Device
  Groups" — plus a toggleable "Groups & Searches" tab in the app. Each is gated on
  the command being present in your installed jamf-cli, so older binaries degrade
  gracefully.
- "Full Instance Report" template: a new template containing every workbook sheet
  and every HTML section, now the default for app report generation. Executive and
  the other focused templates remain available in the picker.
- Custom report template: the Generate sheet now offers a "Custom" template picker
  where you select which sheets to include in a single-sheet or subset report. The
  selected sheet list persists across launches, so repeat jobs use your preferred
  subset automatically.
- Five workbook sheets ported from the Python engine: Patch Summary Dashboard,
  Mobile Supervision Status, Device Security State, Protect Plans, and Protect
  Threat Overview.
- Two HTML report sections ported from the Python engine: Cleanup Analysis
  (disabled policies, unscoped policies/profiles, unreferenced packages/scripts)
  and Timeline (FileVault/SIP/compliance history from archived snapshots).
- The app's collect now also fetches categories, classic iOS profiles, device
  enrollment instances, mobile device inventory details, and Protect plans, so
  the corresponding report sections have data.
- PDF and inventory CSV are selectable output formats in the Generate sheet,
  alongside XLSX and HTML, and the sheet lists exactly which files the current
  selection will write.
- Trends and posture comparison charts show a dot at every data point instead of
  only on hover, and chart PNG exports prefill the filename with the profile name
  and date (e.g. `dummy-Security-Score-2026-06-01.png`).

### Changed

- Accessibility: empty-state actions are announced to VoiceOver, Extension
  Attribute rows are keyboard- and VoiceOver-reachable, and serif KPI numerals
  scale with Dynamic Type.
- Trends chart visuals: removed the colored glow behind the hero metric and
  softened the gradient fill under trend lines so sparse data no longer renders
  as a solid block.
- The Generate sheet defaults to XLSX only (previously XLSX + HTML), and the
  Overview "Generate Report" button skips the collect step when snapshots are
  less than an hour old.
- Compliance labels: the app no longer hardcodes "NIST 800-53r5 Moderate" as the
  compliance metric name. The default label is "Compliance Benchmark"; workspaces
  that set `compliance.baseline_label` or `platform.compliance_benchmarks` in
  config.yaml see their configured benchmark name throughout the app.
- Collect failures during generation now report how old the cached data being
  used is, and fail outright when no cached data exists instead of writing an
  empty report.

### Fixed

- The app's HTML report rendered most sections empty because it loaded cached
  snapshots under names the collector never writes (computers-inventory vs
  computers, classic-policies vs policies, computer-smart-groups vs
  smart-computer-groups). Sections now load the canonical names, fleet-inventory
  sections read the real nested computers-list shape, and sections with no data
  show an explicit "No data — run Collect" placeholder instead of vanishing.
- The Generated reports list showed 0 devices for every report; it now reads the
  device count from the run's summary snapshot.
- Concurrent GUI report runs for the same profile are blocked with a clear
  message, and the toolbar refresh button is debounced.

- `diagnostic-bundle` now collects trend summaries from the configured
  `charts.historical_csv_dir`/summaries directory (where they are actually
  written) instead of a hardcoded `snapshots/computers/summaries` path that
  did not exist — the Python bundle previously included zero summaries in most
  deployments. Brings it to parity with the native in-app bundle.
- Hardened several silent-failure and security paths: diagnostic-bundle token
  redaction, export-CSV path-traversal and formula-injection neutralization,
  LaunchAgent task cancellation, and corrupt-snapshot logging.
- The Schedules profile filter no longer overflows and overlaps the warning
  banner at narrow window widths.

## [2.1.0] - 2026-05-28

### Accessibility

WCAG 2.2 Level AA fixes across the macOS app and the HTML instance report.

macOS app:

- Increase Contrast is now honored for secondary text on every screen. Previously
  only a few components responded, leaving below-AA contrast on the Config,
  Settings, and several other screens.
- Dynamic Type: the app's text now scales with the system Larger Text setting.
  Pinned font sizes were replaced with scalable text styles across every screen,
  the shared `Theme.Fonts` token layer, the IBM Plex Mono text used for
  timestamps, table cells, and identifiers, and the shared button and
  section-header components. Chart axis labels and KPI numerals scale too;
  fixed-size graphical gauges stay pinned by design.
- Reduce Motion now suppresses the settings toggle animation.
- VoiceOver: decorative icons are hidden from the reader, charts expose
  descriptive labels, and live run status is announced as it updates.

HTML instance report (Python CLI and macOS app):

- Added a "Skip to main content" link, a print stylesheet that hides the toolbar
  and interactive controls, and reduced-motion support for animated elements.
- Wide tables now scroll horizontally instead of clipping on narrow viewports.
- The dark-mode toggle reports its state, sortable headers report sort direction,
  and per-row open links carry distinct labels for screen-reader link lists.
- Fixed category disclosure buttons that did nothing when clicked — they were
  missing the aria-controls wiring the expand/collapse script depends on.

### Added

- **First-launch chooser** (macOS app): on a truly fresh install the app
  now opens a "Welcome to Jamf Reports" screen with two side-by-side
  cards — "Connect Jamf Pro" (runs the onboarding wizard) and "Try the
  demo first" (loads synthetic data). Replaces the previous behaviour of
  silently flipping into demo mode whenever no jamf-cli profiles
  existed. The decision is persisted, so subsequent launches skip the
  chooser. Existing users who never explicitly toggled demo mode will
  see the chooser once on next launch.
- **Skip the first report from onboarding** (macOS app): the final step
  of the wizard now offers a "Skip & finish setup" affordance next to
  the Run-now button. The workspace is already fully configured by the
  time this step renders, so skipping is safe — reports can still be
  generated later from the Reports tab.
- **Compliance Benchmarks dashboard** (macOS app, experimental — Platform API
  required): new Posture-group screen browses cached
  `pro report compliance-rules` and `compliance-devices` snapshots with a
  pass/fail/unknown donut, per-rule failure bars, and a device table. The
  screen renders a locked empty state with setup guidance when either
  `experimental.platform_features_enabled` is off or the active jamf-cli
  profile is not configured with `auth-method: platform`. Toggleable via
  Settings → Sidebar Visibility.
- **DDM Blueprints dashboard** (macOS app, experimental — Platform API
  required): new Operations-group screen browses cached
  `pro report blueprint-status` and `ddm-status` snapshots. Surfaces a
  blueprint adoption-rate donut with deployed / not-deployed / failing /
  pending breakdown, a top-failures blueprint table, and a per-source
  declaration table sorted by unsuccessful declarations. Locked empty
  state with setup guidance is shown when either
  `experimental.platform_features_enabled` is off or the active jamf-cli
  profile is not configured with `auth-method: platform`. Toggleable via
  Settings → Sidebar Visibility.
- **`capabilities` command exposes experimental gate metadata** (Python CLI):
  the JSON manifest now includes an `experimental_features` section that
  lists the config keys, capability probes, and surfaces gated by each
  experimental flag. The text output adds a matching summary line.
- **Jamf Protect Deep Dive [Experimental]** (Python CLI and macOS app):
  opt-in deep-dive surfaces for tenants running Jamf Protect. Toggle
  via Settings → Experimental Features (`experimental.protect_features_enabled`
  in `config.yaml`). The Python CLI gains a "Protect Threat Overview"
  workbook sheet (severity-sorted triage list) and a "Jamf Protect"
  HTML report section (threat-event categories, severity distribution,
  endpoint agent versions). The macOS app's Protect screen adds a
  kill-chain stage breakdown, a per-device alert timeline, and an
  endpoint agent version distribution chart, plus a locked empty state
  and "Experimental" badge when the flag is off. All gated paths
  silently skip when the flag is off or no Protect tenant is reachable.

### Changed

- **Platform API features now require both `platform.enabled` and the
  experimental gate** (Python CLI, macOS app): in v2.0 only
  `platform.enabled: true` was required to write the Platform Blueprints,
  Platform DDM Status, and benchmark compliance sheets. v2.1.0 also
  requires `experimental.platform_features_enabled: true` AND a jamf-cli
  profile with `auth-method: platform`. All three checks must pass; any
  one failure logs `[skip] Platform API gate closed` and produces no
  Platform sheets. Upgraders who relied on `platform.enabled: true` alone
  must flip the experimental flag.

- **"Add connection" in Settings opens the onboarding wizard** (macOS
  app): the button under jamf-cli → Connections no longer opens Terminal
  and copies a `jamf-cli config add-profile` command to the clipboard.
  It now navigates straight to the onboarding flow inside the app so
  every profile-add path uses the same GUI wizard.
- **Overview is the new default landing tab** (macOS app): after
  onboarding or on subsequent launches the app opens on Overview rather
  than Trends. Trends only renders meaningful data after two scheduled
  runs, so a freshly-onboarded workspace previously landed on a "No
  trend data yet" screen.
- **Minimum Python is now 3.11** (was 3.9). The Python CLI requires
  `pandas>=3.0`, and pandas 3.0 dropped support for Python 3.9 and 3.10.
  CI now tests Python 3.11, 3.12, and 3.13.
- Bumped `pandas` to 3.0. Regenerated `requirements.lock.txt` and
  `requirements-dev.lock.txt` against the Python 3.11 floor; the pinned
  set no longer includes the `exceptiongroup`, `importlib-resources`,
  `pytz`, `typing-extensions`, and `zipp` backports that older Python
  versions required.
- **Stale-data banner now appears on five more screens** (macOS app): the
  Policies & Profiles, Compliance Posture, Security Posture, Mobile Fleet,
  and Protect screens now show the cached-data banner — the same one the
  Trends screen already displayed — when their snapshot is older than the
  freshness window.
- **Policy/Profile and Update tables rebuilt as native tables** (macOS
  app): the config-findings and profile-status tables on the Policies &
  Profiles screen and the failed-plans and error-devices tables on the
  Updates screen now use SwiftUI's `Table`, giving consistent row chrome
  and correct VoiceOver table navigation.
- **Clearer Sources scope wording** (macOS app): the profile scope control
  no longer describes "Full Admin" in terms that read like a server-side
  Jamf privilege grant; the wording now states it unlocks destructive app
  operations for the profile, stored locally.
- **Mobile Fleet device count** (macOS app): the Mobile Devices section
  header drops the count line when all devices are shown, matching the
  other paginated tables.

### Fixed

- **`runAndCapture` could drop the tail of a `jamf-cli` response** (macOS
  app): the capture continuation resumed as soon as the process terminated,
  without waiting for the stdout pipe to reach EOF. Under load a final
  unread chunk could be lost — collapsing a structured JSON response to a
  truncated or empty payload. It now resumes only once stdout EOF and
  process termination are both observed.
- **Spurious matplotlib legend warning** (Python CLI): the device-state
  trend chart called `legend()` on its single-snapshot bar path, where no
  series carries a label, printing `UserWarning: No artists with labels
  found to put in legend`. The legend is now drawn only on the multi-
  snapshot path that has labelled series.

## [2.0.0] - 2026-05-20

### Added

- **Patch Summary Dashboard** sheet (Python CLI): management-facing overview
  combining fleet activity (active/inactive device counts and ratio) with patch
  compliance metrics — title count, average adjusted completion, compliance
  distribution tiers, and a Top 10 Critical Patches table sorted by lowest
  adjusted completion %.
- **Release Date column** in the Patch Compliance sheet (Python CLI): pulled from
  `jamf-cli pro patch-software-title-configurations patch-summary` for each title.
  Summaries are fetched in parallel (up to 10 concurrent subprocesses) and cached
  to `jamf-cli-data/patch-summaries/`. The column is omitted gracefully if the
  endpoint is unavailable; `collect` now includes patch-summaries in its run.

- **Standalone Patch Compliance CSV export** (PR-25, macOS app): the Patch
  screen's Patch Titles card gains an "Export CSV" action beside the
  existing PNG export. It writes every tracked patch title in collected
  order with the same column shape as the workbook's "Patch Compliance"
  sheet (Title, Latest, On Latest, On Other, Total, Compliance %). Field
  values are formula-injection-neutralized, matching the xlsx export path.

- **Per-report collection cadence — GUI layer** (PR-23, macOS app):
  Surfaces the PR-22 cadence engine in the app so operators never hand-edit
  `config.yaml`.
  - **Settings → Performance** — a new card with an On-prem / Cloud / Custom
    preset picker. Each option shows its resolved per-tier cadences
    ("Refresh: Daily · Inventory: Weekly · Scan: Weekly"); switching presets
    prompts a confirmation noting scheduled runs adopt the new cadence on
    their next fire.
  - **Custom per-report editor** — when the preset is Custom, the card
    expands to a per-report table: each jamf-cli report gets a tier (or
    Never) selector and a cadence picker, seeded from the previous preset's
    defaults so switching to Custom is a starting point, not a blank slate.
  - **Schedules form tier picker** — the New Schedule sheet gains a Tiers
    multi-select (Refresh / Inventory / Scan). The selection persists in the
    LaunchAgent plist via a `--tiers` flag and round-trips back; legacy
    plists without the flag keep their all-tiers behavior.
  - **Onboarding preset prompt** — the Workspace step asks whether the Jamf
    Pro instance is on-prem or cloud and stamps the choice into the new
    profile's `config.yaml`.
  - **Migration notice** — Settings shows a one-time banner when a profile
    still carries the legacy `jamf_cli.collect_skip` key; saving a preset
    finalizes the migration and clears it.

### Removed

- **`ScheduleTier` + `TieredLaunchAgentWriter`** (PR-23, macOS app): the
  legacy hot/warm/cold per-cadence-tier model and its unused LaunchAgent
  writer are deleted. `RefreshCoordinator` is retargeted onto the PR-22
  `CollectionTier` (Refresh / Inventory / Scan) model, with preset-aware
  staleness thresholds. No user-visible behavior change — the old writer
  had no callers.

- **Per-report collection cadence — engine layer** (PR-22, macOS app):
  `ReportEngine.collect` now consults a per-report cadence policy before
  launching each jamf-cli subprocess, so frequent KPI commands run on a
  daily schedule while expensive per-device scans run weekly without
  having to choose between "fetch everything" and "fetch nothing." YAML
  schema added at top-level `collect_cadence:` with:
  - `preset: on-prem | cloud | custom` — defaults pinned by
    `CadencePresetTests`. On-prem defaults are conservative (daily
    Refresh / weekly Inventory + Scan, 15 s between calls, hard-excludes
    `update-status` and `update-device-failures` which crash memory-fragile
    self-hosted Jamf Pro instances). Cloud defaults are twice-daily
    Refresh / every-2-day Inventory / weekly Scan, no pacing, no hard
    exclusions. Custom requires explicit per-report entries.
  - `per_report:` overrides accept the bare-cadence shorthand
    (`overview: 86400`), the kill-switch (`update-status: never`), or the
    explicit object form `{tier: refresh, cadence: 43200}`.
  - `pace_seconds:` overrides the preset's between-call sleep.
  Scheduled `--mode snapshot-only` runs now narrow to the Refresh tier
  only — Trends and the Overview KPIs stay fresh without re-fetching
  every list endpoint each cycle. State files at
  `<jamf_cli.data_dir>/state/<report>.last` track the last successful
  fetch per report; tampering surfaces in the audit view via the
  PR-7 snapshot-manifest scheme (T-14 extends the manifest to cover
  `.last` files; schema bumped to v2). GUI controls for editing the
  schema ship in PR-23. Operators with `jamf_cli.collect_skip` from
  PR-16 see automatic in-memory migration to `per_report: <kind>: never`
  on load — both keys are read during the transition window so no
  re-scaffolding is required. The legacy key is still honored; PR-23
  GUI saves stop emitting it. Full design in
  `docs/architecture/tiered-collection-adr.md`. 1 589 tests pass with
  58 new across `CollectionTierTests`, `CadencePresetTests`,
  `IsDueTests`, `CadenceResolverTests`, `CollectCadenceConfigTests`,
  `StateFileStoreTests`, `WorkspacePathsStateDirTests`,
  `CollectFilterCompositionTests`, `CollectSkipMigrationTests`, and
  `StateFileManifestTests`.

### Changed

- **Diagnostic-bundle redaction hardened** (Python CLI): `diagnostic-bundle`
  now redacts identifiers the regex passes could not reach. The local macOS
  username is stripped from absolute `/Users/<name>/` paths in log free-text;
  the redactor seeds itself from cached `jamf-cli-data/` JSON so device names,
  UDIDs, and asset tags echoed into run logs are redacted by exact match;
  `workspace_tree.txt` now runs through the redactor; and `_PII_JSON_KEYS`
  gained `udid`, `ipAddress`, `realName`, `assetTag`, `managementId`, and the
  `building` / `department` / `room` / `position` org-structure keys. Verified
  against a real workspace: a username that previously appeared 164 times in a
  bundle's logs now appears zero times.

- **Sidebar workspace monogram widened to four characters** (PR-25, macOS
  app): the workspace-chip avatar shows the first four characters of the
  profile slug instead of two, so profiles that share a short prefix stay
  distinguishable at a glance. The avatar widens from 22 to 36 points.

- **Schedule mode semantics tightened — each mode now does exactly one thing** (PR-21, macOS app):
  Before PR-21, three of the four `Schedule.RunMode` cases had descriptions
  that disagreed with the code: `jamf-cli-only` said "from cached data" but
  called collect first; `jamf-cli-full` and `csv-assisted` were operationally
  identical (both passed the newest CSV when present, both no-op'd CSV when
  absent). Modes are now strict and distinct:
  - `snapshot-only` — collect only; updates Trends; no workbook (unchanged from PR-20).
  - `jamf-cli-only` — generate only from the latest cached snapshots; **no collect step**.
    Fast re-render path for editing config or templates without hitting the API.
  - `jamf-cli-full` — collect + generate; no CSV. Renamed display label clarifies
    "No CSV input."
  - `csv-assisted` — collect + generate with a CSV from `csv-inbox/`. Now
    **hard-fails when no CSV is present** instead of silently falling back to a
    jamf-cli-only workbook. Earlier behavior masked broken CSV pipelines for
    days at a time; use `jamf-cli-full` explicitly if you want the no-CSV path.
  Existing pre-PR-20 LaunchAgent plists (which omit `--mode`) default to
  `jamf-cli-only` — that means the silent collect they did before PR-21 stops
  happening; resave the schedule from the GUI to migrate to the explicit mode
  you want. `Schedule.RunMode.displayTitle` and `displayDescription` strings
  updated to match the new semantics; `docs/wiki/07-LaunchAgent-Automation.md`
  Workflow Modes section rewritten to describe both the strict Swift contract
  and the legacy Python `launchagent-setup` divergence (notably csv-assisted's
  silent fallback).

### Fixed

- **OS version deduplication broadened beyond charts** (Python CLI): the
  `_normalize_os_version` normalization that PR-17 applied to OS adoption chart
  timeseries is now also applied to the Security Posture OS Version Distribution,
  the Inventory Summary, and the HTML report, so a release that Jamf reports
  under multiple strings (`macOS 14.6.0`, `14.6.0`, `14.6`) collapses to a single
  row in those sheets too. Rows artificially split by this Jamf reporting quirk
  are re-aggregated before writing.

- **Generated workbooks were unreadable in Excel** (PR-25, macOS app):
  `OOXMLWriter`'s ZIP-entry provider returned the entire part on every
  chunk call. ZIPFoundation sums each returned chunk into the STORED
  entry's `compressedSize`, inflating it to a 4–16x multiple of the real
  length; Excel read past the real data and rejected the worksheet ("We
  found a problem with some content"). QuickLook tolerated the mismatch,
  so the corruption surfaced only in Excel. The provider now returns only
  the requested byte range. Also adds the ECMA-376-required `count`
  attribute on `<cellXfs>` and a defensive last-write-wins cell de-dup.
  New `XLSXIntegrityTests` covers STORED-entry size consistency, XML
  well-formedness, and absence of duplicate cell references.

- **Schedule mode now round-trips through the LaunchAgent plist** (PR-20, macOS app):
  The Swift `LaunchAgentWriter.nativeSingleWrite` / `nativeMultiWrite` now embed
  `--mode <rawValue>` in `ProgramArguments` so the user's selected mode
  (snapshot-only / jamf-cli-only / jamf-cli-full / csv-assisted) survives the
  round-trip through `LaunchAgentService.parse`. Previously the writer omitted
  mode entirely; the parser then defaulted to jamf-cli-only on every read,
  silently overriding the user's choice. The Schedules form let you pick
  snapshot-only, but the next refresh of the list showed it as jamf-cli-only —
  and the scheduled run did the jamf-cli-only behavior because `main.swift`
  unconditionally ran collect + generate. `main.swift`'s `--scheduled-run`
  handler now parses `--mode` (falling back to jamf-cli-only for pre-PR-20
  plists) and dispatches: snapshot-only runs collect only; jamf-cli-only runs
  collect + generate without CSV; jamf-cli-full and csv-assisted run collect
  + generate with the newest CSV from `csv-inbox/`. New
  `testNativeSingleWriteRoundTripsAllRunModes` covers every case in
  `Schedule.RunMode.allCases`.

- **OS adoption charts no longer split same-version device counts across trailing-zero variants** (PR-17): Jamf MDM rows sometimes record OS version as `26.4` and sometimes as `26.4.0` for the same release; the adoption-chart timeseries builders treated them as distinct columns, splitting one population across two lines. `ChartGenerator` now normalizes versions at read time — trailing `.0` patch components are stripped while preserving at least `major.minor`, so `26.4.0 → 26.4` but `26.0.0 → 26.0` (and `26.4.1` is left alone). Applied to both the CSV-sourced (`_build_os_timeseries`) and jamf-cli JSON-sourced (`_build_inventory_summary_timeseries`) paths so the chart is consistent regardless of source. Historical archived snapshots benefit retroactively without re-export.

### Added

- **`snapshot-only` schedule mode now updates the Trends summary** (PR-20, macOS app):
  `ReportEngine.collect` emits `summary_<today>.json` after the collection
  loop completes — previously this only happened inside `generate()`, so a
  snapshot-only schedule collected fresh data but never advanced the Trends
  page. The first-run-of-day skip from PR-18 still applies (a same-day
  summary file is not overwritten); operators investigating "I ran twice and
  Trends only moved once" see the `[info] summary_<today>.json already exists`
  log line and know why. The Schedules form description
  (`Schedule.RunMode.snapshotOnly.displayDescription`) updated accordingly:
  "Runs jamf-cli pro collect, archives JSON snapshots, and updates the
  Trends summary. Does NOT generate a workbook."

- **`jamf_cli.collect_skip` config option for excluding expensive report types from `collect`** (PR-16): Set `jamf_cli.collect_skip: [update-status, update-device-failures]` (or any of `patch-device-failures`, `profile-status`, `update-status`, `update-device-failures`) in `config.yaml` to skip those per-device-heavy queries during live collection. Targets on-prem Jamf Pro instances where these reports stall the server. Skipped commands log `[skip] <label>: excluded by jamf_cli.collect_skip` so operators see exactly what was excluded. Underscores and hyphens are interchangeable in values. Core inventory commands (computers, security, EAs, etc.) always run because the primary report sheets depend on them.
- **Per-LaunchAgent-run partial-status summaries + manifest coverage for `snapshots/computers/summaries/`** (PR-11, threat-model T-12): `cmd_generate` invoked from `cmd_launchagent_run` now emits a per-log `summary_<log_filename>.json` carrying the run's `status` field. The Swift `RunHistoryService.isPartialRun` and `LaunchAgentService.checkSummaryFileForPartialStatus` previously read a file that no producer wrote (BACKLOG MEDIUM-3); they now have a real producer AND verify the file's SHA-256 against a sibling `manifest.json` before trusting `status`. Tampered or corrupt summaries fall back to the existing `[partial]` log-marker scan rather than silently misreporting the PARTIAL pill. Daily `summary_YYYY-MM-DD.json` writes ALSO produce a manifest now — closes the integrity gap PR-7 left open for trend summaries.
- **T-13 integrity envelope for Generated Reports** (PR-12, threat-model T-13):
  Every generated `.xlsx` now ships with a `<basename>.xlsx.sha256` sidecar
  in `shasum -a 256` output format, so recipients can verify the file with
  `shasum -a 256 -c <basename>.xlsx.sha256` from the report directory.
  Generated HTML reports embed a `<meta name="report-sha256" content="...">`
  tag in `<head>` and a visible source-fingerprint footer with the
  verification procedure. The macOS app's "Report ready" toast surfaces the
  first 12 hex chars of the hash; the Generate sheet's completion banner
  shows the per-artifact fingerprint with a click-to-copy button for the
  full 64-character digest. Python and Swift emitters produce identical
  envelope structure.
- **`jamf_cli.require_manifest` config option + AuditView "Unverified snapshot" warning card** (PR-10, threat-model T-11): Set `jamf_cli.require_manifest: true` in `config.yaml` (or toggle "Require snapshot manifest" in Configuration → jamf-cli Cache) to hard-fail on tampered snapshots — SHA-256 mismatches or corrupt manifests. Missing or legacy manifests are tolerated, not hard-failed. Equivalent to passing `--strict-manifest` on every invocation. The macOS app's AuditView now surfaces a warning card listing the count and breakdown of unverified snapshot directories regardless of the config setting, closing the "manifest absence = silent pass" gap from PR-7.
- **`LICENSE`** (MIT), **`NOTICE.md`** (Jamf/Apple trademark and non-affiliation notice), **`THIRD_PARTY_NOTICES.md`** (ZIPFoundation, jamf-cli, Chart.js, Python deps): canonical files at the repo root; mirrored copies in `app/Sources/JamfReports/Resources/` for in-app loading.
- **`BACKLOG.md`**: project-visible backlog of deferred review findings. Items are added when valid but out of scope for the current change, removed in the same commit that fixes them. Pointer notes added to `CLAUDE.md` and `AGENTS.md`.
- **`Acknowledgements…` menu item** (macOS app, application menu): opens a window with three tabs — License, Trademark Notice, Third-Party Notices — driven by `Bundle.module`-loaded resource files. Selectable, accessibility-labeled text.
- **`EmptyStateView`** (macOS app, shared component at `Theme/EmptyStateView.swift`): generalizes the Compliance Posture screen's empty-state pattern (optional icon + title + message + optional primary action). Retrofitted Compliance Posture (canonical usage) and Devices view. Includes accessibility hooks and `#Preview` variants for design verification. Now also accepts an optional `commands: [String]` parameter that renders a list of mono command-line examples above the action button.
- **`Theme.Severity` ramp** (macOS app, `Theme/ThemeSemanticTokens.swift`): paired `inApp` / `export` / `pillTone` / `systemImage` accessors for critical / high / medium / low. Drives Protect alerts-by-severity bars, severity Pills, the export canvas variants, and the new color-blind-safe icon redundancy in Phase 5.3.
- **`Theme.ChartPalette.osVersionInApp` and `osVersionExport`** (macOS app, `Theme/ThemeSemanticTokens.swift`): matched 8-entry palettes consumed by Security Posture `osChart` (in-app) and `SecurityPostureOSDonutExport` (light canvas) so the OS donut now looks the same when exported as on-screen.
- **`DataTableHeader` / `DataTableRow` / `DataTableColumn`** (macOS app, `Theme/Components.swift`): shared table primitives for hand-rolled tables that can't use SwiftUI `Table` (e.g. multi-line truncated rows). `DataTableColumn.width` is `CGFloat?` — `nil` means flex. PolicyProfileView (findings + profiles) and UpdatesView (failed plans + error devices) consume these instead of three independent table dialects.
- **`Theme.Text` / `Theme.Hairline` / `Theme.Surface` contrast-aware accessors** (macOS app, `Theme/ThemeSemanticTokens.swift`): helpers that bump foreground / hairline / surface opacity when `colorSchemeContrast == .increased`. Used in Pill, Sparkline, EmptyStateView, Sidebar, and StatusBar so the app responds to macOS *System Settings → Accessibility → Display → Increase Contrast* by gaining weight rather than recoloring.
- **`accessibility-audit.md`** at the repo root: WCAG 2.1 contrast matrix for every (foreground, background) text pair in the dark theme. Documents methodology, identifies 8 failing pairs across 5 token roles, and proposes minimal token tweaks. The proposed tweaks were applied in a follow-up commit (Pill `.muted` / `.warn` / `.danger` fg, `tealBright`, `fgDisabled`) — all rendered failures now clear AA Normal at 10.5 pt.
- **`build-pkg.sh`** (macOS app): distribution-style `.pkg` installer. Reuses the signed `.app` from `build-app.sh`, installs to `/Applications/JamfReports.app`, beta-aware filename naming (`JamfReports-2.0.0-beta10.pkg` vs `JamfReports-2.0.0.pkg`), team-ID-based Developer ID Installer cert resolution, `pkgutil --check-signature` verify-after-sign, `notarytool submit --wait` + `stapler staple` on release builds.
- **`build-dmg.sh`** (macOS app): consolidated `.dmg` builder paralleling `build-pkg.sh`. Auto-detects marketing + build version from `Info.plist`, beta-aware filename naming, team-ID-based Developer ID Application cert resolution, hard-fail on missing release identity, `notarytool` + `stapler` on release builds.
- **`docs/GLOSSARY.md`**: canonical reference for Apple-platform, Jamf, and jamf-reports-community vocabulary. Disambiguates overlapping terms (smart vs static group, scope vs target, blueprint vs config profile, MDM command vs declaration, ADE vs DEP) and defines project-specific terms (workspace, profile slug, refresh tier, ReportEngine, TrendStore, Compliance Band, Risk Score, Security Score, Stability Index). Pattern inspired by jamf-cli PR #199; lightweight version without the `docs/solutions/` postmortem archive.
- **Chart PNG export across the new dashboards** (macOS app): Security Posture, Compliance Posture, Updates, Mobile Fleet, Protect, and Extension Attributes each gained an Export PNG button next to their primary chart. The export pipeline (`DashboardChartExport`) renders a fixed 848×448 light-mode canvas with consistent serif title + monospaced kicker + footnote framing so every saved PNG looks like it came from the same template.
- **X-axis label scaling in Trends** (macOS app): trend chart x-axis tick density now scales with the selected range (7d / 14d / 28d / 56d strides for w4 / w12 / w26 / w52, and `.automatic(desiredCount: 8)` for All). Labels switch between "Apr 1" → "Apr '26" → "2026" formats so wider ranges no longer collide.
- **Per-EA memory bounds in the Extension Attributes service** (macOS app): the EA dashboard's underlying service now pre-aggregates raw `ea-results` rows in a single streaming pass. Peak memory is bounded by `O(devices + distinctValues)` instead of `O(rows)`, so a 54,000-row fleet (600 devices × 90 EAs) no longer holds the full row array on the snapshot. Top 20 values per EA are kept; the tail rolls into an `Other` bucket with a "Top values shown per EA" footnote when the row count exceeds 25,000.
- **Nine new dashboards** (macOS app): Security Posture, Compliance Posture, Patch, Updates, Policy/Profile, Extension Attributes, Outreach, Protect, and Mobile Fleet. Each reads existing cached `jamf-cli` JSON snapshots — no new API commands are issued. The Sidebar gains POSTURE, OPERATIONS, and FLEET groups; core tabs stay pinned at the top.
- **Configurable Security Score** (macOS app, Config → Scoring tab): The v3.5 weighted security score (FileVault 15, SIP 15, Firewall 15, CrowdStrike 10, mSCP 20, XProtect 5, CVE 15, Secure Boot 5) is now exposed as editable weights and persisted in `config.yaml`. Risk Scoring factors are configurable in the same tab. Defaults reproduce the legacy script's output within ±0.5 points for the same data.
- **Sidebar visibility controls** (macOS app, Settings → Sidebar Visibility): Hide dashboards you don't use; core tabs (Overview, Devices, Sources, Settings) cannot be hidden. Preferences persist via `@AppStorage` per machine.
- **Default trend range** (macOS app, Settings → Data & Charts): A new picker lets you set 4/12/26/52 weeks (or All) as the default for Overview and Trends. Default is now 4 weeks. The picker in Trends still lets you override per-session.
- **Skip expensive collections** (macOS app, Settings → Data & Charts): Optional toggle that omits four per-device commands (`ea-results --all`, `patch-status --scan-failures`, `update-status --scan-failures`, `device-compliance`) from manual GUI refreshes to spare on-prem Jamf servers. LaunchAgent-scheduled collects always run the full set.
- **Legacy fleet-health history import** (macOS app, Settings → Import legacy history): Reads `fleet_health_metrics_history.json` written by `jamf_reports_cli_v3.5.py` and seeds the workspace's `summaries/` directory with translated `summary.json` snapshots so Trends has historical depth from day one.
- **Complete rewrite as a native macOS application**: The project has been rewritten from the ground up as a native Swift/SwiftUI application for macOS 14+. The original single-file Python CLI (`jamf-reports-community.py`) served as the reference implementation; all report generation, data collection, scheduling, and config management logic has been ported to Swift and is now compiled into a self-contained `.app` bundle. Users no longer need Python, pip, or any third-party runtime installed — the app ships with everything required. The Python CLI remains in the repository as a standalone tool for headless or non-Mac environments.
- **Python-free operation** (macOS app): All interactive GUI paths — collect, generate, generate HTML, export inventory CSV, school collect, school generate, config check, workspace init, and LaunchAgent scheduling — now run exclusively through the native Swift engine (`ReportEngine`). Users no longer need Python installed or a bundled Python runtime for any supported workflow. The only remaining jrc dependency is `backup()` and the multi-profile LaunchAgent fan-out — both are limited to edge-case automation flows and will fail fast with a clear error if jrc is absent.
- **Auth fail-fast guard** (macOS app): `CLIBridge.collect()` and `collectThenGenerate()` now probe `jamf-cli pro auth token` before launching any API commands. A profile with invalid or unconfigured credentials returns exit code 3 (HTTP 401) and emits an actionable error line, preventing redundant subcommand launches against an unauthorized tenant. Jamf School profiles (`auth-method = apikey`) bypass the probe automatically.
- **Dynamic Platform Gateway status** (macOS app, Config → Platform API tab): When the active workspace profile uses Platform Gateway auth (`auth-method = platform`), the tab now shows a green "Platform Gateway profile active" callout instead of a static setup instruction, with the profile name and a prompt to enable the Platform API toggle.
- **VoiceOver / Accessibility** (macOS app): All Swift Charts views — Trends metric charts, hero trend chart, compliance distribution, security posture comparison, OS version distribution, and fleet stability — now expose full VoiceOver chart navigation via `AXChartDescriptorRepresentable`, allowing VoiceOver users to swipe through individual data points. Interactive controls (`PNPButton`, `PNPToggle`, `SegmentedControl`, `StatTile`, sidebar nav items, workspace chip, agent cards, metric pills) have composed accessibility labels that include badges, counts, and trend direction. Decorative elements (sparklines, legend dots, progress bar fills, hover chevrons) are hidden from the accessibility tree.
- **Design polish** (macOS app): Visual refinements across eight views:
  - *Sidebar*: Per-profile gradient avatar (hue derived from profile name); compact-mode icon sizing improved; workspace chip shows available workspace count; nav items include badge counts in their accessibility labels.
  - *Titlebar*: Status dot animates when jamf-cli is missing; demo mode chip is tinted gold; hover popover reveals the resolved jamfCLI binary path.
  - *Overview*: Stat tiles with downward trends receive a danger tint and border; security agent cards below 80% coverage show a warn-tinted progress bar and gap count; drill-down cards animate border and shadow on hover.
  - *Fleet Overview*: Profile cards with issues show a warning-colored left-edge accent stripe; first-time profiles (no summary yet) use a dashed border instead of a solid hairline.
  - *Devices*: Search field shows a gold focus ring on focus; stale devices badge the Last Contact column with a clock icon; responsive column hiding collapses low-priority columns at <1200 pt; security status displayed as colored pills.
  - *Trends*: Metric pills show a leading accent bar on selection, a micro-sparkline of the last 8 values, and a pulsing danger wash on declining metrics; the hero chart value gets a metric-colored shadow and a date-range label; archive bars show date and value in a hover tooltip.
  - *Audit*: CRITICAL findings get a red left-edge accent bar; affected-count shown as an inline proportional bar; newly detected findings animate in with a "NEW" badge; resolved findings show a strikethrough with an ok-colored checkmark.
  - *Schedules*: Next-run tile shows a 60 s-tick countdown with a semicircular progress arc; run log is terminal-styled with per-line color coding for errors, warnings, and success keywords, and auto-scrolls only when already at the bottom.
- **Protect Computers Sheet**: New 14-column sheet listing Jamf Protect-managed Macs (hostname, serial, UUID, model, OS version, plan, tags, web protection / full disk access status, insights pass/fail/unknown counts, connection status, last connection). Driven by `jamf-cli protect computers list`. Gated by `protect.computers.enabled` (default off). Marked Experimental until pagination shape is verified against a live tenant.
- **Protect Alerts Sheet**: New 11-column sheet listing Jamf Protect alerts (created, severity, status, event type, computer, serial, plan, analytics, actions, tags, UUID). Driven by `jamf-cli protect alerts list`. Gated by `protect.alerts.enabled` (default off).
- **Protect Insights Sheet**: New 10-column sheet listing Protect compliance insights (label, section, description, pass/fail/none counts, enabled, tags, CIS IDs, UUID). Driven by `jamf-cli protect insights list`. Gated by `protect.insights.enabled` (default off).
- **Device Lookup screen** (macOS app): Search by serial, hostname, asset tag, or device ID; resolves via `jamf-cli pro device <id>` and renders the full DeviceDetail. Includes "Open in Jamf Pro" deep-link to the corresponding console page.
- **APIScope Toggle UX** (macOS app): The per-profile API scope chip in Data Sources is now an interactive Menu — Limited↔Full Admin selectable inline, with a confirmation dialog required for elevation to Full Admin.
- **Console Deep-Link Helpers**: Typed `consoleURL(...)` helpers cover computers, mobile devices, smart/static computer groups, policies, and computer/mobile config profiles, plus String-id overloads. Replaces ad-hoc URL construction across views.
- **jamf-cli First-Time Installer**: `JamfCLIInstaller.firstTimeInstall()` direct-downloads the latest GitHub release into `~/.local/bin/`. SHA256 verification against the release's `*.checksums.txt` is mandatory — install is refused if the checksums file is missing or the digest does not match. Existing upgrade path now flows through the same verification.
- **Platform Health Audit Sheet**: New `Platform Health` sheet driven by `jamf-cli pro audit --checks platform`. Surfaces seven platform-specific health checks (undeployed blueprints, blueprint deployment failures, stale blueprints, compliance benchmarks needing updates, MONITOR-mode benchmarks, empty platform scope, devices with failed DDM declarations). Gated by `platform.enabled` and `platform.audit_platform.enabled`.
- **School DEP Devices Sheet**: New sheet listing DEP-enrolled devices (Serial Number, Model, Color, Status, Profile Name, Device Name). Driven by `jamf-cli school dep-devices list`.
- **School iBeacons Sheet**: New sheet listing configured iBeacons (Name, UUID, Major, Minor, Description). Driven by `jamf-cli school ibeacons list`.
- **Jamf Protect Plans Sheet**: New 14-column `Protect Plans` sheet showing plan name, threat-prevention strategy, custom engine config, exception/analytic sets, and telemetry version per plan. First step of Protect feature graduation from experimental.
- **Protect Bridge**: New `ProtectCLIBridge` class graduates the experimental Protect plumbing into a first-class subclass of `JamfCLIBridge`. Includes auth-detection (`is_protect_available()`) and structured error classification (`_classify_protect_error()`).
- **CI Automation**: Added Dependabot configuration plus weekly workflows that watch for new jamf-cli releases and Python versions.
- **Jamf School Reporting**: Full support for Jamf School inventory and device group sheets in Python reports.
  - New **Compact Inventory**: CSV-driven inventory focusing on stale-status classification.
  - New **Sorted Device Groups**: Bridge-driven group reporting sorted by device count with multi-location support.
- **Native macOS App**: Introduced a complete SwiftUI-based desktop application for fleet overview, detailed inventory, health audits, and automated schedule management.
- **Health Audit Improvements**: New audit views in the macOS app for identifying stale devices, empty groups, and hygiene findings from jamf-cli data.
- **Group Hygiene Reporting**: Automated detection and reporting of unused or misconfigured device groups.
- **Config Management**: Expanded `ConfigView` in the macOS app to manage stale device thresholds, run retention policies, and jamf-cli cache settings.
- **Inbox Management**: Wired `SourcesView` to the workspace inbox for real-time monitoring and one-click clearing of generated reports.
- **Automated Scheduling**: Atomic LaunchAgent management for scheduled report runs across multiple profiles.
- macOS app **Fleet Overview** tab now aggregates initialized profile workspaces
  from historical summary JSON, showing per-profile device count, Stability
  Index, and last successful run without exposing local configuration paths.
- macOS app **Overview** and **Fleet Overview** surfaces now support drill-down:
  KPI cards, macOS distribution, failing rules, security-agent cards, recent
  activity, and fleet profile cards open detail pages with relevant metrics and
  actions to jump to related tabs.
- Added **Stability Index** trend metric as a management-level health score,
  weighted from compliance, patch posture, and inverse stale-device pressure.
- Added **Interactive Breadcrumbs** to all page headers; users can now click the
  parent view name (e.g., "OVERVIEW") to navigate back or switch tabs.
- Added **Keyboard Shortcuts** for core app actions: `Cmd + R` (Refresh),
  `Cmd + F` (Find/Search), and `Cmd + D` (Toggle Demo Mode).
- Added **Live Status Bar** to the app footer, providing real-time feedback and
  CLI output (e.g., "Collecting jamf-cli snapshots...") during long-running tasks.
- Added **Toast Notifications** for background task completion; a brief popup
  now confirms successful report generation or audit completion across all tabs.
- Added **Context Menus** (right-click) to device rows in Detailed Inventory and
  Overview tables with actions for "Open in Jamf Pro", "Copy Serial", and "Copy User".
- Added **Interactive Column Sorting** to inventory and audit tables.
- **Security Hardening**: Hardened `ProfileService` path safety with direct-child workspace root validation to prevent symlink-based traversal.
- **App Responsiveness**: Improved `DirectoryWatcher` responsiveness by reducing debounce interval and ensuring MainActor thread safety for Swift 6 concurrency.

### Changed

- Tracked jamf-cli dependency updated to v1.17.0. No code changes required.
  Notable upstream changes since v1.14.0:
  - v1.15.0: Spec-generated platform commands and bulk delete functionality added.
  - v1.16.0: New `jcds download <fileName>` and `jcds sync --dir <path>` commands for
    Jamf Cloud Distribution Service — not used by the app.
  - v1.16.1: Nil-safety fix for device platform section fields — picked up by the app's
    v1.16.1 minimum version floor (see entry below).
  - v1.17.0: New `--compact` flag (token-efficient output), `--select` flag (multi-field
    projection), and `doctor` diagnostic command. Inventory preload CSV export and app
    store app backup capabilities added. Classic API extended with ebooks, user-groups,
    and VPP scope support. Destructive commands annotated with `jamf:destructive`.
    None of these changes affect commands or flags used by the app.
- **Partial-success status for sheet-write failures** (Python CLI + macOS engine): When one or more sheets fail to write during `generate` / `school-generate`, the run now emits `status: "partial"` in `summary.json`, lists the failed sheets in `sheets.failures` (with `{"sheet": name, "error": "<Type>: <message>"}` entries), populates `counts.sheet_failures`, and logs `[partial] Report written with N sheet failure(s)` instead of the plain success line. Previously, sheet exceptions were swallowed and the run reported `status: "ok"` regardless. **Operator note**: tenants whose CSV column mapping has a pre-existing tolerated miss (`KeyError`/`ValueError` on a non-required sheet) will now surface as `status: "partial"` rather than silently skipping. Required sheets (e.g. Compliance with `compliance.enabled: true`) still raise `SystemExit` and fail the run as before. Required sheets are evaluated by `CSVDashboard.required_failures` on the Python side and by the `SheetSkippable`-conforming error protocol on the Swift side; non-conforming throws land in `failures` rather than being swallowed.

- **Design review pass across the dashboards** (macOS app):
  - *Pills never wrap mid-word*: `Pill` now applies `.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)` internally. `CRITICA / L`, `INVESTIGAT / ING`, and `INAC / TIVE` no longer render across two lines in Protect and Updates tables. Column widths bumped where the underlying label is genuinely longer (Protect status 88 → 104 pt, Updates state 120 → 138 pt).
  - *EmptyStateView icon is visible*: foreground swapped from `hairlineStrong` (white @ 0.12) to `fgMuted` so the icon reads as a visual anchor rather than a ghosted artifact. The `NSAccessibility.announcementRequested` on-appear announcement was dropped — tab labels already speak themselves and `NSApp.keyWindow` can be nil for non-focused windows.
  - *Severity bars and severity Pills now agree per row*: Protect's `Alerts by Severity` card was using a different ramp from its own severity Pills below it (Medium read bright yellow on the bar, gold-brown on the Pill). Both routes now go through `Theme.Severity.{critical,high,medium,low}.inApp`, so the row colors line up.
  - *Status colors come from Theme tokens, not inline hex*: `PatchView.complianceColor` / `actionColor`, `OutreachView.daysSinceColor`, and `CompliancePostureView.barColor` now reference `Theme.Colors.danger / warn / goldBright / ok` instead of duplicating the same hex literals.
  - *OS-version palette is shared between in-app and export*: Security Posture's macOS donut and its PNG export now consume `Theme.ChartPalette.osVersionInApp` / `osVersionExport`. Exporting the chart no longer produces unexpectedly different slice colors. MobileFleet's iOS version chart aligns its export against the same palette's lead color.
  - *Empty states use one component, one icon weight, one padding*: nine hand-rolled empty states across Security Posture, Compliance Posture (already canonical), Outreach, Patch, Updates, Policy/Profile (both findings and profiles), Extension Attributes, Mobile Fleet, and Protect were converted to call `EmptyStateView(...)`. Each screen now picks a domain-appropriate SF Symbol. Protect's "no Protect data" state includes the four `jamf-cli protect *` commands that would populate it.
  - *KPI grid columns are aligned across screens*: every `LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, …)])` was raised to `220` to match the Overview screen, and `ProtectView.kpiGrid` switched from a fixed-3-columns layout to the same adaptive form. At 960 pt window width, Overview and Security Posture now show the same tile widths.
  - *"Showing N of M" copy unified*: every SectionHeader trailing that signals a row cap now reads `"\(shown) of \(total)"`; bare counts and "Showing first N" variants were removed. `PolicyProfileView.findingsCard` previously capped at 100 silently — the cap is now annotated.
  - *SectionHeader gained a `trailingValue:` slot*: passes a sentence-case string through `fg2` color without uppercase tracking. Used in Extension Attributes' Value Distribution card header where the EA name (e.g. "FileVault Status") was being rendered as "FILEVAULT STATUS" in tracked mono. The existing `trailingTag:` slot retains the uppercased Kicker behavior for actual tags.
  - *Hand-rolled tables unified*: Policy/Profile (findings + profiles) and Updates (failed plans + error devices) now consume new `DataTableHeader` / `DataTableRow` / `DataTableColumn` primitives from `Theme/Components.swift`. Column widths are preserved; row-level styling (per-row backgrounds, multi-line truncated error cells) carries through unchanged. Reduces three table dialects to one.
  - *Extension Attributes export header*: removed the redundant `Spacer()` between SectionHeader and Export PNG button — SectionHeader already has an internal Spacer, so the trailing tag and the export button were misaligned. Same view also drops the duplicate `.onTapGesture` on EA coverage rows.
  - *Patch titles table gains an Export PNG button*: routed through `DashboardChartExport` with a new `PatchTitlesTableExport` light-canvas view (848 × 448 pt). Matches the export pattern already established on Compliance Posture, Security Posture, Updates, Mobile Fleet, Protect, and Extension Attributes.
  - *Export canvas templates unified*: `DashboardExportCanvas` and `ExtensionAttributesView.BarChartExportView` no longer build two different headers — both consume a shared `DashboardExportHeader` so a strip of saved PNGs from different dashboards looks like one set. Export timestamps now include the timezone (`yyyy-MM-dd HH:mm 'UTC'`).
  - *Sidebar polish*: nav rows tint background `Color.white.opacity(0.04)` on hover (matches the workspace chip pattern); `avatarHue(for:)` spreads adjacent letters and offsets clear of the brand gold band so two profiles starting with `A` and `B` no longer pick near-identical hues; the avatar `accessibilityLabel` uses the same two-letter monogram the avatar visually shows.
  - *Protect date formatting*: rows like `731d ago` now render as the absolute date once the span exceeds 60 days. Under 60 days uses `RelativeDateTimeFormatter` with abbreviated units.
  - *Protect KPI subs*: Web Protection / Full Disk Access / Connected tiles read `"10 of 12 (83%)"` instead of a bare `"83%"`, matching the Security Posture KPI tile convention.
  - *Protect subtitle*: falls back to `criticalAlerts + highAlerts + mediumAlerts + lowAlerts` count fields when the `alerts` array is empty but the counts are present — fixes the case where demo data and partial real data produced a subtitle ("12 computers") that didn't match the cards rendered below.
  - *SecurityPostureView Action Items*: the always-zero P2 "Reserved" tile was dropped from the action items card. The card now shows only P0 and P1.
  - *StatTile sparkline color follows the delta*: when the delta direction is `.down` the sparkline defaults to `Theme.Colors.danger`; on `.up`, `Theme.Colors.ok`; on `.flat`, gold. Eliminates the case where an upward gold sparkline was drawn next to a red downward delta on the same tile.
- **Accessibility — respect macOS system settings** (macOS app):
  - *Increase Contrast*: Pill background opacity, Sparkline gradient fill, EmptyStateView message text, Sidebar caption text, and workspace chip background now react to `@Environment(\.colorSchemeContrast)` and gain weight when the system setting is enabled. No light-mode inversion — dark mode is preserved; tokens just step up.
  - *Reduce Motion*: TrendsView pulse animations on bad-trend pills and archive bars now respect `@Environment(\.accessibilityReduceMotion)`. Under reduce-motion, the danger wash and gold pulse are static while the underlying signal (icon, color, text) remains visible.
  - *Reduce Transparency*: Sidebar, StatusBar, and GlassPane swap `.regularMaterial` / `.ultraThinMaterial` for opaque `Theme.Colors.winBG2` when `@Environment(\.accessibilityReduceTransparency)` is on. GlassPane additionally swaps to a stronger border when reduced so the elevation cue survives.
  - *Color-blind redundant encoding*: RunsView and SchedulesView status pills now pair color with an icon (`checkmark` / `exclamationmark` / `xmark`) so last-run status remains identifiable under deuteranopia. Protect severity Pills, Protect alerts-by-severity bars, Policy/Profile findings Pills, Compliance Posture controlBar labels, Patch compliance numerics, and Updates statusBar labels use the same pattern (critical / high / medium / low mapped to SF Symbols). Severity remains identifiable for users with deuteranopia or under macOS *Display → Color Filters → Deuteranopia*.
  - *WCAG 2.1 contrast pass*: dark-theme tokens that failed AA Normal at 10.5 pt were lifted to pass. Pill `.muted` fg moved from `fgMuted` (2.40:1) to `fg2` (5.50:1); Pill `.warn` fg `#FFB340` → `#FFCE7A` (3.82 → 4.59:1); Pill `.danger` fg `#FF8077` → `#FFA39A` (3.77 → 4.83:1); `tealBright` `#3A8A8A` → `#4FAAAA` (3.83 → 5.89:1); `fgDisabled` `#5A5A60` → `#8A8A90` (2.41 → 4.68:1). Log-line error/warn colors in `GenerateSheet` and `SchedulesView` and `PNPButton.danger` fg mirror the new Pill fg targets for consistency. The full matrix and methodology live in `accessibility-audit.md`.
  - *Dynamic Type for body text*: pinned `.system(size: ...)` calls for non-display body text were switched to SwiftUI semantic fonts (`.callout` / `.footnote` / `.caption` / `.caption.monospaced()`) across all 16 primary screens (OverviewView, ProtectView, SchedulesView, HealthCheckView, TrendsView, RunsView, and 10 others). Users on *System Settings → Displays → Larger Text* see body text, captions, and help text grow while the typographic identity (serif H1s, mono kickers, 32 pt numeric metrics, SF Symbols) stays anchored.
- **Theme tokens for log-line coloring** (macOS app, `Theme/Theme.swift`): Named tokens `dangerSoft` (`#FFA39A`) and `warnSoft` (`#FFCE7A`) replace inline hex literals for terminal-style log output in RunsView and SchedulesView. Ensures consistent coloring across live-output views and centralizes audit color maintenance.
- **Sidebar Surface tier on interact** (macOS app): Navigation row hover tint now uses `Theme.Surface.hover(contrast)` which bumps opacity when Increase Contrast is on. Workspace chip swaps to `Theme.Surface.interactive(contrast)` tier when engaged instead of clamped opacity > 1. Sidebar brand block truncates with `.lineLimit(1).truncationMode(.tail)` for long org names.
- **Schedules popover adaptive height** (macOS app, `SchedulesView`): Run-log popover changed from fixed `height: 260` to `minHeight: 200, maxHeight: 320` so it adapts on narrow windows without clipping.
- **Schedules exit-code pill always shows code** (macOS app, `SchedulesView`): Changed from showing "DONE" / "EXIT 0" to always displaying "EXIT N" with tone and icon based on exit code (0 → teal+checkmark, non-zero → danger+xmark).
- **RunsView empty state and context menu** (macOS app, `RunsView`): Hand-rolled empty state migrated to `EmptyStateView` for consistency. Reveal button enabled unconditionally, falling back to run-history root when no run selected. Per-row right-click context menu now mirrors header (Copy log, Export log, Reveal in Finder).
- **TrendsView export unified** (macOS app, `TrendsView`): Chart export migrated to shared `DashboardExportCanvas` pipeline, eliminating 15+ inline hex-color literals. Metric display now renders flat-delta metrics as `"—"` in muted color instead of misleading `+0%`. Archive bar heights normalize to visible data range instead of metric maximum, making sparse trends visible.
- **ExtensionAttributesView empty-state icon** (macOS app, `ExtensionAttributesView`): Swapped icon from `tag` to `slider.horizontal.below.rectangle` to better convey user-defined data slots rather than mail labels.
- **Sidebar is scrollable** (macOS app): the left navigation column now wraps the section stack in a `ScrollView` so the SYSTEM section is reachable on 13" MacBook Pro screens. Compact-rail tray backdrop and workspace chip preserved.
- **Window min-width unified to 960pt** (macOS app, `JamfReportsApp.swift`): the static `minSupportedWidth = 960` constant (with a WCAG 1.4.10 docstring) and the actual `.frame(minWidth:)` were out of sync (the frame was 1200). Both now use the constant — the app is honest about supporting the documented breakpoint.
- **Overview KPI grid reflows on narrow windows** (macOS app): grid columns switched from `.flexible()` to `.adaptive(minimum: 220)` so tiles collapse to fewer columns at narrow widths instead of squishing into unreadable strips.
- **Trends chart Y-axis dynamically fits data** (macOS app): the hero chart's Y-domain now uses `min(metric.minY, dataMin)...max(metric.maxY, dataMax)`. The metric's `minY`/`maxY` constants are treated as a *minimum visible frame* (preferred when data is in-range), not a hard clamp. A Stability Index of 0% is now visible instead of disappearing below `minY: 40`; a Stale count of 101 is visible instead of clipping above `maxY: 60`.
- **Trend chart interpolation switched from `.catmullRom` to `.monotone`** (macOS app): Catmull-Rom splines can overshoot the data envelope between near-zero control points, producing visible "dips below zero" even though no actual data point was negative. `.monotone` (Fritsch-Carlson) provably stays within the envelope.
- **Trends title-bar subtitle reflects the active range** (macOS app): previously hardcoded to `"26W"` regardless of selection. The `Trends` tab subtitle and the picker selection are now both bound to the `@AppStorage("defaultTrendRange")` key, so the title bar shows `Trends / W4` when W4 is selected, etc. Side effect: picker selection persists across navigation.
- **Trends multi-line comparison chart Y-scale**: changed from hardcoded `30...100` to `0...100`. The previous range silently clipped any value below 30% (e.g. FileVault at 0%, early-deployment compliance).
- **Trends archive bar heights normalize to `metric.maxY`** (macOS app): the formula previously assumed a 0-100 percentage metric, producing nonsensical bar heights for raw-count metrics (Stale, Active Devices). Now normalizes against the metric's actual maximum.
- **Trends bad-trend pulse fires only on actual declines** (macOS app): the danger pulse animation previously fired on any non-positive delta, including `0` (flat trend or first-snapshot delta). Restricted to `delta < 0`.
- **Overview first-snapshot delta hides** (macOS app): when only one snapshot exists, the delta row showed `+0.0pp` / `+0` as if a real comparison was made. The tile now hides the delta row when fewer than two snapshots are available.
- **Sparkline lower bound clamped at 0** (macOS app, `Theme/Components.swift`): the Sparkline component normalized to `values.min()...values.max()`, allowing the visible baseline to sit below zero for percentage metrics with near-zero readings. The lower bound is now clamped to `max(0, values.min())`. Internal change; no caller updates needed.
- **`DailySummary` fields `fileVaultPct`, `osCurrentPct`, `patchPct` are now `Double?`** (macOS app, `SummaryJSONParser.swift`): previously non-optional `Double` with `0.0` initialization when source data was absent or failed to decode, making "no data" indistinguishable from a real 0%. Decoder uses `decodeIfPresent`; `ReportEngine` leaves them `nil` when absent; downstream consumers (`SecurityScoreCalculator`, `FleetOverviewView`, `TrendStore`, `Models.TrendSeries.stabilityIndex`) `guard let` / `if let` unwrap. Pulls one item out of `BACKLOG.md`.
- **`build-app.sh` codesign + version validation** (macOS app): `build-dmg.sh` and `build-pkg.sh` both now read `CFBundleShortVersionString` and `CFBundleVersion` from the built `Info.plist` and fail hard if either is missing or invalid. Release builds also `codesign --verify --deep --strict` the `.app` before staging — preventing an unsigned bundle from being wrapped in a signed DMG/pkg and submitted to notarization with a confusing failure.
- **Protect Bridge graduation**: `JamfCLIBridge.protect_*` shim methods (deprecated in v2.0) have been removed. Internal callers now construct a `ProtectCLIBridge` via `_build_protect_bridge(config)`, which honors the dedicated `protect.*` config block (`data_dir`, `profile`, `use_cached_data`) so Pro and Protect can target different tenants. `_protect_commands` / `_require_protect_command` likewise moved from `JamfCLIBridge` to `ProtectCLIBridge` where they always belonged.
- **Protect collect planner** now gates Protect snapshots on `is_protect_available()` — when Protect is unconfigured for the active profile, the collector emits a single `[skip]` line instead of a misleading auth error. The `cmd_check` Protect probe likewise replaces its placeholder-value heuristic with the same availability call.
- **Overview screen tile layout**: Stat tiles on the Overview screen now use a fixed-count flexible grid; previously, an asymmetric `minWidth` on the primary tile caused right-side tiles to collapse into single-character columns on live workspaces.
- **Titlebar breadcrumb is clickable**: The "Tab Name / SUBTITLE" path at the top of every screen now acts as a navigation control — clicking either segment pops the active tab's `NavigationStack` back to root.
- **Minimum supported jamf-cli is now v1.16.1** (raised from v1.14.0). Picks up the platform-section nil-guard in `pro device <id>` (jamf-cli PR #185). The pre-v1.4 patch-status `installed`/`total` shape is no longer parsed — only `on_latest`/`on_other` is supported. The older `update-status` shape (`summary`/`ErrorDevices`) is preserved pending live verification; `status_summary` remains the canonical path. Users on older versions must upgrade via Homebrew (`brew upgrade jamf-cli`). The app surfaces a notice in Settings when the installed version is below the floor rather than hard-failing — most code paths still work.
- **v1.6.0 Compatibility**: Updated patch and update-status parsers to support the new JSON schema introduced in jamf-cli v1.6.0.
- **Python Runtime**: Switched to pinned SHA256 verification for bundled Python runtime assets on both arm64 and x86_64 architectures.
- **Test Suite**: Expanded Swift test coverage for core services including `ConfigService`, `ProfileService`, `CSVInboxService`, and `LaunchAgent` management. Added negative path testing for security boundaries.
- **Date Robustness**: Reconciled Python date-handling logic to be more resilient to clock skew and diverse timestamp formats using UTC-aware pandas parsing across all school-related sheets.
- **Architecture Cleanup**: Removed deprecated `_write_device_groups` and `_write_device_inventory` in favor of more specialized methods.
- Compliance failure-count parsing is now fail-closed: `strict_parse_failures()`
  raises `ValueError` on non-numeric values (empty, "N/A", "null", etc.) instead
  of silently treating them as 0. In the summary JSON path, unparseable values
  cause `compliancePct` to be omitted (GUI shows "no data") rather than exiting.
  CSV sheets log unparseable details and exclude those rows from compliance bands.

### Fixed

- **`api_key` / `apikey` leaked in free-text log lines** (Python CLI + macOS app, `LogRedactor`): both `LogRedactor` implementations already redacted `api_key` / `apikey` JSON keys in `redact_json` walks, but the `_SECRET_PATTERNS` / `patterns` table omitted the matching free-text regex. A jamf-cli echo of an API key in a log line (e.g. `apikey="..."`) survived redaction. Both redactors gained a generic `api_?key` pattern (case-insensitive, 8-char value floor mirroring `client_secret`); diagnostic bundles and run logs now scrub both spellings.
- **`patchPct` written as `0.0` floor when `patch_status` failed** (Python CLI, `_emit_summary_json` CSV path): the CSV branch initialized `patch_pct = 0.0` and unconditionally wrote `patchPct: 0.0` to `summary.json`, even when `bridge.patch_status()` raised. The Swift `DailySummary.patchPct` is `Double?`, so the `0.0` was treated as a real data point and plotted as a 0% trend floor. The key is now omitted (matching the existing `compliancePct` treatment and the Swift `Double?` shape); the warn message now reads "patchPct omitted (no data)".
- **`isTrustedJamfCLIExecutable` skipped the M-01 codesign gate** (macOS app, `LaunchAgentWriter`): the helper used by `runMultiNow`'s legacy multi-profile path verified the jamf-cli candidate by path identity (`ExecutableLocator.locate` + `sameResolvedPath`) but not by signature. A tampered jamf-cli planted at the located path would have satisfied the path check and launched. The helper now runs `CLIBridge.codesignGate` after the path check, closing the 4th spawn site identified in the M-01 review. A `_testLocatedOverride` parameter (test seam only) lets unit tests reach the gate without owning the real binary path.
- **Multi-profile "Run now" failed with "paths are not trusted"** (macOS app, `LaunchAgentWriter`): `nativeMultiWrite` omitted the `WorkingDirectory` key, but `runMultiNow`'s `isExpectedMultiWorkingDirectory` guard required it to match `ProfileService.workspacesRoot()`. Every multi-profile Run now click failed. Three coordinated changes: writer now emits `WorkingDirectory`; validator accepts a missing key (self-heal for pre-existing plists); the compound guard was split so the error message names which path failed (stdout / stderr / WorkingDirectory) and tells the user to re-save the schedule. The self-heal now emits a `[warn]` line so the substitution isn't silent.
- **Config decode failed on every collect/generate** (macOS app, `YAMLCodec`): the parser required block-sequence list items at `indent + 2`, but config.yaml files written by `workspace-init` and edited in the GUI use YAML's compact form where list items share the parent key's indent (valid YAML; PyYAML/ruamel accept it). The result was that `security_agents`, `custom_eas`, and similar lists silently decoded as empty mappings, producing "Config decode failed (config.yaml): The data couldn't be read because it isn't in the correct format" on every run while the engine quietly fell back to default config — so generated reports were missing custom EAs and security agents. New `peekBlockSequenceIndent` lookahead finds sequences at either indent. As a corollary, an empty `key:` followed by a sibling key now decodes as `null` rather than `{}` (which previously failed Array decode for any Optional list field).
- **`pro scripts list` JSON blob leaked into the live run log** (macOS app, `CLIBridge.runAndCapture`): stdout was being both captured for the report engine and streamed to `onLine`. For commands like `pro scripts list --output json` whose stdout is a 360 KB JSON payload, the full body (including embedded script source) flooded the live console — including a complete FileVault decrypt script body bleeding into stderr lines from other profiles. stdout is now captured silently; jamf-cli progress messages continue to stream via stderr.
- **Schedules live output was not selectable / copyable** (macOS app, `SchedulesView.RunLogConsole`): the `Text` lines in the live-output popover gained `.textSelection(.enabled)` and the popover header gained a Copy-all button that joins every line into the clipboard. Users can now copy error text for triage without screenshotting.
- **Recent runs had no Reveal-in-Finder action** (macOS app, `RunsView`): the header gained a Reveal button (next to Refresh / Copy log / Export) and each run row gained a right-click "Reveal log in Finder" context menu. Both route through `SystemActions.reveal`, which is now `@discardableResult` returning `Bool` and logs via `AppLogger.ui.warning` when the path falls outside the allow-list, giving operators an observable signal for the previously silent no-op.
- **"Run now" on Schedules always failed with "stdout log" path error** (macOS app, `LaunchAgentWriter.nativeManualRunPlan`): the validator built the expected `StandardOutPath` via `expectedMultiLogURL(filename: "").deletingLastPathComponent()`, which stripped the per-label folder — comparing `~/Library/Logs/JamfReports/stdout.log` against the writer's actual `~/Library/Logs/JamfReports/<label>/stdout.log`. The validator now uses the helper correctly, passing the actual filenames. Test gap (round-trip writer↔validator) tracked in `BACKLOG.md` since the relevant functions are `private`.
- **Trends chart and Overview sparklines no longer dip below zero** (macOS app): see the *Changed* section for the combined fix — `.catmullRom` → `.monotone` interpolation plus dynamic Y-domain in the hero chart plus Sparkline lower-bound clamp plus optional metric types in `DailySummary`. The "below zero" visual symptom had four compounding root causes; all four are addressed.
- **Trends title bar shows the active range** (macOS app, `ContentView.swift`): previously hardcoded `"26W"` regardless of picker selection.
- **Privacy-modifier convention** (macOS app, logging): `AppLogger` calls added in the recent review pass — `DashboardChartExport.run`, `DashboardChartExport.render`, and `ExtensionAttributeService.load` decode-error branches — used `privacy: .public` for both file paths and `error.localizedDescription`. The project's existing convention (per `ReportEngine.swift`) is `lastPathComponent` (public) + `error.localizedDescription` (private). Updated to match: full paths now log as `lastPathComponent`, and error descriptions are redacted by the OS unified-log system when viewed by other users.
- **Silent PNG export failures** (macOS app): `DashboardChartExport.run` (and the EA-dashboard equivalent) previously dropped render and write errors with `try?` after the user had already confirmed a save destination. Both helpers now return `Result<URL, ExportError>?`; each dashboard caller posts a danger-style toast on `.failure` and `AppLogger.ui.error` records the underlying error. The user-visible action no longer fails silently when the disk is full, the destination is unwritable, or `ImageRenderer` returns nil.
- **EA snapshot decode failures hidden as "no data"** (macOS app): `ExtensionAttributeService.load(resultsURL:definitionsURL:)` used `try?` on the JSON decode, making a truncated or corrupt `ea-results.json` indistinguishable from a pre-first-collect empty state. Decode errors now log to `AppLogger.engine.warning` with the failing file path so a stale or malformed snapshot is diagnosable from `Console.app`.
- **Unstable mobile-device row IDs** (macOS app, Mobile Fleet): `Either<L, R>.id` returned `UUID().uuidString` when both `MobileDeviceListRow.id` and `MobileDeviceInventoryItem.mobileDeviceId` were nil, generating a fresh random identity on every render pass. SwiftUI Table selection and scroll position now use a deterministic fallback (`light-<serial>-<name>` / `rich-<serial>-<name>`) so rows without server IDs stay stable across redraws.
- **PNG-export duplication and missing a11y in EA dashboard** (macOS app): `ExtensionAttributesView.exportDistributionPNG` reimplemented the full `NSSavePanel` + `ImageRenderer` + `try?-write` pipeline and the corresponding button had no `accessibilityLabel` or `help`. The function now delegates to `DashboardChartExport.render(...)` (a sibling of `.run` that accepts an already-framed view), and the button has the same a11y modifiers as every sibling Export PNG control. The unused `isExporting` state and `AppKit` import were removed.
- **Skip-expensive subtitle omitted Extension Attributes** (macOS app, Settings): When the "Skip expensive collections" toggle is on, the subtitle listed Posture/Patch/Updates as affected. Since `ea-results` is one of the four suppressed commands, the Extension Attributes dashboard is also affected; the subtitle now lists all four.
- **Trends Export PNG missing accessibility metadata** (macOS app): The reference Export PNG button in Trends had no `accessibilityLabel` or `help`. Added both so VoiceOver announces the active metric and the button's purpose, matching the bar set by the new dashboards.
- **`alertsBySevirityCard` typo** (macOS app, Protect): renamed to `alertsBySeverityCard`. Internal only — no user-visible impact.
- **CollectFilterTests tautology** (macOS app, tests): `testSkipExpensiveFalsePreservesAllPlannedKinds` used `.filter { _ in true }` (identity), which asserted nothing about production behavior. Replaced with `testSkipExpensiveDeltaIsExactlyTheExpensiveKindsSet`, which exercises both branches and asserts the symmetric difference equals `expensivePerDeviceKinds`. Added `testPlannedKindsCountMatchesProductionCommandList` as a drift guard against silent kind additions in `ReportEngine.collect`.
- **Trend metric silent corruption** (Python CLI): `_build_summary_from_bridge` and `_emit_summary_json` silently wrote `0.0` to `summary.json` when any bridge call (security_report, inventory_summary, device_compliance, patch_status) raised an exception. The 0.0 was indistinguishable from a real zero reading in Trends charts. All five metric collection blocks now log a `[warn]` line on failure; `0.0` is still written as a sentinel (required by the Swift decoder) but the failure is now visible.
- **Cache-write failure hidden from fallback chain** (macOS app): `CachedDataFallback.runWithFallback` used `try?` on `saveSnapshot(data)`, silently discarding disk errors (ENOSPC, EACCES). If the cache was never written, the next live failure would hard-error instead of falling back gracefully. Now logs the write failure at `AppLogger.engine.warning` and returns the live data normally.
- **`SystemActions.open` accepted plain `http` URLs** (macOS app): The browser-open branch allowed `http` in addition to `https`, and accepted any URL regardless of whether it had a valid host. Now requires scheme `== "https"` and a non-empty host; bare scheme URLs (e.g. `javascript:`, `data:`) are silently dropped.
- **Silent `return -1` after `ensureWorkspace`** (macOS app): Four call sites in `CLIBridge` returned `-1` with no output when `ProfileService.workspaceURL` returned nil after `ensureWorkspace` succeeded — an unreachable-in-practice but hard-to-diagnose state. All four now emit a `.fail`-level `LogLine` to the Runs screen and an `AppLogger.cli.error` entry before returning.
- **Background refresh failures were invisible** (macOS app): `RefreshCoordinator.performRefresh` incremented `failureCounts` on non-zero collect exits but emitted no log and published no state. Auth expiry or server outage silently staled all workspace data. Now logs each background refresh failure at `AppLogger.cli.warning` with the exit code and consecutive-failure count.
- **Workflow script injection vector** (CI): The jamf-cli version-watcher workflow interpolated the upstream release tag directly into a `run:` shell context. A malicious tag value from `Jamf-Concepts/jamf-cli` could be injected into the shell. The tag is now validated against `^v?[0-9][0-9A-Za-z.+\-]*$` before being written to `$GITHUB_OUTPUT`, and subsequent steps reference it via `env:` rather than direct `${{ }}` interpolation.
- **Cache directory permission errors were indistinguishable from missing directory** (macOS app): `cachedJSONSnapshots` used `try?` on `contentsOfDirectory`, treating ENOENT (expected on first run) identically to EACCES or other errors. Now uses `do/catch` with a specific `NSFileReadNoSuchFileError` guard — ENOENT returns an empty list silently; other errors are logged at `AppLogger.cli.warning`.
- **Security Hardening**: Resolved path-traversal risks by sanitizing trailing-slashes in workspace paths and validating profile names in `TrendStore`.
- **HTML Security**: Hardened HTML reports against branding-driven markup/style injection via escaped titles and topbar branding.
- **UI Stability**: Fixed Swift compiler ambiguities and missing return statements in various app views (`SchedulesView`, `AuditView`).
- **Data Integrity**: Improved error normalization for cached Jamf software-update responses to prevent blank report sheets.
- `_emit_summary_json` now validates existing summary files before skipping:
  parses JSON and checks for required keys (`date`, `totalDevices`, `source`);
  regenerates instead of using corrupt data.
- Compliance parsing no longer crashes in summary path: removed `sys.exit(1)`
  when unparseable values are found; sets `comp_pct = None` and logs a warning.
- Font loading on remote Macs: bypassed SwiftPM's `Bundle.module` lookup for font resources so custom fonts load correctly when the app bundle is copied to a different Mac.
- Canonical macOS bundle layout: normalized the SwiftPM resource bundle directory structure so resource paths resolve correctly in production builds outside the build tree.
- Per-profile drill-down: fixed pluralization of time-ago labels and corrected a missing Stability trend chart on the per-profile detail view in Fleet Overview.
- Tests for `max_cache_age_hours` enforcement in `test_bridge.py`:
  `test_max_cache_age_raises_when_cache_too_old`,
  `test_max_cache_age_skips_check_when_zero`,
  `test_max_cache_age_uses_cache_when_fresh`.
- Tests for `JamfCLIBridge.audit()` and `group_analyze()` methods:
  `test_audit_calls_correct_command`,
  `test_audit_with_category_adds_checks_flag`,
  `test_group_analyze_unused_mode_adds_flag`.
- Fixed chart layout overflow in the macOS app where charts could go "off the page"
  due to categorical string X-axis; now uses continuous `Date` scaling.
- Fixed timeline range filtering (W4–W52) to be duration-based rather than
  snapshot-count based, ensuring correct behavior when daily snapshots exist.
- Fixed chart scaling for sparse data: charts now anchor to the selected time
  domain (e.g., a full year for W52) rather than stretching few points to fill.
- Improved responsiveness of **Trends** view; comparison cards now stack
  vertically on narrow windows using `ViewThatFits`.
- Added **Data Staleness Indicators** to headers; timestamps now turn amber (>24h)
  or red (>7d) with a relative age label to warn when viewing old cached data.
- Improved search discoverability; `Cmd + F` now automatically focuses the search
  field in **Detailed Inventory** and **Health Audit** views.
- Health Audit now tracks drift between cached audit snapshots, badges findings
  that are new since the previous run, and shows recently resolved findings.
- Multi-profile automation now has a dedicated `multi-launchagent-run` command
  that fans out the existing LaunchAgent workflow across initialized profile
  workspaces, with aggregate status JSON and per-profile results.
- Fixed optional metrics (Stability, NIST Compliance) in the macOS app **Overview**
  rendering as 0.0% when no historical data exists; now shows "--" and "No Data".
- Manual multi-profile "Run now" actions in the macOS app now append their output
  to the standard schedule logs and record exit status correctly.
- Hardened device row identity to prevent collisions for records that capture
  a numeric Jamf ID but lack a serial number or name.
- Fixed sidebar trend badge to honor custom `charts.historical_csv_dir` paths
  instead of hardcoding the default snapshots directory.
- Manual multi-profile "Run now" now rejects legacy `jamf-cli multi`
  LaunchAgent plists that point at a fake executable with the same basename
  instead of the trusted `jamf-cli` discovered by the app.
- Multi-profile LaunchAgent schedules now read their aggregate status JSON and
  treat `[fail]`, `Error:`, and non-zero exit markers in logs as failed runs,
  so a failed profile fan-out no longer appears as OK in the schedule list.
- Trends now keep optional metric values paired with their original snapshot
  dates, preventing Compliance, CrowdStrike, and Stability data from drifting
  onto the wrong date when summaries mix CSV-only and jamf-cli-backed metrics.
- Active Devices demo trends now use the demo total-device series and clamp
  mismatched demo date/value arrays, preventing crashes when viewing that metric.
- "Open in Jamf Pro" context-menu actions now appear only when a device has a
  numeric Jamf computer ID populated from inventory or patch-failure data,
  avoiding invalid URLs built from serial/name-based local row IDs.
- Breadcrumb navigation actions now use main-actor closures, resolving Swift
  concurrency warnings from page-header navigation callbacks.
- macOS app Trends **Export PNG** now renders readable, self-contained chart
  images with a light background, title, date range, gridlines, axis labels,
  point markers, highlighted latest point, and summary stats instead of sparse
  dark images with little context.
- Active Devices PNG exports now use dynamic y-axis scaling so count metrics no
  longer flatten into a near-empty line against a hardcoded range.
- Multi-profile schedules now run the saved JRC LaunchAgent command instead of
  bypassing automation through `jamf-cli multi -- pro collect`, preserving the
  selected mode, base profile, target profile list/filter, sequential setting,
  logs, and status-file behavior.
- Health Audit, Group Hygiene, and Backups app views received focused usability
  refinements: compact KPI summaries, last-run timestamps, clearer affected
  counts, recommendation details, group-type/status pills, bulk ID/CSV helpers,
  improved backup labels, diff selection hints, and syntax-colored diff output.
- When `--csv` is explicitly provided but the file is unreadable, `generate`
  now exits with an error instead of silently producing a workbook with no
  CSV sheets.
- When the Compliance sheet is enabled in config but fails during generation,
  `generate` now exits with an error rather than silently skipping the sheet.
- The output workbook is now written to a `.partial` temp file and atomically
  renamed to the final path only after a successful `wb.close()`, preventing
  partially-written `.xlsx` files from being left on disk if the process is
  interrupted mid-write.
- Compliance failure counts of `""` or `"N/A"` no longer silently count as
  passing. Unparseable values are excluded from the compliant count in both
  the summary JSON and the Compliance sheet. The sheet now shows an
  "Unparseable (excluded)" row when any values could not be parsed, making
  the data quality issue visible.
- Merging multiple CSVs via `--csv` now deduplicates rows by serial number.
  If the same serial appeared in more than one input file, the first
  occurrence is kept and a warning is printed.
- Fleet Drift comparison now warns when a historical CSV snapshot contains
  duplicate serial numbers, rather than silently discarding them.
- Unexpected exceptions that escape a command (e.g. network errors, malformed
  JSON) now print a clean `Error: <type>: <message>` line to stderr and exit 1,
  instead of surfacing a raw Python traceback with local paths.
- **Build Fix**: Fixed a missing `return` statement in `SchedulesView.swift` that prevented the macOS app from building.
- **Swift Compiler**: Simplified `latestJson` closure in `AuditView.swift` to resolve a compiler ambiguity error.
- macOS app builds now fail fast when component or bundle signing fails instead
  of continuing with a partially signed app.
- Bundled Python runtime builds now require a pinned SHA256 before downloading,
  extracting, or copying a runtime asset.
- Swift jamf-cli install/update subprocesses now drain stdout and stderr while
  the process is running, avoiding hangs when a command emits enough output to
  fill a pipe buffer.
- Manual scheduled "Run now" execution now rejects tampered LaunchAgent plists
  whose Python executable, script path, config/status paths, log paths, or
  profile do not match the generated command contract.
- LaunchAgent environments are now rebuilt from a small trusted set instead of
  inheriting plist-controlled `PATH`, `JAMFCLI_PATH`, `PYTHONHOME`, or
  `PYTHONPATH` values.
- `launchagent-setup` now writes LaunchAgent plists atomically and restores the
  previous plist if `launchctl bootstrap` fails.
- `backup` now removes partial backup directories on subprocess, stats,
  manifest, or final rename failures and reports cleanup failures explicitly.
- `inventory-csv` now writes through a destination-local temp file before
  replacing the final CSV, preserving an existing export if the write fails.
- `generate` now emits trend summary JSON only after the workbook closes
  successfully, and `--force-summary` can explicitly replace an existing
  same-day summary.
- Cached Jamf managed-software-update endpoint errors are now normalized to the
  same no-data workbook rows as live `jamf-cli` failures, so cached reports no
  longer produce blank Update Status/Failures sheets when the tenant toggle is off.
- Reduced macOS app file-opening and onboarding exposure by removing the unused
  `/Applications` allow-list entry and redacting profile credentials from
  registration failure output before it is shown in the UI.
- Hardened generated HTML reports against branding-driven markup/style injection:
  page titles and topbar branding are escaped, accent colors are limited to hex
  values, inline logos must be small bitmap images, and SVG logos are rejected.
- Hardened macOS app multi-profile "Run now" execution so tampered LaunchAgent
  plists cannot redirect the aggregate status file or stdout/stderr logs outside
  the generated `~/Library/Logs/JamfReports/<label>/` directory, and the saved
  `multi-launchagent-run` arguments must match the generated command contract.
- macOS app report actions now choose a Python interpreter that can import the
  bundled report dependencies, and the workspace banner now distinguishes a
  missing `config.yaml` from a missing workspace directory.
- macOS app scheduled runs now show computed next-run times and last-run status
  from the generated LaunchAgent status/log files; manual "Run now" uses the
  schedule's `launchagent-run` command so it records run history consistently.
- Turning demo mode off now removes the synthetic `meridian-prod` local
  workspace and any generated demo LaunchAgents so the demo profile does not
  leak into live profile discovery.
- Hardened macOS app profile handling around connection validation, workspace
  initialization, LaunchAgent labels, and live-mode trends so invalid profile or
  schedule names are rejected consistently and live users are not shown synthetic
  compliance-band chart data.
- The macOS app now delegates scheduled-run LaunchAgent creation to Python's
  `launchagent-setup`, using the shared status-file, log, CSV inbox, and
  `com.github.tonyyo11.jamf-reports-community.*` plist format; old
   `com.tonyyo.jrc.*` app-generated plists are removed on launch.
 - Fixed `DeviceRecordMerger` not updating `jamfIDIndex` after merging records
   with a new `jamfID`, causing subsequent lookups by Jamf ID to miss updated records.
 - Fixed `TrendStore` timezone mismatch: `parsedDate` used UTC while
   `filterSummaries` used `Calendar.current`, causing date-range boundaries to
   shift during DST transitions. Both now use `Calendar(identifier: .iso8601)`.
 - Fixed `DailySummary` decoding to use explicit `init(from:)` with
   `decodeIfPresent` for optional keys (`compliancePct`, `crowdstrikePct`),
   preventing decode failures when Python omits CSV-only metrics.
 - Fixed `cmd_multi_launchagent_run` missing timeout: `ThreadPoolExecutor` now
   uses `wait(futures, timeout=3600)` so a hanging profile run cannot block
   the pool indefinitely; timed-out profiles are recorded as failed.

### Removed

- Removed unwired Swift prototype status/history/benchmark screens, their
  orphaned single-consumer services, unused demo fixtures, unused theme tokens,
  and unused private Python helpers.

## [1.3.0] - 2026-04-24

### Fixed

- `cmd_inventory_csv` now reads `jamf-cli pro computers list` responses correctly.
  Earlier versions read top-level keys (`name`, `serialNumber`, `operatingSystemVersion`,
  `location.username`) but `jamf-cli` returns nested objects (`general.name`,
  `hardware.serialNumber`, `operatingSystem.version`, `userAndLocation.username`) and,
  by default, only includes the General section. The result was inventory CSVs where
  every non-id/udid field was empty. The bridge now requests
  `--section GENERAL --section HARDWARE --section OPERATING_SYSTEM
  --section USER_AND_LOCATION --section DISK_ENCRYPTION --section SECURITY`, and
  `_inventory_export_row()` resolves values through `_flatten_record` plus a new
  `INVENTORY_FIELD_CANDIDATES` lookup table that handles both nested (current) and
  flat (legacy) shapes.
- Per-device `pro device <id>` enrichment is no longer the only source for FileVault,
  SIP, Firewall, Bootstrap Token, and Gatekeeper columns — those values now come from
  the inventory list's SECURITY section. Setting
  `inventory_csv.skip_security_enrichment: true` is now safe with no data loss for
  the standard security columns; it simply skips redundant per-device API calls.

### Added

- New `jamf_cli.command_timeout_seconds` config key (default `300`) sets the per-call
  timeout for jamf-cli subprocess invocations. The previous hardcoded 120s timeout
  was insufficient for slow Jamf Pro instances or large fleets.
- New `jamf_cli.ea_results_timeout_seconds` config key (default `600`) sets a
  longer timeout specifically for `pro report ea-results --all`, which is consistently
  the slowest jamf-cli call because it queries every EA value across the fleet.
- New `inventory_csv` config block with `max_workers` (default `20`) and
  `skip_security_enrichment` (default `false`). Replaces the previous hardcoded
  `max_workers=8` and provides an opt-out for the per-device security enrichment
  loop now that the inventory list returns security fields directly.
- `JamfCLIBridge.computers_list()` accepts a `sections` argument and converts it to
  repeated `--section` flags. `_run()` and `_run_and_save()` accept an optional
  `timeout` override.

### Changed

- Tracked jamf-cli dependency updated to v1.14.0. No code changes required.
  Notable upstream changes in v1.14.0: added `-vv` (request headers) and `-vvv`
  (request and response bodies) verbose levels — additive and orthogonal to this
  tool's stdout JSON parsing. Generator command ingests Jamf Pro 11.27.0
  monolith OpenAPI spec — improves command coverage upstream without affecting
  any commands this tool already calls.

## [1.2.0] - 2026-04-20

### Added

- **`export-reports` command** — generates dated, filtered CSV snapshots from the
  wide `automation_inventory_*.csv` produced by `launchagent-run --mode jamf-cli-full`.
  Configured via the new `export_reports` list in `config.yaml`.  Each entry defines
  a name, output directory, filename template (`{ts}` is replaced with a timestamp),
  schedule (`daily`, `mon,wed,fri`, `1st-of-month`, etc.), optional row filter
  (`within_days` or `exclude_values`), and optional column selection/rename map.
  State files in `jamf-cli-data/state/export-<name>.last` prevent double-writes
  within the same day.
- `export-reports` runs automatically as the final step of
  `launchagent-run --mode jamf-cli-full` when `export_reports` entries are
  configured; exported paths are recorded in the automation status JSON.
- `Config.export_reports` property (returns `list[dict]`, empty list default).
- **`sheets.only`** config list — when non-empty, only the named workbook tabs
  are written. This takes precedence over `sheets.skip` and supports focused
  workbooks such as patch-only, security-only, or mobile-only exports.
- **`sheets.skip`** config list — named workbook tabs can now be skipped during
  `generate` and `school-generate`, including CSV-backed sheets, custom EA tabs,
  and auxiliary tabs such as `Report Sources` and `Charts`. Sheet names are
  matched case-insensitively and unknown names emit a warning.
- **`automation.generate_html` / `generate_xlsx` / `generate_inventory_csv`**
  config flags — LaunchAgent automation can now produce timestamped HTML,
  xlsx, and inventory CSV artifacts per scheduled run, including `snapshot-only`.
- `launchagent-run` status JSON now records separate xlsx, HTML, and inventory
  CSV output paths when those artifacts are produced.
- `cmd_html()` now archives older timestamped HTML outputs using the same
  `output.archive_enabled` / `keep_latest_runs` retention rules as xlsx reports.

### Changed

- Tracked jamf-cli dependency updated to v1.11.0. No code changes required:
  the field-candidate and fallback logic already handles the v1.10.0 change
  where `pro mobile-devices list` switched to the detail endpoint with nested
  `general.*` JSON fields; the `MOBILE_INVENTORY_FIELD_CANDIDATES` dictionary
  already covers both flat and nested key shapes.
- `pro computers-inventory` remains the primary command namespace in v1.10.0;
  `computers` / `comp` are now registered as aliases pointing to it, so all
  existing calls to `pro computers-inventory patch` continue to work unchanged.
- New v1.11.0 subcommands `pro classic-account-users list` and
  `pro classic-account-groups list` are not yet used by this tool; flagged here
  for future consideration as a backup-coverage sheet.
- Tracked jamf-cli dependency updated to v1.12.0. No code changes required.
  Notable upstream changes in v1.12.0: `apply` now works for PATCH-only resources
  (vpp-locations, computers-inventory, adcs-settings, digi-cert-settings,
  mobile-device-groups-static-groups, patch-software-title-configurations,
  team-viewer-remote-administrations, venafis) — this tool does not use `apply`.
  The `--rename` flag was renamed to `--name` for `device-enrollment-instances`
  create/update/apply operations — this tool only uses `device-enrollment-instances list`
  and is unaffected. `config show`, `config list`, and `config validate` now accept
  `-o` for structured output (json, yaml, csv, table, plain) — additive, no impact.
- Tracked jamf-cli dependency updated to v1.13.0. No code changes required.
  Notable upstream changes in v1.13.0: `--installation-priority` added to package
  upload commands — this tool does not upload packages. `--custom-payload-file` and
  `--custom-payload-domain` added for classic macOS config profile create/update —
  this tool only uses `classic-macos-config-profiles list` and is unaffected.
  Help command examples now consistently include the `pro` prefix — cosmetic/docs
  change, no impact on CLI syntax or on the help-output parser used for command
  discovery. HTTP client internals (streaming multipart, shared transport) improved
  with no CLI surface change.

## [1.1.0] - 2026-04-16

### Added

- Added **Active Devices** sheet to the jamf-cli workbook showing total, active, and
  inactive device counts against the `thresholds.stale_device_days` window.
- Added adjusted compliance columns to **Patch Compliance**: Adjusted Up To Date,
  Adjusted Out Of Date, Adjusted Total, and Adjusted Completion %. These columns scale
  raw patch counts by the active-device ratio so stale/offline devices don't deflate
  reported compliance. If device-compliance data is unavailable the adjusted columns are
  silently omitted and raw columns remain unchanged.
- Added Jamf School reporting support for `jamf-cli school` data (jamf-cli 1.7+) and
  Jamf School device CSV exports.
- Added `school-generate`, `school-collect`, `school-scaffold`, and `school-check`
  commands.
- Added Jamf School workbook sheets for inventory, OS versions, device status, stale
  devices, overview, device groups, users, classes, apps, profiles, and locations.
- Added **Cleanup Analysis** section to the HTML report. Surfaces disabled policies,
  unscoped policies, unscoped macOS profiles, unused packages, and unused scripts — each
  in its own tab with a count badge. The section appears only when per-policy and
  per-profile detail JSON is cached on disk (populated by the `collect` step). If no
  detail cache exists, the section is omitted silently.
- Added **macOS Adoption Timeline** chart to the HTML report. Requires
  `html.track_history: true`; the chart appears once two or more point-in-time snapshots
  exist for the same instance.
- Added `scripts/demo.sh` as a supported offline demo runner that generates fixture-backed
  HTML, Jamf Pro workbook, mobile CSV workbook, and Jamf School workbook outputs without
  requiring a live tenant or local maintainer workspaces.

### Changed

- Extended the config and documentation surface to cover Jamf School mappings and
  workflows.
- Documented the committed fixture corpus as the supported no-credentials demo path for
  the community repo and replaced README workspace examples that implied local demo
  workspaces.

### Fixed

- Fixed a cache lookup bug in `_latest_cached_json` where `rglob` was matching JSON files
  inside per-ID detail subdirectories (e.g. `classic-policies/14/`) when querying the
  parent directory. Changed to non-recursive `glob` so list-level and detail-level caches
  are not confused.
- Fixed HTML report JavaScript being completely non-functional (dark mode, table sorting,
  search, CSV export all broken). The `_js()` method used a plain triple-quoted Python
  string, causing `\r` and `\n` to be emitted as literal CR/LF bytes inside JavaScript
  regex patterns and string literals, producing a parse error that silently broke the
  entire `<script>` block. Fixed by switching to a raw string (`r"""..."""`).

### Changed

- Removed the DevliegereM attribution link from the HTML report footer. Credit is
  retained in source-code comments. Public-facing documentation and the wiki continue
  to credit the original project.

## [1.0.0] - 2026-04-14

### Added

- Initial tagged community release of the single-file Jamf reporting tool.
- Config-driven Jamf Pro CSV reporting with scaffold, validation, collection, and report
  generation workflows.
- Optional `jamf-cli` integration for live snapshots and expanded workbook coverage.
- Release packaging automation for tagged GitHub releases.
