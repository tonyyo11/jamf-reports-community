# jamf-cli First

JamfReports is built on a single architectural decision: `jamf-cli` is the data
source. It is the only thing that talks to Jamf. Everything else, the SwiftUI app and
the cached JSON files on disk, is an orchestrator around it. Rendering is separate:
the native Swift `ReportEngine` turns the cached JSON into workbooks and HTML, and the
same binary also ships a `jamf-reports` command-line interface (see
[`docs/wiki/07-Command-Line.md`](../wiki/07-Command-Line.md)).

## Why

- **Auth is hard.** Jamf Pro's OAuth2 client credentials flow, token refresh, and
  multi-tenant profile management are already solved by `jamf-cli`. Re-implementing
  them in Swift would duplicate work and create a second auth surface to audit.
- **API surface drift.** Jamf Pro adds and renames endpoints constantly. `jamf-cli`
  ships updates within days. By depending on it, the app gets that drift handled for
  free.
- **Operator portability.** Anything the GUI can do, an operator can also do from a
  terminal. A jamf-cli command and a button in the app produce the same JSON in the
  same on-disk location.
- **Auditability.** Every Jamf Pro API call is observable as a jamf-cli invocation
  in the Run History tab and in the run logs under `<workspace>/automation/logs/`.

## Composition

```
+--------+      +-------------------+      +------------+      +-----------+
|  You   | ---> |  JamfReports.app  | ---> |  jamf-cli  | ---> | Jamf Pro  |
+--------+      +-------------------+      +------------+      +-----------+
                       |   |   ^                  |
                       |   |   |                  v
                       |   |   |          OAuth token in
                       |   |   |          jamf-cli keychain
                       |   |   |
                       |   |   +-- read cached JSON for rendering
                       |   |
                       |   +------ writes config.yaml, ScheduleStore;
                       |           one bundled background item runs --tick
                       |
                       +---------- spawns jamf-cli with --output json,
                                   captures stdout/stderr, parses, caches
```

Three on-disk surfaces glue the system together:

- **`~/Jamf-Reports/<profile>/config.yaml`** — column mappings, thresholds, what to
  collect. Edited by the wizard and by the operator.
- **`~/Jamf-Reports/<profile>/jamf-cli-data/`** — cached snapshots from every
  jamf-cli call, one folder per kind: `<kind>/<kind>_<yyyyMMdd'T'HHmmss>.json`, with a
  `manifest.json` beside them when `jamf_cli.require_manifest` is on and per-kind
  `state/` files. The source of truth for the rendering pipeline.
- **`~/Jamf-Reports/<profile>/snapshots/`** — dated CSV snapshots and per-run
  `summary.json` files for the Trends tab.

## Call composition

When you click Generate in the Generated tab, the app does roughly this:

1. Resolve the active profile via `WorkspaceStore` and `ProfileService`.
2. Determine which sheets the chosen template needs.
3. For each sheet, look at `jamf-cli-data/` for fresh-enough JSON.
4. For any stale or missing data, spawn `jamf-cli` with the right subcommand,
   stream stdout/stderr to the Run History tab, and write the JSON back to
   `jamf-cli-data/`.
5. Hand the JSON tree to `ReportEngine`, which dispatches to `CoreDashboard`,
   `CSVDashboard` (if a CSV is present), or `HtmlReport` for HTML output.
6. Write the artifact to `Generated Reports/`.

The same flow runs from scheduled runs (the bundled `--tick` background item,
`--scheduled-run`, or the `jamf-reports` CLI), with the GUI-only steps (Run History
tab streaming, artifact reveal) replaced by per-run log files.

## What lives where

| Surface              | Owner       | Notes                                                |
|----------------------|-------------|------------------------------------------------------|
| Auth tokens          | jamf-cli    | macOS keychain, never read by the app                |
| Tenant URL + client  | jamf-cli    | Stored in the jamf-cli profile                       |
| Cached JSON          | App         | `~/Jamf-Reports/<profile>/jamf-cli-data/`            |
| Column mappings      | App         | `config.yaml`                                        |
| Generated artifacts  | App         | `Generated Reports/`                                 |
| Schedules            | App         | `ScheduleStore`: `~/Library/Application Support/JamfReports/schedules.json`; managed schedules are derived from the Automation policy, not stored |
| Background item      | App+macOS   | One `SMAppService` agent inside the app bundle, runs `--tick` |
| Logs                 | App         | `<workspace>/automation/logs/`                       |

## What this is NOT

- Not a Jamf Pro replacement. The app does not write to Jamf Pro.
- Not a self-contained API client. Collecting needs `jamf-cli`: the app looks for it in
  fixed directories (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`,
  `/usr/sbin`, `/sbin`), not on `PATH`, and checks its code signature before every
  launch. Rendering from snapshots already on disk (the `jamf-cli-only` schedule mode,
  generating from cache, a CSV-only profile) launches no jamf-cli.
- Not a daemon. The app starts no background process of its own. The one background
  item is a user `SMAppService` agent, declared inside the signed bundle, that runs
  `--tick` and only does work when a schedule is due. It exists only when something is
  scheduled, and macOS can require the operator to approve it.

## Implications for contributors

When adding a feature that needs new Jamf Pro data:

1. Confirm `jamf-cli` already exposes a subcommand that returns it. If not, the
   feature blocks on a jamf-cli release first.
2. Wire the subcommand into the `CLICommand` enum (`Services/CLICommand.swift`),
   not a bespoke `CLIBridge` method.
3. Add a decoder under `Engine/JamfCLIDecoder.swift` for the JSON shape.
4. Cache the JSON with `ReportEngine.saveSnapshot` under `jamf-cli-data/<kind>/`, and
   add the kind to the collect matrix and `knownCollectKinds` in `ReportEngine.swift`.
5. Render from the cached JSON in the relevant dashboard module.

The app never bypasses the cache. Every read goes through `jamf-cli-data/`, even when
the data was just collected in the same run. This keeps the Trends tab, the Reports
tab, and scheduled runs in lockstep.
