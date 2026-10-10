# Security & Operational Considerations

This page covers secure workspace management, automation integrity, and audit trail
practices for fleet reporting in regulated environments.

## Cloud Sync and Shared Workspaces

Two layouts are supported, and they answer different questions. Pick the
narrower one that does what you need.

| You want | Layout | What syncs |
|---|---|---|
| Teammates to **read the reports** | Publish | Finished workbooks and HTML only |
| Several Macs to **run the reporting** | Shared workspace | Everything, including raw device data |

### Publish: share the reports, keep the workspace local

The narrowest option. Keep the workspace on local disk and point only the
generated reports at the shared folder:

```yaml
output:
  allow_absolute_paths: true    # required for any path outside the workspace
  output_dir: "~/Library/CloudStorage/OneDrive-Contoso/Team/Jamf Reports"
```

Raw snapshots, run logs, backups, and `config.yaml` stay local, where their
permissions and single-writer assumptions still hold. Run Check confirms this
with a green **"Reports publish to …"** row.

`~` is expanded; a folder the app will not use is named in the run log and
reports go to `Generated Reports` in the workspace.

The Reports screen lists the folder the reports go to, and Reveal in Finder, Open and
Quick Look work there for that profile. Nothing else outside the workspace is opened, and a
system or credentials folder typed as `output_dir` is never used, so it is never opened
either.

`~/Library` is otherwise off-limits to output paths, but `~/Library/CloudStorage`
is deliberately carved out — that is where macOS mounts every modern sync
provider, and it holds user data rather than application state.

### Shared workspace: several Macs, one history

Choose the folder in **Settings → Workspace location**. Every profile, snapshot,
report and trend then lives there, and any Mac pointed at it contributes to one
pooled history rather than keeping a private copy.

That path is per-Mac and is stored in this Mac's preferences, not in
`config.yaml` — a sync provider mounts the same team folder under each user's
home, so `/Users/alice/Library/CloudStorage/…` on one machine is
`/Users/bob/…` on the next. What every machine must agree on lives in the
workspace's own config:

```yaml
shared_workspace:
  enabled: true                  # omit to decide from the folder itself
  claim_ttl_minutes: 45          # how long a run's claim stays valid
  min_collect_interval_hours: 12 # 0 disables the freshness check
```

Coordination turns itself on when the workspace is on a synced volume. Two
guards then run:

- **Freshness.** A scheduled collect stands down when another Mac collected
  inside `min_collect_interval_hours`, naming which one and when. Pressing
  Refresh in the app always collects anyway — an explicit request wins.
- **Claims.** Each run publishes a short lease at
  `automation/.workspace-claim.json` naming the host, the operation and an
  expiry, so a second machine can see one is already working. A machine that
  sleeps or shuts down mid-run leaves its claim behind; expiry is what lets the
  next run take over rather than waiting forever.

Each Mac also records its own last run under `automation/hosts/<host-id>.json`
— one file per machine, never a shared one, so this state cannot itself produce
conflict copies.

**The claim is advisory, not a lock.** Sync is eventual, so two machines
starting within seconds of each other can both proceed. Nothing is corrupted
when that happens: snapshots are written under unique timestamped names and read
back in filename order, never by modification date. You simply get two collects
where you wanted one.

**Coordination covers Jamf Pro collects only.** A Jamf School profile on a
shared workspace gets none of the stand-down or claim behavior above, by design
— School collects on its own schedule with no cross-Mac awareness. Jamf Protect
runs only after a Jamf Pro collect that actually collected: when the Pro collect
stands down for another Mac, or skips because today's collect already ran,
Protect is skipped with it and the run log says so.

**Every Mac must reach Jamf the same way under the same profile name.** The
workspace's `config.yaml` names the jamf-cli profile collects use
(`jamf_cli.profile`), but each Mac looks that name up in its own jamf-cli
configuration and keychain, which never sync. Give every Mac a jamf-cli
profile of that name that reaches the same Jamf Pro instance the same way:
all direct, or all through the Jamf Platform API with the same environment
ID. If one Mac's profile points elsewhere, its collects either write another
instance's data into the shared history or fail where the others succeed, and
each screen shows whichever Mac collected last. Compare `jamf-cli config list`
on each Mac when you add it.

