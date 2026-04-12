# Automated Testing

This project now uses a committed fixture corpus plus `pytest` for automated validation.

## Fixture Provenance

The committed fixtures under [`tests/fixtures/`](../tests/fixtures/README.md) come from
Jamf-provided fake/demo data sourced from the local `Dummy/` and `Harbor/` workspaces.
They are safe to commit because they are not production, employer, customer, or client
data.

The repo intentionally commits curated fixtures, not full workspaces:

- stable CSV inputs under `tests/fixtures/csv/`
- one latest-good jamf-cli JSON sample per supported command under `tests/fixtures/jamf-cli-data/`
- dated CSV snapshots under `tests/fixtures/snapshots/` for chart and historical-trend tests
- small test configs under `tests/fixtures/config/`

## Run The Suite

Install dev dependencies:

```bash
pip install -r requirements-dev.txt
```

Run all tests:

```bash
python3 -m pytest tests -q
```

Recommended pre-commit check:

```bash
python3 -c "import py_compile; py_compile.compile('jamf-reports-community.py', doraise=True)"
python3 -m pytest tests -q
```

## How To Refresh Fixture Data

Use `Dummy/` and `Harbor/` as source workspaces, then promote a minimal subset into
`tests/fixtures/`.

### CSV fixtures

1. Export or refresh the source CSV in `Dummy/Jamf Reports/...` or `Harbor/Jamf Reports/...`.
2. Replace the matching committed fixture file while keeping the committed filename stable.
3. Re-run `pytest`.

Example pattern:

```text
Dummy/Jamf Reports/Pro/All Macs_04052026.csv
  -> tests/fixtures/csv/dummy_all_macs.csv
```

Stable names keep test references clean and avoid churn from timestamped filenames.

### jamf-cli JSON fixtures

1. Refresh the local `Dummy/jamf-cli-data/` cache with a new `collect` run or whatever
   source command produced the improved JSON shape.
2. For each command you want covered, replace the committed fixture with the newest
   useful sample and keep the committed filename stable.
3. Keep one sample per command shape unless a version-specific regression requires more
   than one shape.

Example pattern:

```text
Dummy/jamf-cli-data/patch-status/patch-status_2026-04-12T194331927561.json
  -> tests/fixtures/jamf-cli-data/patch-status/patch-status.json
```

### Historical-trend fixtures

Trend charts need dated snapshots. The filename date is part of the behavior under test.

Use this pattern when you want to build fresh trend data:

1. Keep a per-family source export in `Dummy/` or `Harbor/`.
2. Copy the export into `tests/fixtures/snapshots/<family>/`.
3. Give it a stable dated name such as `dummy_all_macs_2026-04-12.csv`.
4. Keep at least two dated snapshots when you want line or stacked-area trend coverage.

Two useful fixture strategies:

- identical snapshots on different dates: good enough to validate chart plumbing and date parsing
- meaningfully different snapshots on different dates: better when validating trend math or a regression in bucket counts

If you add a new chart or trend feature, add a new dated snapshot that exercises the edge
case you care about instead of broadening every existing fixture.

## What To Keep Out Of Git

Do not commit:

- full `Dummy/` or `Harbor/` histories
- generated `.xlsx` outputs
- generated chart PNGs
- `.DS_Store`
- duplicate timestamp variants for the same jamf-cli command when one curated sample is enough
