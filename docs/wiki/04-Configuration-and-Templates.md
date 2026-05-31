# Configuration & Templates

`config.yaml` is the bridge between your Jamf data shape and the report logic. It maps
your tenant's column and Extension Attribute names to the logical fields the reports
expect. One `config.yaml` lives in each profile workspace.

The complete, annotated schema is the repo's
[`config.example.yaml`](https://github.com/tonyyo11/jamf-reports-community/blob/main/config.example.yaml).
Treat that file as the reference — the engine ignores unknown keys, so do not invent new
ones.

## How config.yaml is created

- **During onboarding** — the CSV-mapping step scaffolds a `config.yaml` with best-guess
  column mappings from a Jamf Pro CSV export (or a minimal config if you skip).
- **From the CLI** — `python3 jamf-reports-community.py scaffold --csv export.csv` does
  the same from the command line. `check` then validates it. See
  [CLI Workflow](07-CLI-Workflow).

Scaffolding is a starting point, not a final answer. Always review the result.

## The Config screen

![config.yaml editor](images/config-editor.png)

In the app, the **Config** screen edits `config.yaml` through seven tabs:

| Tab | What it covers |
|---|---|
| Columns | CSV column → logical field mappings |
| Security Agents | third-party agents to track (CrowdStrike, etc.) |
| Custom EAs | extra Extension-Attribute-driven sheets |
| Thresholds | stale-device days, disk-usage and compliance bands |
| Platform API | opt-in Jamf Platform API reporting |
| Output | output directory, archiving, run retention |
| Scoring | the weighted Security Score and risk-score weights |

## Reviewing column mappings

Scaffolding fuzzy-matches headers; check these common mistakes:

- `manager` must be a real manager field, not Jamf's `Managed` status column.
- `secure_boot` must map to the Secure Boot column.
- `bootstrap_token` should map to the escrowed state.
- `disk_percent_full` must be a percentage column, not free space in MB.

Field names are exact and case-sensitive — `operating_system` (not `os_version`),
`last_checkin` (not `last_contact`), `email` (not `assigned_user_email`). The
[`config.example.yaml`](https://github.com/tonyyo11/jamf-reports-community/blob/main/config.example.yaml)
header comments list every field.

## Tracked sections

- **`security_agents`** — a list of third-party agents. Each entry drives a row in the
  Security Agents sheet. `connected_value` is a case-insensitive substring match.
- **`compliance`** — a failures-count EA column and a pipe-delimited failures-list EA
  column, for mSCP / STIG reporting.
- **`sheets`** — optional `only` / `skip` lists to trim the workbook by tab name.
- **`thresholds`**, **`output`**, **`charts`** — stale-device window, disk-usage bands,
  output retention, chart toggles.

## Custom Extension Attribute sheets

`custom_eas` is a list; each entry produces one workbook sheet. Five types:

| Type | Behavior | Key fields |
|---|---|---|
| `boolean` | pass/fail counts | `true_value` |
| `percentage` | color-coded distribution | `warning_threshold`, `critical_threshold` |
| `version` | version distribution | `current_versions` |
| `text` | value frequency table | — |
| `date` | days-until-expiry, color-coded | `warning_days` |

Recipes:

```yaml
custom_eas:
  - name: "FileVault Status"
    column: "FileVault 2 - Status"
    type: boolean
    true_value: "Encrypted"

  - name: "mSCP NIST 800-53r5 Failures"
    column: "mSCP - NIST 800-53r5 Failure Count"
    type: percentage
    warning_threshold: 5
    critical_threshold: 15

  - name: "User Cert Expiry"
    column: "User Certificate - Expiry Date"
    type: date
    warning_days: 30
```

```yaml
security_agents:
  - name: "CrowdStrike Falcon"
    column: "CrowdStrike Falcon - Status"
    connected_value: "Installed"
```

After editing, open the **Health Audit** screen — each Custom EA is listed with its
column name and detected type, and any column missing from the cached data is flagged.

## The Customize screen

The **Customize** screen controls what a generated workbook contains:

- Toggle individual sheets on or off.
- Choose which metrics appear on the Overview score cards.
- Apply a template preset as a starting point.

## Report templates

The app ships five report templates. Pick one when generating; each is a curated sheet
selection, not a separate engine. All formats — XLSX, HTML, PDF — are produced by the
native Swift engine.

| Template | Audience | Cadence | Focus |
|---|---|---|---|
| Executive | Leadership | Monthly | One-screen story: managed devices, encryption, patch posture, OS adoption |
| Operational | Fleet ops | Daily | Actionable failures and intervention queues |
| Compliance | Auditors | Monthly | Jamf state tied to mSCP baselines and compliance bands |
| Asset | Asset / lifecycle | Quarterly | Hardware inventory and refresh planning |
| Security Posture | Security review | Weekly | Managed controls, security agents, EA-derived signals |

To change a template's sheet selection permanently, edit its file under
`app/Sources/JamfReports/Engine/Templates/` and rebuild — that is a code change, not a
config change.

## Platform API (opt-in)

As of v2.1.0, three conditions must all be true to enable the Platform API sheets
(blueprint status, DDM status, and benchmark-specific compliance sheets):

1. `platform.enabled: true` in `config.yaml`
2. `experimental.platform_features_enabled: true` in `config.yaml`
3. The active `jamf-cli` profile must be configured with `auth-method: platform`

Setting `platform.enabled: true` alone is no longer sufficient — the experimental gate
and the platform-auth profile are also required. The `capabilities` command reports
whether the gate is open for the current profile.
