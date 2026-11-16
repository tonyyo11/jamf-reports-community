# A hand-edited config.yaml is understood, reported on, and kept

Owner direction (2026-10-02): flexibility and customizability are key; a `config.yaml` edited by
hand, or shaped by an organization nothing like the author's, is a supported input. The app must
understand what was typed, say so when it could not, show what is in effect, and keep what was
typed when it saves. A read-only audit on 2026-10-02 found no unknown-key detection anywhere,
28 cases where a typed value is silently replaced or ignored, and several writers that drop what
they do not model. This plan closes the cases with the most reach. What is loud today stays loud:
a wrong type, an unknown `custom_eas[].type`, a dict where a list belongs, or a missing required
key still rejects the file and names the key path.

Paths are under `app/Sources/JamfReports/` and `app/Tests/JamfReportsTests/`. Tasks run in order
in one worktree, each followed by a review.

## Global Constraints

- Work only inside this worktree. Do not push, open a PR, or edit GitHub issues.
- Do not edit `CHANGELOG.md`, `README.md`, `CLAUDE.md`, `AGENTS.md` or `BACKLOG.md`; put the
  proposed CHANGELOG line and any stale documentation sentence in your report.
- Before the first edit of each file, run `git log --oneline origin/main..HEAD -- <path>` and put
  the count in your report. At 3 or more, state why your change does not undo that work.
- One commit per logical change. Subject `<type>(config): <imperative, ≤72 chars>`. No attribution
  or co-author trailers. Do not use: critical, crucial, essential, significant, comprehensive,
  robust, elegant.
- Test first: write the failing test, see it fail for the stated reason, then fix. Every claim in
  this plan marked "verify first" is an inference from reading: write the test that proves or
  refutes it before changing code, and if it is refuted, keep the test, change nothing, and say so.
- Tests never read or write the real `~/Jamf-Reports`, never run `jamf-cli`, clean up
  `UserDefaults` keys with a per-test `defer` (no `tearDown` override on a `@MainActor` test
  class), and a test class for a SwiftUI `View` type carries class-level `@MainActor`. Test a
  profile-keyed service by pointing `JRC_TEST_WORKSPACES_ROOT` at a temp dir and restoring it.
- Swift 6 strict concurrency; CI compiles with Swift 6.1. No force-unwrap in production code,
  functions ≤100 lines, lines ≤100 columns, no new package dependency, no new Service/View/Model
  file without a caller in the same commit.
- Text taken from the user's file and shown anywhere (a Doctor row, a banner, the new panel) is
  untrusted display text: strip control characters and cap it at 60 characters, in one shared
  helper. Never echo a value under a key whose name suggests a secret (`url`, `token`, `secret`,
  `password`, `key`, `webhook`): show `(set)` or `(empty)`.
- Config Doctor rows added by this plan are `.warn` (or `.suggest`), never `.fail`: only `.fail`
  reaches Run History, and a typo must not turn a healthy scheduled run red.
- No organization-specific values anywhere. Sample config in tests uses invented names.
- Do not change SwiftUI layout primitives unless the task says so; a commit that does carries
  `DRAFT — needs visual verification` in its body.
- A behaviour change to how a value is read is listed in the task, pinned by its own named test,
  and named in the proposed CHANGELOG line.
- Gate before each commit, from `<worktree>/app`:
  `swift build --build-tests 2>&1 | grep "error:" || echo OK`, then
  `swift test --filter '<SuiteA>|<SuiteB>'` for the suites you touched. Report actual counts.
- If something does not reproduce or a task would pass ~350 changed source lines, stop and report.

## Task 1: Unknown keys are reported, with the nearest known key

Files: `Engine/ConfigDecoder.swift`, `Services/ConfigDoctorService.swift`, new
`Engine/ConfigSchema.swift` (called by the Doctor in this task), tests.

Today a misspelled key in any block is ignored and its default is used, with no signal anywhere
(`JSONDecoder` ignores extras; every `CodingKeys` enum is private).