### Adding another Mac

Once one Mac has its workspace in the shared folder, do this on each Mac that joins it:

1. Install the same app version the other Macs run.
2. Install `jamf-cli` and create the profile `config.yaml` names in `jamf_cli.profile`,
   reaching the same instance the same way (above), with this Mac's own credential (see
   [Multi-Tenant and Team Access](#multi-tenant-and-team-access)). Give its API client the
   same privileges as the others. Failure counts live in the workspace, so a privilege one
   Mac lacks shows up as a failing source on every Mac.
3. Sync the team folder and keep it downloaded (OneDrive's **Always Keep on This Device**,
   or your provider's equivalent). A file that exists only in the cloud is fetched the first
   time the app reads it, which slows Trends and report generation and fails offline.
4. Make sure `config.yaml` holds no absolute path that only exists on the first Mac, such as
   `/Users/alice/…` in `data_dir`, `output_dir` or an archive folder. Use a path relative to
   the workspace, or start it with `~/`.
5. Launch the app. When jamf-cli already has a profile, first launch opens **jamf-cli is
   already set up**. Under **Already have a workspace folder?**, click **Choose workspace
   folder…** and pick the folder that contains the profile folders, not a profile folder
   itself, then confirm the shared-folder notice. Skip **Initialize & run first
   collection**: the workspace already exists. On a Mac that already uses the app,
   **Settings → Workspace location** does the same.
6. Leave automation off. One Mac should run the schedules; see
   [Several Macs, one workspace](https://github.com/tonyyo11/jamf-reports-community/wiki/05-Scheduling-and-Automation#several-macs-one-workspace).
7. Run **Config → Run check**. It should list the other Macs and raise no version or clock
   warning.

If first launch shows the Welcome chooser (**Connect Jamf Pro**, **Try the demo first**)
instead, the app found no jamf-cli profile. Fix jamf-cli rather than running onboarding,
which creates a separate, empty workspace under `~/Jamf-Reports`.

### What a shared workspace still costs you

**Everyone with folder access can read the fleet's PII.** `jamf-cli-data/`
snapshots and `automation/logs/` hold device serials, hostnames, usernames, real
names, email addresses, job titles, phone numbers and rooms in the clear, and
`config.yaml` holds any webhook URL you have configured. The app writes them
`0600` inside `0700` directories, but POSIX
permissions are enforced by the local kernel — a sync provider does not
replicate them. Whoever can open the SharePoint site can read the files, the
server-side search index can surface their contents, and a Windows client has no
POSIX permission model at all. `.metadata_never_index` suppresses local
Spotlight only; it does nothing server-side.

This is the one thing coordination does not solve. The app asks you to confirm
it when you choose the folder, and Run Check repeats it on every shared
workspace — but the decision is yours to make and to justify. In a regulated environment, decide deliberately who the
folder is shared with, and get it reviewed before the first collect. If the
audience for the reports is wider than the audience for device-level inventory,
use the publish layout instead — or both: a private shared workspace plus an
`output_dir` pointing at a wider folder.

**Backups are pruned per-machine.** Each scheduled backup records the Mac that
made it, and each machine prunes only its own — an unscoped prune would spend
one machine's retention budget on everyone's backups. Backups made before this
version carry no ownership record and are never auto-removed, so clear those out
once by hand.

**Config copies.** Before a save or a scaffold drops text from config.yaml,
the app copies it to `config.yaml.bak-<date-time>` beside it (the newest five
are kept). The copy holds whatever the file holds, including a webhook URL,
and sits in the same folder, so on a synced workspace it syncs like
config.yaml itself.

**Keep every Mac on the same app version.** Versions before 2.7.0 order
snapshots by modification date and prune backups without checking whose they
are. Run Check warns when it sees a peer reporting a different version.

**Clocks matter.** Freshness compares timestamps written by different machines,
so leave "Set date and time automatically" on everywhere. Run Check warns when a
peer's timestamps are more than five minutes ahead.

**Conflict copies.** When two machines do write the same file at once, providers
keep both as `summary_2026-08-20 2.json` or `computers_… (1).json`. The app
ignores any file whose name is not in canonical form, so no report is ever built
from a duplicate. Run Check lists them so you can delete them; if they keep
appearing, raise `min_collect_interval_hours`.

**Per-machine scheduling state is never safe to sync.** The background item is
registered per machine from the app bundle itself — there is no separate file
for it in the workspace to accidentally sync. `~/Library/Application
Support/JamfReports/schedules.json`, which holds hand-built schedules, is also
per machine and must not be synced: launchd-adjacent tooling and the app both
execute whatever a schedule record names without a write-permission check, so
a synced schedules.json turns a cloud-account compromise into arbitrary
scheduled execution on every machine sharing it. Legacy plists imported from a
pre-2.8.0 install stay local too, always — including on a shared workspace,
where only the data moves. Legacy plists the app archives into the workspace
have their webhook URLs scrubbed, precisely because that archive often ends up
on one.

**`jamf_cli.require_manifest` and a shared workspace don't mix well.** If two
Macs happen to write a snapshot with the same filename stamp — a same-second
collision — the surviving file after sync may not be the one whose hash was
recorded, leaving a manifest that mismatches the file on disk and blocks
generate until you delete the manifest by hand. Leave `require_manifest` off
on a shared workspace.

**A scheduled run needs the folder mounted to start at all.** If the shared
folder isn't mounted when the background item's tick fires, the run can't
reach its workspace and nothing is written — no log line, no entry in Run
History. The Automation Health overdue check is what surfaces this: the
schedule simply looks like it stopped firing.

**`retention.snapshot_keep_count` counts files, not days per Mac.** The count
floor keeps the newest N snapshot files in a kind's folder regardless of which
Mac wrote them. With N Macs collecting daily into the same shared folder, that
floor protects roughly `keep_count / N` days of any one machine's history.

**Backup diffs: Raw mode is unredacted.** Summary mode and its Copy button
redact credential-shaped values (password hashes, recovery keys, and similar);
Raw mode shows the full payload as jamf-cli returned it.

### Check it

**Config → Run check** reports the whole picture for the active profile: which
layout is in effect, whether the workspace folder is reachable and writable,
which other Macs write there and when each last collected, whether their clocks
and app versions agree, any live or stale claim, and every conflict copy it can
see — each with what to do about it.

## Configuration Integrity

**A shared `config.yaml` can be edited by any Mac that can write the folder, so each Mac
pins what matters.** On a shared workspace (a sync-provider or `/Volumes` folder, or
`shared_workspace.enabled: true`), every Mac reads the same `config.yaml`, and several things in
it decide where data goes or what runs: the report, archive, data and chart-history folders with
`output.allow_absolute_paths`, the retention switch, `retention.mode` (archive or delete) and
`retention.archive_dir`, the `protect.profile` this Mac collects from, the `notify.detail` level,
and the `notify.url` webhook. Each Mac records the values it was set up with in its own
Application Support folder (for the webhook only the host and port and a SHA-256 of the URL,
never the URL) and compares them with `config.yaml` at the start of every collect and report.
If a value changed, a scheduled run, the background item, an automatic collect in the app or the
`jamf-reports` command on that Mac keeps to a safe value for that key: reports go to the
`Generated Reports` folder in the workspace, a changed data or chart-history folder reads as its
default, retention archives and never deletes, a changed Protect profile skips Protect, a changed
detail level sends `minimal`, and a changed webhook sends nothing. The run log gets one
`[warn] shared config changed <key>` line per key, and the run still counts as successful. A
collect or report you start yourself in the app keeps reading `config.yaml` as typed, and Config
Doctor carries the warning. Setting `shared_workspace.enabled: false` in the shared file does not
turn pinning off on a Mac that already pinned, and that setting is itself pinned.

The first time a Mac sees a shared workspace it pins what the file holds, but an absolute folder
outside the workspace and `retention.mode: delete` already in the file count as unconfirmed:
background runs use the safe values for them until you confirm once. The webhook, the Protect
profile and the other keys are trusted at first sight. If the Mac's own pin cannot be read, every
key reads as changed until you confirm.

While anything waits for a confirmation, an amber strip above every screen says "Shared config
needs confirming on this Mac" and its Review button opens Config Doctor, so reports landing in
`Generated Reports` instead of your own folder are not a silent surprise. Onboarding and
`jamf-reports scaffold --out` confirm the keys the file they write sets on that Mac (the report
and data folders), and nothing else. If the app gains a pinned key in an update, a Mac that
pinned before the update pins the new key the first time it sees it.

To accept a change, open Audit, then the Config tab (Config Doctor), read the "Shared config
changed since this Mac pinned it" row, which lists each key with its pinned and current value,
and click Confirm. Confirm re-pins only the values shown, and only while the file still holds
them. Saving the output folders in the Config screen, or the notification settings, on that Mac
also confirms a key, but only one that save actually changed. A local workspace is never pinned.

**`config.yaml` retention settings are honored when synced.** The `retention.mode` setting
(archive or delete) and `retention.snapshot_keep_days` are read from `config.yaml` at
collect time, not stored in the app. A shared workspace pins `retention.enabled` and
`retention.mode` per Mac (above), so a peer's change to `delete` archives on a Mac that has not
confirmed it; on a local workspace the file is the only authority. `retention.enabled` is
**off by default** — raw `jamf-cli-data/` snapshots are kept indefinitely until an admin opts
in, so this risk only applies to workspaces that have already turned retention on.

**A peer who can write the shared `config.yaml` steers every Mac.** On a shared workspace
each Mac reads the same file, so whoever can write the folder, or the sync account behind
it, can change the output and archive folders (with `output.allow_absolute_paths`), the
retention mode, and the webhook in `notify.url` for all of them. The app refuses system
and credentials folders as output folders, but a folder it allows is used. Limit write
access to the shared folder to the reporting team, and review changes to `config.yaml`
the way you would review any file that holds a webhook URL. If this matters in your
environment, prefer the publish layout above, where `config.yaml` stays local.

**`jamf_cli.require_manifest` hardens against tampered snapshots.** When set to `true`,
each collected raw snapshot gets a sibling SHA-256 `manifest.json`, and every report-
generation entry point (xlsx, HTML, PDF, School) refuses to run at all if the newest
snapshot in any kind folder fails verification (hash mismatch or a corrupt manifest) —
rather than silently generating a report from tampered data. It does not trigger on
`absent` or `omitted` results, since legacy snapshots and partial collects cannot be
retroactively verified. Off by default.

**jamf-cli's signature is checked before use.** The app runs jamf-cli, and passes it a
client secret during setup, only when the binary carries Jamf's Developer ID signature
(team `483DWKW443`). From 2.9.0 the check asks for a certificate Apple issued to Jamf, so a
binary that merely names Jamf's team in a self-made signature is refused. If Setup says
jamf-cli failed its signature check, reinstall it from Jamf's release package or Homebrew.

**Recommendation:** store `config.yaml` in version control (local git, internal GitHub, etc.)
if your operational security practices require configuration audit trails. Generated reports
themselves do not need version control — only the input config.

## Audit Trail and Log Retention

**Run logs and status files are local and self-pruning.** The app keeps the newest 50 run
logs in `~/Jamf-Reports/<profile>/automation/logs/` and cleans up older ones automatically.

**In regulated environments**, collect and ship logs to your SIEM (Splunk, Elastic, etc.)
for a durable audit trail:

```bash
# Example: tail-ship logs to syslog
tail -f ~/Jamf-Reports/<profile>/automation/logs/*.log | nc -q1 siem.example.com 514
```

Logs include timestamps, profile name, command, exit status, and error details — but NOT
credential/secret material. As of this version credentials are masked in the log file itself
when each line is written, not only when Run History displays it.

## Diagnostic Bundle Redaction Scope

**`diagnostic-bundle` and run history log export redact credentials, most PII and IPv4 addresses.**

The diagnostic bundle includes:

- Redacted `config.yaml` (secrets and webhook URLs removed; exception approvers and
  descriptions replaced with placeholders)
- Recent logs (secrets, webhook URLs, the Jamf server address and the profile's tenant and
  environment IDs removed)
- Recent daily summaries (`summary_<date>.json`), with PII redacted by stable hash
  placeholders such as `device-<8hex>` and `serial-<8hex>`
- A workspace tree listing (paths visible, but no data)
- Version details for the app, macOS and `jamf-cli`, and the output of `jamf-cli doctor`
  with the server hostname removed

It does not include the raw `jamf-cli-data/` snapshots.

Run History's **Copy log** and **Export log…**, and the export in Settings › Logging, apply
the same redaction before the text reaches the clipboard or a file: secrets, webhook URLs
(Slack, Teams, Teams Workflows, Power Automate), the Jamf server address and the profile's
tenant and environment IDs are removed. The log on screen is not changed.

**IP addresses:** IPv4 addresses are redacted wherever they appear in the text, and so are
the values of the last-reported-IP fields (`lastIpAddress`, `lastReportedIp`). That
covers a Jamf Pro instance addressed by IP (e.g., `https://192.168.1.10/`). The IP rule
matches IPv4 addresses only. Hostnames in URLs are redacted, but other infrastructure
details, such as the paths in the workspace tree listing, stay visible.

**Before sharing a bundle or log export**, review it and redact other infrastructure
details if your security policy requires it:

```bash
# Inspect the bundle contents
unzip -l ~/Jamf-Reports/<profile>/diagnostics/jamf-reports-diagnostic-*.zip
```

## Generated Report Handling

**Reports contain MDM inventory: serials, usernames, OS versions, security posture,
compliance status, and application inventory.** These are the same fields visible in your
Jamf Pro console to authenticated users — but a generated Excel workbook or PDF is a local
file, not access-controlled.

**Recommendation:**

- Handle reports with the same care as your Jamf Pro inventory exports.
- Apply your organization's data classification (confidential, internal-only, etc.) to the
  output format (Excel/PDF watermarks, email DLP, file permissions, etc.).
- Set output permissions: `chmod 600 ~/Jamf-Reports/<profile>/Generated Reports/*.xlsx`
  (owner read/write only, no group or world visibility).
- Use `output.archive_enabled: true` to move older reports into an archive for retention
  governance (they are moved, not deleted, so you can audit/recover them).
- **The HTML report keeps device lists short because it is forwarded:** it lists at most
  100 stale Macs, 25 recent failures and 10 least-compliant Macs, and says how many more
  the workbook has. The workbook's sheets are not capped.

## Multi-Tenant and Team Access

**Credentials belong to one person or one Mac; data can be pooled.** Keep the
two apart.

- **Never share a credential.** Give each administrator, or each reporting
  Mac, its own Jamf Pro API client or Jamf Account integration, with read
  access only (see
  [Permissions & Access](https://github.com/tonyyo11/jamf-reports-community/wiki/13-Permissions-and-Access)).
  Separate credentials keep Jamf's own audit trail attributable and let you
  revoke one without breaking the rest. The jamf-cli configuration
  (`~/.config/jamf-cli/`) and its keychain items stay on each Mac; never
  sync or copy them.
- **Share data deliberately.** Keep one workspace per person or role (for
  example `prod-ops` and `prod-audit`), or pool several Macs into one
  history with a
  [shared workspace](#shared-workspace-several-macs-one-history). Never copy
  a workspace folder between machines. A shared workspace also needs every
  Mac to use the same profile name and connection, described in that
  section.
- **Schedules are per Mac.** Recreate them on each Mac with
  `jamf-reports schedules add` or the Automation screen rather than sharing
  `schedules.json`; it is per-machine state, not something to check into
  version control.

**Scope Platform API integrations narrowly.** One Jamf Account can list
several environments and tenants — test, production, beta, and instances
hosted in different places — and Jamf Account lets one integration apply to
more than one of them. Create each JamfReports integration for the single
environment its profile reports on, with read permissions only. An
integration spanning every environment, or carrying write permissions, turns
a secret leaked from one Mac into access to all of them.

## External Network Calls

**SOFA feed is the only non-Jamf host the app reaches.** When collecting, the app
fetches macOS and XProtect release dates from `sofafeed.macadmins.io` to score
currency in your security posture metrics. If your network must not reach third-party
hosts, disable this fetch by adding it to `jamf_cli.collect_skip` in `config.yaml`:

```yaml
jamf_cli:
  collect_skip: [sofa]   # or: ["sofa", "other", "kinds"]
```

The last feed fetched stays in use. With none, the macOS-current and XProtect-current
factors have no data and are left out of the Security Score (never scored as 0). Jamf Pro and Platform API calls are always to your configured
Jamf Pro server, not a third-party host.

## Webhook Egress

**The opt-in `notify:` webhook digest never carries report files or device-level rows —
only aggregate metrics, statuses, and operational names** (profile, schedule label, run
status, counts). It requires `notify.url` to be `https://`; an `http://` URL is treated as
not usable and no send is attempted.

**Scope note — the overdue digest is routed per profile.** One headless tick evaluates
*every* schedule on the machine and sends each profile's overdue schedules to that profile's
own `notify:` webhook. A fleet-wide schedule (managed automation for all profiles) goes to
every configured webhook. A profile with no usable webhook gets a warning in the run log and
its schedules are never posted to another profile's channel. Profiles that share one webhook
URL get a single card; if those profiles map to different audiences, set `notify.detail:
minimal` on any of them and the shared card carries only counts. Excluded profiles are
omitted. Each workspace sends at most one digest a day.

- **`notify.detail: minimal`** reduces every card to event facts only — counts and
  statuses ("2 alert rules tripped", "1 schedule overdue") with no metric values, no
  error text, and no schedule names. Use it for headless or high-security hosts where the
  webhook should act as a doorbell rather than a data channel. `full` (the default) sends
  metric names/values, error text, and schedule names.
- **Failure-card error text is redacted before it leaves the Mac** — the same secret and
  PII redaction used elsewhere in the app (server hostnames included) is applied to a run's
  error description before it is placed in a card fact.
- **Slack/Teams mention and link injection is escaped.** Every fact label and value is
  HTML-entity-escaped (`&`, `<`, `>`) before it enters a payload, which structurally
  destroys Slack's mention/directive syntax (`<!channel>`, `<@U123>`, `<https://…|…>`) —
  untrusted text in a fact value can never trigger a broadcast ping or a disguised link.

See [Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust) for the dead-man switch, metric alerts, and
notification setup this webhook serves.

## Managed Automation Policy and Validation

**The app's "Automation" policy is declarative, not scriptable.** Setting the master toggle
registers or unregisters the one bundled background item and re-evaluates the policy at
once — nothing else on disk changes.

- **On enable:** up to four schedules (freshness, scan, reports, backup) are derived from
  the policy on every wake of the background item — nothing is written for them — and the
  item is registered if it wasn't already.
- **On disable:** the derived schedules stop being derived immediately; the background item
  stays registered only if a hand-built schedule still needs it, and unregisters itself
  otherwise.
- **On change:** the next wake simply derives a different set of schedules from the new
  policy. There is nothing to diff or apply, and a hand-built schedule (exact label match
  required for ownership) is never touched.

The policy JSON is stored in macOS AppStorage (not visible from the CLI, and there is no
export/import affordance in Settings). To move an automation policy to another Mac,
re-create the same settings on the **Automation** screen — the same four schedules are
derived on any host running the app, so there is nothing else to migrate.

The same Automation screen that hosts this policy also drives the opt-in Notifications
webhook and shows Automation Health (the dead-man switch for overdue or failing
schedules) — see [Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust).

**Collecting and writing reports never overlap on one Mac.** The app, the background item
and the command line share one lock. Generate, Export PDF, Export Inventory CSV and Trends'
archive are refused while a collect runs ("A refresh is already running"), and a Refresh, an
automatic collect or a scheduled run asked for while a report is being written waits ("A
report is being generated — try again when it finishes"). The lock is per Mac: Macs sharing
a workspace coordinate through the shared-workspace claim described above.

## Known Issues

**`pro report security` on jamf-cli 1.24.0 through 1.27.0 requires a Jamf Security Cloud
subscription — fixed in 1.28.0.** On those releases this Jamf Pro report is routed through
the Jamf Security Cloud client and fails on any tenant without a subscription — Security
Posture, the weighted security score, and every FileVault, SIP, firewall and Gatekeeper
figure derived from it show their last collected values. jamf-cli 1.28.0 resolves the
report as Jamf Pro again, so upgrading restores all of it. If you cannot move past 1.27.0,
pin jamf-cli to 1.23.x instead; see the CHANGELOG's Known Issues entry.
