# AI Insights

Opt-in, on-device fleet insights using Apple's Foundation Models framework. Off by
default. Requires macOS 27 or later — on any earlier macOS, every AI surface is hidden
entirely, not shown as unavailable.

## What it is

Three surfaces, all built from data the app has already collected:

- **AI Fleet Insight card** (Overview) — turns the current daily summary digest into a
  plain-language headline and a short list of severity-tagged findings (info, warning,
  critical), with deltas against the prior period where available.
- **"Explain this run"** (Run History) — appears next to a failed scheduled run. Produces
  a one-sentence summary of the failure, a likely cause, and one concrete first
  troubleshooting step.
- **AI-generated executive summary** — an optional paragraph prepended to the Executive
  Summary sheet in generated `.xlsx` workbooks and the equivalent HTML report section, for
  reports generated from the app's GUI.

## Requirements and honesty about what runs where

- Requires macOS 27+ with Apple Intelligence available on the Mac.
- On macOS 26 and earlier, the Overview card and the Settings "AI Insights" panel do not
  appear at all — the app doesn't advertise a feature it can't run there.
- **Official builds run the on-device Apple Foundation Model only. No fleet data leaves
  the Mac.** Private Cloud Compute is not offered in Settings: it requires an
  Apple-granted entitlement (`com.apple.developer.private-cloud-compute`) tied to App
  Store distribution, which a Developer ID-distributed build cannot carry. Attempting to
  construct that model without the entitlement crashes the process, so the app checks for
  it first and never offers the option when it's absent — Settings shows a plain
  "Model — On-device" row instead of a picker. A build that does carry the entitlement
  (for example, a fork built for App Store distribution) gets the model picker back
  automatically, with no code change.
- An `external` tier (a bring-your-own hosted LLM) is specced in the config schema but not
  implemented. Setting `tier: external` has no effect today.

## Data-handling specifics

- **"Explain this run" is on-device only, regardless of the configured tier.** Even if
  the profile is set to Private Cloud Compute, the run-failure explainer always resolves
  to the on-device model — a log excerpt is never sent off the Mac. The log excerpt is
  also fully redacted (credential patterns, then hostnames/emails/serials/usernames)
  before it is ever stored in the value that reaches the model; there is no code path that
  can construct an unredacted excerpt.
- **The report narrative is built only from the same aggregate metrics the Executive
  Summary sheet already shows** (device counts, percentages, a security grade) — no
  device identifiers, usernames, or free-text fields reach the model.
- **The report narrative only runs during GUI-initiated report generation.** Headless
  runs — scheduled runs, the included `jamf-reports` command-line tool, and the
  Schedules "Run now" dispatcher — never call it, so scheduled/CLI reports never carry an
  AI section.
- Narrative generation is raced against a 10-second timebox; on timeout, an error, or
  empty output, the report is produced without the AI section rather than waiting.
- Model output that lands in an HTML report is escaped before insertion.
- **`lock_on_device: true`** is a high-security override: it refuses any non-on-device
  model regardless of the configured tier, for every AI surface.

## Turning it on

Settings → **AI Insights** (only visible on a macOS 27+ host):

- **Enable AI insights** — the master toggle; off by default.
- **Model** — On-device or Private Cloud Compute (the picker only appears on a build that
  carries the PCC entitlement; otherwise a static "On-device" row is shown).
- **Lock to on-device (high security)** — ignores the model choice above and never uses
  Private Cloud Compute.
- A status line reports the live availability (for example, "On-device intelligence is
  ready," "Turn on Apple Intelligence in System Settings to use insights," or the model
  still warming up).

Settings writes only the `ai:` block of `config.yaml`; every other key is left alone. The
same block can be hand-edited directly:

```yaml
ai:
  enabled: false            # opt-in; inert on macOS < 27
  tier: "on_device"         # on_device | pcc | external (external not yet built)
  lock_on_device: false     # refuse any non-on-device model even if tier says otherwise
  reasoning_level: "light"  # light | moderate | deep
```

`reasoning_level` has no dedicated Settings control today — set it directly in
`config.yaml` if the on-device model on your Mac advertises reasoning support.

## Limitations

- Output quality depends entirely on Apple's on-device Foundation Model; the app does not
  tune, fine-tune, or supplement it.
- Every AI result is advisory, not authoritative. The Fleet Insight card and the report
  narrative both carry an explicit "verify against the [metrics/tiles]" note alongside
  their output — treat the generated text as a summary of the numbers you can already see
  elsewhere on the screen or in the same report, not a new source of truth.