Produces:
- `enum ConfigSchema { static func knownKeys(at path: [String]) -> Set<String>?;
  static func unknownKeys(in root: [String: Any]) -> [UnknownKey] }` and
  `struct UnknownKey: Sendable, Equatable { let keyPath: String; let suggestion: String? }`.
  `knownKeys` is derived from the decoder's own `CodingKeys` (make each `CaseIterable`), so the
  schema cannot drift from what the app reads. It returns nil for a path whose keys are free-form
  (a mapping the user names, for example `columns` extras if the decoder accepts arbitrary ones;
  find these from the decoder, do not guess).
- Three keys the decoder never sees but the app reads by other means are known too:
  `output.allow_absolute_paths`, `html.track_history`, `html.history_file`.

Behaviour:
1. The walk covers top-level keys, nested mappings, and mappings inside lists (`custom_eas[]`,
   `security_agents[]`, `alerts.rules[]`, `exceptions[]`, `compliance.baselines[]`,
   `charts.compliance_trend.bands[]`), reporting key paths like `custom_eas[2].warning_treshold`.
2. `suggestion` is the known key at edit distance ≤2 at that path (ties: none). Keys are compared
   as written; `-`/`_` differences count as distance 1.
3. Config Doctor: one `.warn` row per unknown key under a "config.yaml" heading — title the key
   path, detail `The app does not read this key.` plus ` Did you mean "\(suggestion)"?` when
   there is one. The value is never shown. More than 20 unknown keys: the first 20 rows and one
   row saying how many more.
4. If the security-policy work is on your base, `security_policy` is covered by this walk like
   every other block and its own unknown-key Doctor rows are removed so a key is reported once
   (its level-value rows stay). If it is not on your base, say so and skip this item.
5. A top-level key the app does not know is reported once, not once per nested key under it.

Tests: a fixture config with a misspelled top-level key, a misspelled nested key, a misspelled
key inside the second `custom_eas` item, and a correct file (no rows); the shipped
`config.example.yaml` produces zero unknown-key rows (this pins the schema to the documented
file — if it reports any, the example or the schema is wrong: say which); every key the decoder
reads is in the schema (iterate the `CodingKeys`).

## Task 2: Values the app replaced or ignored are stated

Files: `Services/ConfigDoctorService.swift`, `Engine/ConfigDecoder.swift` (two value-reading
changes below), `Engine/ReportEngine.swift` (`keep_latest_runs` only), tests.

One `valueRows(config, raw:)` in the Doctor, following the existing `alertsRows` pattern,
restates each fallback or clamp the code already computes. Each row: title the key path, detail
what was typed (through the shared display helper) and what the app uses. Cover, each with a
test (verify each first against the code; drop any that turn out to be loud already and say so):

- `notify.provider` not `teams`/`slack`; `notify.detail` not `full`/`minimal`;
  `notify.enabled: true` with an empty or non-https `url`.
- `retention.mode` not `archive`/`delete`; `retention.enabled` with both horizons ≤ 0;
  `retention.archive_dir` that resolves outside the workspaces root.
- `shared_workspace.claim_ttl_minutes` and `min_collect_interval_hours` outside their clamps
  (state the typed and the clamped value).
- `jamf_cli.collect_skip` entries outside the accepted kinds (name them; the stall guard does not
  apply to them).
- `sheets.only` / `skip` / `order` names that match no sheet (compare with `CoreDashboard`'s
  sheet plan names, case-insensitively as `SheetsConfig.applyTo` does).
- `exceptions[].expires_date` not `yyyy-MM-dd`.
- `thresholds.*` that are zero or negative where a positive number is required, or a warning
  threshold above its critical one.
- `custom_eas[]` keys that do not apply to the entry's `type` (for example `warning_threshold`
  on a `boolean`), which the engine ignores.
- `alerts.rules[].lookback_days` non-numeric; `alerts.rules` present with `alerts.enabled` absent.
- `branding.accent_color` and chart band `color` values that are not hex colours.
- `html.section_limits.*` outside their clamps; `ai.tier` / `ai.reasoning_level` unknown.
- Keys that are read into the config but have no effect anywhere (verify each with `rg` for a
  consumer beyond the decoder, the GUI editor and the writer): `jamf_cli.enabled`,
  `jamf_cli.allow_live_overview`, `platform.enabled`, `thresholds.checkin_overdue_days`,
  `thresholds.profile_error_critical`, `charts.os_adoption.enabled`,
  `charts.compliance_trend.enabled`. Row detail: `This key currently has no effect.` Report the
  list you confirmed; do not delete the keys or their GUI controls in this task.
