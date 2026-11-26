# Patch scan fixtures

`patch-scan-failures-captured.json` is `pro report patch-status --scan-failures --output json` from a test Jamf Pro server (jamf-cli 1.38.0, Jamf Pro 11.34, 2026-11-25), with one patch policy failing a download (-1003). Names, IDs, the serial and the user were replaced; the keys and JSON types are as jamf-cli printed them (`attempt` is text, `status_date` has no time zone). The `title_compliance` section was left out.
