# Security & Operational Considerations

This page covers secure workspace management, automation integrity, and audit trail
practices for fleet reporting in regulated environments.

## Cloud Sync and Workspace Boundaries

**Do not cloud-sync workspaces or LaunchAgent plists to consumer cloud storage** (OneDrive,
iCloud Drive, Google Drive, Dropbox, etc.). 

- **Workspace data** (`~/Jamf-Reports/<profile>/`) contains fleet inventory at rest: device
  serials, usernames, security posture, compliance status, and application inventory. 

- **LaunchAgent plists** (`~/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.*.plist`)
  contain automation policy, schedule cadence, and webhook URLs — and can be modified by a
  synced-cloud write to change when, how, and where your reports run. launchd executes
  whatever plists are present without a write-permission check once they land on disk.

- **Implication:** a compromise of the cloud account or a cloud-provider infrastructure
  breach can alter your automation policy or exfiltrate fleet data without re-authentication.

If you use cloud storage, keep workspaces and LaunchAgents local. Use your MDM, version
control (GitHub/GitLab), or SIEM integration to back them up instead.

## Configuration Integrity

**`config.yaml` retention settings are honored when synced.** The `retention.mode` setting
(archive or delete) and `retention.snapshot_keep_days` are read from `config.yaml` at
collect time, not stored in the app. If a synced config is modified to `mode: delete` and
`snapshot_keep_days: 1`, a snapshot collection will purge older raw data before you notice.
Note that `retention.enabled` is **off by default** — raw `jamf-cli-data/` snapshots are
kept indefinitely until an admin opts in, so this risk only applies to workspaces that
have already turned retention on.

**`jamf_cli.require_manifest` hardens against tampered snapshots.** When set to `true`,
each collected raw snapshot gets a sibling SHA-256 `manifest.json`, and every report-
generation entry point (xlsx, HTML, PDF, School) refuses to run at all if the newest
snapshot in any kind folder fails verification (hash mismatch or a corrupt manifest) —
rather than silently generating a report from tampered data. It does not trigger on
`absent` or `omitted` results, since legacy snapshots and partial collects cannot be
retroactively verified. Off by default.

**Recommendation:** store `config.yaml` in version control (local git, internal GitHub, etc.)
if your operational security practices require configuration audit trails. Generated reports
themselves do not need version control — only the input config.

## Audit Trail and Log Retention

**Run logs and status files are local and self-pruning.** The app keeps the newest 50 run
logs in `~/Jamf-Reports/<profile>/automation/logs/` and cleans up older ones automatically.

**In regulated environments**, collect and ship logs to your SIEM (Splunk, Elastic, etc.)
for a durable audit trail, especially for the write-path `patch-managed` command:

```bash
# Example: tail-ship logs to syslog
tail -f ~/Jamf-Reports/<profile>/automation/logs/*.log | nc -q1 siem.example.com 514
```

Logs include timestamps, profile name, command, exit status, and error details — but NOT
credential/secret material (always redacted). The `patch-managed` command logs device IDs
affected and the managed-state change requested.

## Diagnostic Bundle Redaction Scope

**`diagnostic-bundle` redacts credentials and most PII, but not bare IP addresses.**

The diagnostic bundle includes:

- Redacted `config.yaml` (secrets always removed)
- Recent logs (secrets redacted)
- Snapshots (PII redacted with stable hash placeholders: `device-<8hex>`, `serial-<8hex>`)
- Workspace tree listing (paths visible, but no data)

**Exception:** if your Jamf Pro instance is addressed by IP (e.g., `https://192.168.1.10/`) 
instead of a hostname, those IPs remain in the bundle. Server URLs are NOT redacted by the
IP-redaction heuristic (which matches only hostnames with alphabetic TLDs).

**Before sharing a bundle**, review it and redact IP addresses or other infrastructure
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

## Multi-Tenant and Team Access

**Each profile is an isolated workspace; one person can manage multiple profiles.**

For team access to the same Jamf Pro instance without sharing credentials:

1. Create one `config.yaml` and workspace per person or role (e.g., `prod-ops`, `prod-audit`,
   `prod-dev`).
2. Authenticate each profile independently via the app's Onboarding flow — each gets its own
   `jamf-cli` credential.
3. Share only the LaunchAgent `.plist` files (in version control) to keep schedules in sync;
   each person runs the schedules locally.

Do not share the workspace directory (`~/Jamf-Reports/<profile>/`) or the `jamf-cli` keychain
credential across team members — use separate profiles and credentials for audit trail
isolation.

## Webhook Egress

**The opt-in `notify:` webhook digest never carries report files or device-level rows —
only aggregate metrics, statuses, and operational names** (profile, schedule label, run
status, counts). It requires `notify.url` to be `https://`; an `http://` URL is treated as
not usable and no send is attempted.

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

**The app's "Automation" policy is declarative, not scriptable.** Setting a master toggle
installs or removes the managed LaunchAgent plists and validates policy changes in real
time.

- **On enable:** the app installs up to four agents (freshness, scan, reports, backup),
  signed with your chosen schedule times, and logs the installation to Run History.
- **On disable:** the app removes those agents and logs the removal.
- **On change:** the app diffs the policy, applies only the differences, and never
  overwrites hand-built schedules (exact name match required for ownership).

The policy JSON is stored in macOS AppStorage (not visible from the CLI, and there is no
export/import affordance in Settings). To move an automation policy to another Mac,
re-create the same settings on the **Automation** screen — reconcile derives and installs
the same LaunchAgents from the policy on any host running the app, so there is nothing
else to migrate.

The same Automation screen that hosts this policy also drives the opt-in Notifications
webhook and shows Automation Health (the dead-man switch for overdue or failing
schedules) — see [Automation Trust](https://github.com/tonyyo11/jamf-reports-community/wiki/05b-Automation-Trust).
