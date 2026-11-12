# Automated Testing

The macOS app has an automated `swift test` suite. Its test data is the committed
`jamf-cli` JSON / CSV fixtures the engine reads (synthetic demo-tenant data — see Fixture
Provenance below). Captured rows and keys, not text written from documentation, are the rule: a
fixture is captured from real `jamf-cli` output (the tree also holds Security Cloud, site-scope,
timestamp, catalog and School keys-and-types fixtures).

## Swift app tests

The test suite lives under `app/Tests/JamfReportsTests/`, with engine-layer suites in an
`Engine/` subdirectory — one suite per service or feature area. Run it from the `app/`
directory:

```bash
cd app
swift test
```

Verify the app still compiles before committing any Swift change:

```bash
cd app && swift build 2>&1 | tail -20
```

CI runs three legs: `macos-15` with Xcode 16.4 (Swift 6.1.x, the language floor), `macos-26`
with Xcode 26.0.1 (Swift 6.2) and the `xcode-27` runner image (a preview that may fail without
failing the run). It also runs the tick agent's spawn-constraint test, the versioning tests,
and the check for symbols only tests reference (`app/scripts/check-test-only-symbols.zsh`). A
local Swift 6.3+ toolchain relaxes `@MainActor` enforcement and can compile code that fails on
CI — before pushing, run:

```bash
cd app && swift build --build-tests 2>&1 | grep "error:" || echo OK
```

New services and business-logic functions should have a corresponding
`<ServiceName>Tests.swift`.

## What the harness guarantees

- A test never launches jamf-cli: under XCTest in a debug build the locator and the Homebrew
  lookup find none, and profile discovery reads no jamf-cli config file. A test that needs one
  injects a stub that is not named `jamf-cli`.
- A test never touches the real workspaces root, tick lock, schedule store or run-now markers:
  set `JRC_TEST_WORKSPACES_ROOT` for a workspace root, and the debug build gives each test
  process its own Application Support folder.
- `swift test --filter <Suite>` runs one suite. Never run two `swift test` at once in one
  checkout.
- `.githooks/pre-push` runs the CI-parity `swift build --build-tests` once enabled with
  `git config core.hooksPath .githooks`.
- A checkout under an iCloud folder can fail the xctest codesign step; build and test from a
  folder outside iCloud.

## What a test has to prove

A test that cannot fail proves nothing. Before trusting a new test, ask what it does if the
code under it returns nothing: an empty list, nil, 0 or an early return. If it still passes,
rewrite it to assert what the user would see: the figure on the screen, the row in the sheet,
the line in the log. The quiet forms are a loop over rows that turned out empty, `contains` on
text that appears either way, and a nil check on a path that returns nil for every input. When
in doubt, break the code and run the test: it has to fail.

## Fixture Provenance

The committed fixtures used by the suite are synthetic demo-tenant data, fabricated for
tests. They are safe to commit because they are not production, employer, customer, or
client data, and every identifying value (serials, UDIDs, MACs, IPs, emails, hostnames) is
a clearly synthetic placeholder.

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

## What To Keep Out Of Git

Do not commit:

- full demo-workspace histories or raw (unscrubbed) tenant exports
- generated `.xlsx` outputs
- generated chart PNGs
- `.DS_Store`
