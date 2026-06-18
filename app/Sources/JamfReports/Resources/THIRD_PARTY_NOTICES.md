# Third-Party Notices

This project incorporates or invokes the following third-party software.
Each item is listed with its license, project URL, and how it is used by
this project. License text for each component is reproduced or linked
below.

---

## Bundled in the macOS app

### ZIPFoundation

- Project: https://github.com/weichsel/ZIPFoundation
- License: MIT
- Used for: pure-Swift ZIP creation for the OOXML (`.xlsx`) writer.

---

## Invoked as an external subprocess (not bundled)

### jamf-cli

- Project: https://github.com/jamf/jamf-cli
- Publisher: Jamf Software, LLC
- License: Apache License 2.0
- Used for: querying Jamf Pro and Jamf School instances. The binary is
  installed separately by the end user (typically via Homebrew) and is
  invoked by this project as a subprocess. It is not bundled, modified, or
  redistributed.

See `NOTICE.md` for the trademark notice covering "jamf-cli" and related
marks owned by Jamf Software, LLC.

---

## Loaded at runtime (not bundled)

### Chart.js

- Project: https://www.chartjs.org
- License: MIT
- Used for: rendering charts inside the HTML report. The library is loaded
  from a public CDN at report-viewing time and is not bundled in this
  project's source or build artifacts.

---

## Build-time dependencies (not redistributed)

The release pipeline uses the following Apple-provided tools, which are
not part of the distributed artifact:

- `codesign`, `productsign`, `pkgbuild`, `productbuild`, `hdiutil`,
  `xcrun notarytool`, `xcrun stapler` — bundled with macOS and Xcode
  Command Line Tools.
