# Server-health fixtures

One file per jamf-cli command the server-health sources run, named `<kind>-<command>.json`.

`certificate-authority-active.json` is the output of `jamf-cli pro certificate-authority
active --output json`, captured on 2026-11-24 with jamf-cli 1.38.0 against Jamf Pro test
servers. Every value is replaced by a synthetic value of the same JSON type and format
(keys, nesting and types as captured; `notAfter` and `notBefore` are epoch seconds).

`jamf-pro-notifications-list.json` is `jamf-cli pro jamf-pro-notifications list --output json`,
built from the seven rows captured on 2026-11-25 on a second Jamf Pro test server: the `type`
values as Jamf prints them (`PATCH_EXTENTION_ATTRIBUTE` included), `params` as `{}`, `{id, name}`
or the patch EA trio, an `id` in `params` sometimes a number. Names are synthetic.

A test requires a fixture here for every server-health kind in the collect matrix, so a kind
lands in the same change as its captured shape.

`admin-accounts-list.json`, `api-integrations-list.json` and `laps-pending-rotations-list.json` are the opt-in admin-hygiene
commands (`pro accounts list`, `pro api-integrations list`, `pro local-admin-password
pending-rotations`), shapes as captured on 2026-11-24 against Jamf's public test server; every
value is synthetic and the rows are edited to cover each count. Pending rotations is the
`{totalCount, results}` envelope with no rows on every server captured (2026-11-24 and
2026-11-25), so a result row's shape is still unknown and the reduction reads `totalCount` alone. The reductions save only counts, and a test
checks that no username, name, email, client ID or display name reaches the saved document.