- `school_cli.enabled` together with `protect.enabled` (state which one the collect uses).

Two value-reading changes (each pinned by a named test and named in the CHANGELOG line):
1. `notify.detail`: read case-insensitively; a value that is neither `full` nor `minimal` resolves
   to `minimal`, not `full`. An unrecognised value must fail toward sending less.
2. `output.keep_latest_runs`: verify first — the audit reads `0` as archiving the report just
   written and a negative number as a trap in `dropFirst`. If confirmed, a value below 1 is
   treated as 1.

## Task 3: The YAML reader says what it skipped, and reads one way

Files: `Services/YAMLCodec.swift`, the config loader beside it, `Engine/HtmlReport.swift` (the
line-based `html:` reader), `Services/DeviceInventoryService.swift` (the line-based
`stale_device_days` reader), `Services/WorkspacePaths.swift` (the raw `allow_absolute_paths`
lookup), `Views/ConfigView.swift` (existing banner only), `Services/ConfigDoctorService.swift`,
tests.

The project parses YAML with its own minimal codec. Verify each of these first, then fix what is
confirmed:

1. Lines the parser skips are recorded: a mis-indented line, a line with no colon where a key is
   expected, tab indentation, a duplicate key in one mapping, and a block scalar (`|` or `>`),
   which the codec does not support (the audit reads it as the literal `|` with continuation
   lines dropped). Add `YAMLCodec` parse notes (line number, kind) beside the existing
   `repairedKeys`. Parsing behaviour for valid input does not change.
2. A leading UTF-8 byte-order mark is stripped before parsing (the audit reads it as leaving the
   first top-level key unmatched).
3. Duplicate keys: every reader agrees on which one wins. The audit reads the engine as
   last-wins and the GUI and `WorkspacePaths` as first-wins. Make all of them last-wins and
   report the duplicate.
4. One reader per value. Three values are read by ad-hoc line scanners or raw lookups that
   disagree with the decoder: `html.track_history` / `html.history_file` (misreads `true # note`,
   `True`, a quoted value, CRLF), the Devices screen's `thresholds.stale_device_days` (misses a
   section header carrying a comment, or flow style, and falls back to 30), and
   `output.allow_absolute_paths` (its truthy set differs). Read all three through the same loader
   the engine uses, with the decoder's boolean rules. Behaviour changes only for the inputs the
   scanners misread; pin each in a named test.
5. Quoted booleans — verify first: the audit reads `true_value: "true"` (which the GUI itself
   writes for a boolean EA whose expected value is the word true) as coerced to a Bool and
   rejecting the whole file. If confirmed, a quoted scalar stays a string for string-typed keys.
6. Surfacing: the Config screen's existing banner (the one that shows repaired keys) also shows
   the parse notes as `Line N: <what was skipped>`; the Doctor gets one `.warn` row per note
   under the "config.yaml" heading, capped at 20. No layout-primitive changes.

## Task 4: Saving from the app keeps what was typed

Files: `Services/NotifyConfigStore.swift`, `Intelligence/AIConfigWriter.swift`,
`Services/ConfigService.swift`, `Services/OnboardingFlow.swift`, `CLI/UtilityCommands.swift`,
`Views/ConfigView.swift` (banner and Save only), tests.

1. `NotifyConfigWriter` and `AIConfigWriter` replace their whole block today, dropping any key
   they do not model. Make both set individual keys and keep the rest of the block, the way
   `ChartsConfigWriter` does. Test: an unmodelled key inside `notify:` and inside `ai:` survives a
   save.
2. `custom_eas` and `security_agents` are rebuilt from the keys the editor models, so an extra
   key on an entry is dropped. Keep each entry's unmodelled keys through a load/save round trip
   (carry them on the model as an opaque dictionary; they are not edited). An entry the user
   deletes in the GUI is deleted; a new entry has none.
