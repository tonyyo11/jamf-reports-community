# Server-health fixtures

One file per jamf-cli command the server-health sources run, named `<kind>-<command>.json`.

`certificate-authority-active.json` is the output of `jamf-cli pro certificate-authority
active --output json`, captured on 2026-11-24 with jamf-cli 1.38.0 against Jamf Pro test
servers. Every value is replaced by a synthetic value of the same JSON type and format
(keys, nesting and types as captured; `notAfter` and `notBefore` are epoch seconds).

`jamf-pro-notifications-list.json` is `jamf-cli pro jamf-pro-notifications list --output json`,
captured the same day on Jamf's public test server: one row, every value synthetic, the `type`
spelling (`PATCH_EXTENTION_ATTRIBUTE`) as Jamf prints it.

A test requires a fixture here for every server-health kind in the collect matrix, so a kind
lands in the same change as its captured shape.
