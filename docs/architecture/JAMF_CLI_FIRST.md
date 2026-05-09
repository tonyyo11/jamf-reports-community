# jamf-cli First

JamfReports is built on a single architectural decision: `jamf-cli` is the engine.
Everything else — the SwiftUI app, the cached JSON files on disk, the Python script —
is an orchestrator around it.

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
  in the Run History tab and in `~/Library/Logs/JamfReports/`.

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
                       |   +------ writes config.yaml, schedules LaunchAgents
                       |
                       +---------- spawns jamf-cli with --output json,
                                   captures stdout/stderr, parses, caches
```

Three on-disk surfaces glue the system together:

- **`~/Jamf-Reports/<profile>/config.yaml`** — column mappings, thresholds, what to
  collect. Edited by the wizard and by the operator.
- **`~/Jamf-Reports/<profile>/jamf-cli-data/`** — cached JSON snapshots from every
  jamf-cli call. The single source of truth for the rendering pipeline.
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

The same flow runs from the LaunchAgent tiers, with the GUI-only steps (Run History
tab streaming, artifact reveal) replaced by per-run log files.

## What lives where

| Surface              | Owner       | Notes                                                |
|----------------------|-------------|------------------------------------------------------|
| Auth tokens          | jamf-cli    | macOS keychain, never read by the app                |
| Tenant URL + client  | jamf-cli    | Stored in the jamf-cli profile                       |
| Cached JSON          | App         | `~/Jamf-Reports/<profile>/jamf-cli-data/`            |
| Column mappings      | App         | `config.yaml`                                        |
| Generated artifacts  | App         | `Generated Reports/`                                 |
| Schedules            | launchd     | Plists in `~/Library/LaunchAgents/`                  |
| Logs                 | App+launchd | `~/Library/Logs/JamfReports/<label>/`                |

## What this is NOT

- Not a Jamf Pro replacement. The app does not write to Jamf Pro.
- Not a self-contained API client. Without `jamf-cli` on PATH the app cannot run.
- Not a daemon. There is no background process owned by the app — only on-demand
  jamf-cli spawns and per-user LaunchAgents the operator opts into.

## Implications for contributors

When adding a feature that needs new Jamf Pro data:

1. Confirm `jamf-cli` already exposes a subcommand that returns it. If not, the
   feature blocks on a jamf-cli release first.
2. Wire the subcommand into the `CLICommand` enum (`Services/CLICommand.swift`),
   not a bespoke `CLIBridge` method.
3. Add a decoder under `Engine/JamfCLIDecoder.swift` for the JSON shape.
4. Cache the JSON to `jamf-cli-data/<command>.json`.
5. Render from the cached JSON in the relevant dashboard module.

The app never bypasses the cache. Every read goes through `jamf-cli-data/`, even when
the data was just collected in the same run. This keeps the Trends tab, the Reports
tab, and the LaunchAgent tiers in lockstep.
