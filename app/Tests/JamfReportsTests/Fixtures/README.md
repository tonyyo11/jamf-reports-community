# Test Fixtures

The files in this directory are committed on purpose for automated testing.

They are synthetic demo-tenant data, fabricated for tests. They are not production,
employer, customer, or client data, and they contain no real device identifiers.

Rules for this fixture corpus:

- Keep filenames stable and timestamp-free for `csv/` and `jamf-cli-data/`.
- Keep only the smallest set of files needed to exercise supported parser shapes.
- Keep dated filenames only in `snapshots/`, where the date itself is part of the test.
- Do not commit generated workbooks, PNG output, or large snapshot histories here.

Refresh workflow:

1. Regenerate the source data from a local demo workspace (never a real tenant export).
2. Scrub identifying values per the checklist below before committing.
3. Replace the curated fixture file with the new file, keeping the committed name stable.
4. For jamf-cli JSON, keep one latest-good sample per command shape.
5. For trend tests, add or replace dated CSV snapshots under `snapshots/`.
6. Run `python3 -m pytest tests -q` before committing.

Scrub checklist (apply to every refreshed fixture):

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
