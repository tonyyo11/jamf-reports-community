# Security Cloud fixtures

`risk-list.json` follows the row shape of `jamf-cli security risk list --output json` in
jamf-cli 1.36.0 (a bare array). Every value is invented: the GUIDs, user, location, device name
and connector payload are fabricated (nested objects and nulls as jamf-cli prints them) so the allow-list test can see them dropped. It is not tenant data.