3. A `custom_eas` or `security_agents` value that is not a list (the audit reads a dict-shaped
   value as showing empty and being saved as `[]`) is never overwritten by a save: the save of
   that block is skipped and the Config screen's banner says why. Verify first.
4. The Config screen loads once and Save writes every modelled key from memory. If `config.yaml`
   changed on disk since it was loaded (compare modification date and size), Save does not write:
   the banner says `config.yaml changed on disk since this screen loaded it.` with a Reload
   action. Reloading discards unsaved edits; say so in the banner text.
5. Before any app-initiated write that replaces an existing `config.yaml` wholesale (the
   onboarding CSV scaffold, onboarding "Skip", and the CLI `scaffold --out` when the target
   exists), the existing file is copied to `config.yaml.bak-<yyyyMMdd-HHmmss>` beside it; keep
   the newest 5 such backups. The CLI prints the backup path.
6. Saving a managed block re-emits it, which drops comments inside that block. Do not try to
   preserve them. Instead, whenever a save would drop a comment (the block's on-disk text
   contains a `#` comment line or a trailing comment), make the same timestamped backup as in
   item 5 — skipped only when an existing backup beside the file holds the same bytes, and never
   pruned by the save that made it (amended after review: "once per app launch" named a copy that
   lacked text typed since) — and show one line in the banner: `Comments inside the blocks this
   screen edits are not kept. A copy of the file as it was is at <backup name>.`
7. Added after Task 3's review. A line the reader skipped (a Task 3 parse note) that falls inside
   a managed block is deleted when that block is re-emitted, and the refresh after save
   (`ConfigView.save()` → `refreshEngineParseStatus()`) then clears its note. Treat it as item 6
   treats comments: when a parse note's line falls inside a block the save is about to rewrite,
   make the timestamped backup (same rule as item 6) and show one line in the
   banner: `Lines this screen could not read inside the blocks it edits are not kept. A copy of
   the file as it was is at <backup name>.` Test with a skipped line inside `columns:`.
8. Added after Task 3's re-review. `YAMLCodec`'s `endOfTopLevelBlock` treats the blank lines and
   unindented `#` comments that follow a block as part of it, so re-emitting an edited block
   deletes them: in a file copied from `config.example.yaml` that is every section banner comment
   below an edited block. The block a save rewrites ends at its last indented line; blank lines
   and unindented comments between it and the next top-level key are kept verbatim. Verify first
   with a save round trip on a copy of `config.example.yaml`: every unindented comment line and
   blank line outside the managed blocks' own indented text survives. Item 6's backup and banner
   then apply only to comments inside a block's indented text.

## Task 5: The Config screen shows what the file says

Files: `Views/ConfigView.swift` (one new tab or card), a small view file if the tab needs it
(with its caller in the same commit), `Services/ConfigDoctorService.swift` or `ConfigSchema`
(read side only), tests.

Consumes: Task 1 `ConfigSchema.unknownKeys(in:)`; Task 3 parse notes; the shared display helper.

A read-only "From config.yaml" tab on the Config screen, so a customization typed by hand is
visible in the app:

1. "Set in the file, not editable here": every key present in the file that the app reads but no
   screen edits, with its value through the display helper (secret-like keys show `(set)`),
   grouped by top-level block in file order. Which keys the screens edit comes from
   `ConfigService`'s managed keys and the scoped stores; derive it, do not hand-list it, and test
   that a key edited by a screen is not listed here.
2. "Not read by the app": the unknown keys from Task 1, with the suggestion.
3. "Skipped by the reader": the parse notes from Task 3.
4. A button that reveals `config.yaml` in Finder through `SystemActions` (the existing
   allow-listed reveal), and a Reload button.
5. Empty sections are omitted; a file with nothing to show says `Everything in config.yaml is
   editable on the other tabs.` Demo mode shows the demo workspace's nothing-to-show state and
   reads no file.
6. Layout: this adds a tab and a list. The commit carries `DRAFT — needs visual verification`;
   describe in the report how the tab strip behaves at `PageScaffold.minSupportedWidth` (the
   strip already falls back to short labels below about 804 pt — give the new tab a short label).

Tests: the pure function that builds the three sections from a fixture file (file-only keys,
unknown keys, parse notes; a screen-edited key excluded; a secret-like key masked).

