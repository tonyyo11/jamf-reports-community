# Automation Trust

Unattended reporting has a failure mode that silent success can hide: the schedule stops
firing, or fires and fails, and nobody notices because there is no error on screen. This
page covers the three features that tell you your automation is actually running — the
dead-man switch, metric alerts, and webhook notifications.

For how to set up schedules in the first place, see
[Scheduling & Automation](05-Scheduling-and-Automation).

## The dead-man switch

The dead-man switch treats the **absence** of a run as signal. It looks at every JamfReports
LaunchAgent — managed or hand-built — and flags two conditions:

- **Overdue** — the schedule is enabled, it should have fired at some past time, that
  expected fire plus a **60-minute grace window** has elapsed, and no run has recorded a
  finish at or after the expected fire. In short: it should have run and produced nothing.
- **Failing** — a run did record, and its most recent result reported failure.

A schedule can be both; overdue takes precedence, so you see the more urgent "nothing ran"
state first. Disabled schedules never raise an issue. The grace window absorbs launchd
jitter, a slow collect, and clock skew without hiding a genuinely missed run.

The expected fire time is computed backward from the schedule's `StartCalendarInterval`;
the last-run result comes from the per-run status records the scheduled-run path writes
(`<label>_status.json` and the per-profile run status for all-profiles agents).

### Where it surfaces

- **Overview banner** — when any schedule is overdue or failing, the Overview screen shows
  a banner with an **Open Automation** action.
- **Automation Health section** — the Automation screen lists each overdue/failing schedule
  with its expected-fire and last-run detail, or "All scheduled runs on time."

### When it re-evaluates

The health state is recomputed:

- At **app launch**, on the same pass that reconciles managed automation.
- When the app **returns to the foreground** (Mac wake / app focus).
- On the **Overview screen's refresh** (its banner recomputes with the tab's data).

### Headless coverage

The GUI is not the only thing that checks. Every headless scheduled run, at the end of its
work, evaluates the whole set of sibling schedules and can post the overdue digest itself —
so a host that only ever runs on a timer (never opening the app) still gets overdue
notifications, provided at least one schedule is still firing to do the checking.

The once-per-day marker for the overdue digest is a file in the workspace
(`overdue-notify`), shared between the GUI and the headless path, so the digest is sent at
most once per calendar day no matter which one notices first.

### The honest limitation

If **every** schedule stops firing on a host that **never** opens the app, nothing is left
to evaluate — the checker itself is a scheduled run, and if all of them are dead, none runs
to raise the alarm. For that total-silence case, an **external monitor** (an MDM
extension attribute on the LaunchAgents, a heartbeat check, or a report-freshness alert on
the output directory) is the only cover. The dead-man switch protects against one schedule
failing while others keep running; it cannot report its own host going fully dark.

## Metric alerts

Metric alerts watch the numbers in the daily summary and fire when a threshold is crossed.
They are configured in the `alerts:` block of `config.yaml` and are **off by default**.

Each rule names a metric, a comparison, a threshold, and (for `drops_more_than`) an optional
lookback:

```yaml
alerts:
  enabled: true
  rules:
    - {metric: "filevault_pct", when: "below", threshold: 90}
    - {metric: "patch_pct", when: "drops_more_than", threshold: 5, lookback_days: 7}
    - {metric: "stale_count", when: "above", threshold: 50}
```

**Comparisons (`when`):**

- `below` — fires when the value is below the threshold.
- `above` — fires when the value is above the threshold.
- `drops_more_than` — fires when the value fell by more than the threshold (percentage
  points for percentage metrics) versus a prior summary. `lookback_days` (default 7) sets
  how far back the prior is read; it is ignored by `below`/`above`.

**Metric keys.** Thirteen are percentages or 0–100 scores; three are whole-number counts:

| Percentages / scores | Counts |
|---|---|
| `filevault_pct`, `compliance_pct`, `os_current_pct`, `patch_pct`, `sip_pct`, `firewall_pct`, `gatekeeper_pct`, `secure_boot_pct`, `bootstrap_pct`, `xprotect_pct`, `cve_pct`, `mscp_score_pct`, `security_score` | `stale_count`, `action_items_p0`, `total_devices` |

### How and when alerts fire

- **Only on runs that collect.** Alerts evaluate after a run that produced a fresh summary
  — `snapshot-only`, `jamf-cli-full`, or `csv-assisted`. A `jamf-cli-only` run generates
  from cache and never evaluates alerts.
- **A rule whose metric has no data that day never fires.** Missing data is not an alert —
  that gap is the dead-man switch's job, not an alert's.
- **`drops_more_than` needs history.** It only fires when a prior summary at least
  `lookback_days` old exists. It also deliberately skips a `compliance_pct` comparison that
  spans a measurement-basis change (the four-control proxy versus a real mSCP failure
  count), so switching on `compliance.baselines` does not fabricate a large false drop.
- **Once per day per rule.** A second same-day run does not re-card a rule that already
  fired, but a rule that trips for the first time later the same day still alerts.
- **One card per run.** When at least one rule trips, a single attention-styled card is
  posted with a fact per tripped rule.

Metric alerts reuse the `notify:` webhook and add no URL of their own, so they require
`notify:` to be enabled with an `https://` URL. If alerts are enabled but no usable webhook
is configured, the run warns loudly (Console and Run History) rather than going silent.

A rule with an unknown metric or comparison, or a missing/invalid threshold, is ignored
rather than failing the whole config — and each ignored rule is surfaced in the in-app
**Config Doctor** (the Alerts checks), in the logs, and in Run History, so a typo is
visible rather than a quiet no-op.

## Webhook notifications

All of the above — plus routine run digests — reach you through one opt-in webhook per
profile. Configure it in the `notify:` block of `config.yaml`, or in the **Notifications**
section of the Automation screen (enable, choose Microsoft Teams or Slack, paste the
`https://` incoming-webhook URL, pick a detail level, and send a test card):

```yaml
notify:
  enabled: false
  provider: "teams"   # teams | slack
  url: ""             # https:// incoming webhook URL
  detail: "full"      # full | minimal
```

Four kinds of card are posted:

- **Run digest** — after a successful scheduled run (report name, status, profile).
- **Failure** — a run that errored, in a red/attention style.
- **Metric alert** — a tripped threshold, in an attention style with ⚠️.
- **Overdue** — the dead-man digest when a schedule missed its run.

### Egress discipline

Cards are a doorbell, not a data channel. They carry aggregate metrics, statuses, and
operational names (profile, schedule name, run status) only — **never report files or
device-level rows**. Failure text is redacted before it leaves the host. The webhook URL
must be `https://`; an `http://` URL is refused and the Notifications panel warns that
nothing will send.

For a high-security or headless deployment, set `detail: "minimal"`. Minimal reduces every
card to event facts — counts and statuses such as "2 alert rules tripped", "run failed", or
"1 schedule overdue" — with no metric values, no error text, and no schedule names. The
card becomes a signal that something happened, with the detail kept on the host.

## See also

- [Scheduling & Automation](05-Scheduling-and-Automation) — managed automation, the
  per-schedule builder, run modes, and collection cadence.
- [Security & Operational Considerations](10-Security-and-Operational-Considerations) —
  the webhook egress and LaunchAgent threat model.
- [Diagnostics & Troubleshooting](09-Diagnostics-and-Troubleshooting) — the Config Doctor
  and Run History.
