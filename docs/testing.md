# Automated Testing

The project has two automated test suites: `pytest` for the Python CLI (covered below,
backed by a committed fixture corpus) and `swift test` for the macOS app (see
[Swift app tests](#swift-app-tests)).

## Fixture Provenance

The committed fixtures under [`tests/fixtures/`](../tests/fixtures/README.md) are
synthetic demo-tenant data, fabricated for tests. They are safe to commit because they
are not production, employer, customer, or client data, and every identifying value
(serials, UDIDs, MACs, IPs, emails, hostnames) is a clearly synthetic placeholder.

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

Or use the repo wrapper:

```bash
./scripts/test.sh
```

Recommended pre-commit check:

```bash
python3 -c "import py_compile; py_compile.compile('jamf-reports-community.py', doraise=True)"
python3 -m pytest tests -q
```

## Optional Git Hook

If you want pushes to run the local test gate automatically, point git at the committed
hook directory:

```bash
git config core.hooksPath .githooks
```

That enables `.githooks/pre-push`, which runs:

```bash
./scripts/test.sh
```

Use this when you want local enforcement before `git push`, but still keep GitHub Actions
as the merge-time source of truth.

## How To Refresh Fixture Data

Regenerate fixtures from a local demo workspace, scrub identifying values per the
checklist below, and promote a minimal subset into `tests/fixtures/`. Never commit
real tenant exports.

### Scrub checklist

Before committing any refreshed fixture, replace every identifying value:

- Activation Lock bypass codes: blank, always.
- Serial numbers: synthetic, non-Apple-checkable values (`FXTR0001XX` style).
- UDIDs: synthetic (`00008101-FIXTURE0000NNNN` style, or fresh random UUIDs).
- MAC addresses: locally administered synthetic values (`02:00:00:...`).
- IP addresses: TEST-NET ranges only (`203.0.113.x`).
- Phone numbers: 555 exchange only (e.g. `612-555-0147`).
- Emails, domains, hostnames: `example.*` only (e.g. `student01@example.edu`,
  `https://example.jamfcloud.com`).
- Management IDs and similar GUIDs: freshly generated values, never tenant originals.
- Tenant, org, and location names: clearly fictional placeholders.

### CSV fixtures

1. Export or refresh the source CSV in a local demo workspace.
2. Scrub identifying values per the checklist above.
3. Replace the matching committed fixture file while keeping the committed filename stable.
4. Re-run `pytest`.

Example pattern:

```text
<local demo workspace>/Jamf Reports/Pro/All Macs_04052026.csv
  -> tests/fixtures/csv/dummy_all_macs.csv
```

Stable names keep test references clean and avoid churn from timestamped filenames.

### jamf-cli JSON fixtures

1. Refresh a local demo workspace's `jamf-cli-data/` cache with a new `collect` run or
   whatever source command produced the improved JSON shape.
2. Scrub identifying values per the checklist above.
3. For each command you want covered, replace the committed fixture with the newest
   useful sample and keep the committed filename stable.
4. Keep one sample per command shape unless a version-specific regression requires more
   than one shape.

Example pattern:

```text
<local demo workspace>/jamf-cli-data/patch-status/patch-status_2026-04-12T194331927561.json
  -> tests/fixtures/jamf-cli-data/patch-status/patch-status.json
```

### Historical-trend fixtures

Trend charts need dated snapshots. The filename date is part of the behavior under test.

Use this pattern when you want to build fresh trend data:

1. Keep a per-family source export in a local demo workspace.
2. Scrub it per the checklist above, then copy it into `tests/fixtures/snapshots/<family>/`.
3. Give it a stable dated name such as `dummy_all_macs_2026-04-12.csv`.
4. Keep at least two dated snapshots when you want line or stacked-area trend coverage.

Two useful fixture strategies:

- identical snapshots on different dates: good enough to validate chart plumbing and date parsing
- meaningfully different snapshots on different dates: better when validating trend math or a regression in bucket counts

If you add a new chart or trend feature, add a new dated snapshot that exercises the edge
case you care about instead of broadening every existing fixture.

## What To Keep Out Of Git

Do not commit:

- full demo-workspace histories or raw (unscrubbed) tenant exports
- generated `.xlsx` outputs
- generated chart PNGs
- `.DS_Store`
- duplicate timestamp variants for the same jamf-cli command when one curated sample is enough

## Swift app tests

The macOS app has its own test suite under `app/Tests/JamfReportsTests/`, with
engine-layer suites in an `Engine/` subdirectory — one suite per service or feature
area. Run it from the `app/` directory:

```bash
cd app
swift test
```

Verify the app still compiles before committing any Swift change:

```bash
cd app && swift build 2>&1 | tail -20
```

CI pins Xcode 16.4 (Swift 6.1.x). A local Swift 6.3+ toolchain relaxes `@MainActor`
enforcement and can compile code that fails on CI — before pushing, run:

```bash
cd app && swift build --build-tests 2>&1 | grep "error:" || echo OK
```

New services and business-logic functions should have a corresponding
`<ServiceName>Tests.swift`.