## Task 6: `sheets` settings reach every workbook, and four reads found on the way

Found while building Tasks 1 and 2. Each item is "verify first".

Files: `Engine/SheetRegistry.swift` (or wherever `writeSelected` lives), `Engine/CoreDashboard.swift`,
`Engine/SchoolDashboard.swift`, `Engine/OOXMLWriter.swift`, `Services/SnapshotRetentionService.swift`,
`Services/ConfigDoctorService.swift`, `config.example.yaml`, tests.

1. `sheets.only` / `skip` / `order` are documented as controlling the workbook's tabs, but the
   generate path for jamf-cli sheets goes through `SheetRegistry.writeSelected`, which is reported
   to ignore `config.sheets`; only the CSV sheets honour it (`CSVDashboard`), and
   `CoreDashboard.writeAll`, which did honour it, is reported to have no production caller. Verify
   with a test that generates a workbook from fixture snapshots with `sheets.skip: ["<a jamf-cli
   sheet name>"]` and looks for that tab. If confirmed: the workspace's `sheets` settings apply to
   the final tab list of every workbook the app writes — jamf-cli sheets, CSV sheets and Jamf
   School sheets — after the report template has chosen its sheets: `skip` removes, a non-empty
   `only` restricts (within what the template includes), `order` reorders, names matched
   case-insensitively as `SheetsConfig.applyTo` does. A name that matches nothing is ignored (the
   Doctor row from Task 2 already says so). The Custom template's own sheet selection and
   `sheets.only` both apply (intersection). If `CoreDashboard.writeAll` is confirmed dead, delete it
   and its tests in the same change and say so. Correct the `config.example.yaml` comment (and the
   Task 2 Doctor row about Jamf School) to describe the behaviour as built.
2. `branding.accent_color` is written into the workbook's `styles.xml` without validation
   (`OOXMLWriter`), while the HTML report falls back for an invalid colour and a `sanitizedAccent…`
   helper exists that nothing calls. Verify with a workbook built with `accent_color: "red\"/><x"`:
   the styles part must stay well-formed XML. Fix: one validated hex value used by both reports,
   falling back to the default colour when the typed value is not a 3- or 6-digit hex colour (the
   Task 2 Doctor row already reports it). Delete the unused helper if the fix does not use it.
3. `retention.archive_dir` given as a relative path containing `..` is reported to be able to
   resolve outside the workspace. Verify with a test (`archive_dir: "../outside"` in a temp
   workspaces root). If confirmed, resolve it the way `output.archive_dir` is resolved and
   refuse a path that leaves the workspace unless `output.allow_absolute_paths` is true, falling
   back to the default `_archive` with the Task 2 Doctor row.
4. Config Doctor builds a column's key name with `snakeCased`, which turns `entraSSOStatus` into
   `entra_s_s_o_status`, so it can never suggest a header for `entra_sso_status` and its row title
   is wrong. Use the column's real config key (the decoder's `CodingKeys` raw value) instead of
   deriving it; test every column field's key against the decoder's.
5. Added after Task 3's review. `ReportEngine.resolveOutputURL` (the workbook and HTML writer's
   folder) does not expand `~` and, given a profile, sends an absolute `output.output_dir` outside
   the workspace to `<workspace>/Generated Reports` without reading `output.allow_absolute_paths`;
   `WorkspacePaths.outputDir(for:)` (the Reports library, the period report) honours the key. So
   `output_dir` is read two ways, and the documented publish layout (workspace local, `output_dir`
   in a synced team folder, `allow_absolute_paths: true`) is reported to never place the report
   there. Verify with a test through `ReportEngine.generate` in a temp workspaces root: an
   absolute `output_dir` in a second temp folder with `allow_absolute_paths: true`, the same with
   the key absent, and a `~/`-prefixed value. If confirmed: `resolveOutputURL` resolves the folder
   through `WorkspacePaths.outputDir(for:)` so both readers agree; a refused path falls back to
   `Generated Reports` in the workspace and the run log says why in one `[warn]` line. No change
   when `output_dir` is relative. If refuted, keep the tests and change nothing.
