# Test Fixtures

The files in this directory are committed on purpose for automated testing.

They are derived from Jamf-provided fake/demo data from the local `Dummy/` and `Harbor/`
workspaces. They are not production, employer, customer, or client data.

Rules for this fixture corpus:

- Keep filenames stable and timestamp-free for `csv/` and `jamf-cli-data/`.
- Keep only the smallest set of files needed to exercise supported parser shapes.
- Keep dated filenames only in `snapshots/`, where the date itself is part of the test.
- Do not commit generated workbooks, PNG output, or large snapshot histories here.

Refresh workflow:

1. Update the source `Dummy/` or `Harbor/` workspace locally.
2. Replace the curated fixture file with the new source file, keeping the committed name stable.
3. For jamf-cli JSON, keep one latest-good sample per command shape.
4. For trend tests, add or replace dated CSV snapshots under `snapshots/`.
5. Run `python3 -m pytest tests -q` before committing.
