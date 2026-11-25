# Jamf Protect wave E fixtures

The keys and value types of `jamf-cli protect threat-prevention-versions list --output json`
and `jamf-cli protect downloads summary --output json`, captured on jamf-cli 1.38.0
(2026-11-24). Every value is invented: ids are digit strings of the captured length (one is a
whole number, which the calculator also accepts), timestamps have the captured 27-character
form, and the URLs point at `example.invalid`. `unknownNested` is not a jamf-cli key; it is
there so the reducer test can see an unlisted key dropped. It is not tenant data.

`protect-plans-1.38.json` has the keys and value types of one `jamf-cli protect plans list
--output json` row captured on jamf-cli 1.38.0 (2026-11-25), with invented values. It shows that
jamf-cli writes `preventListSets` as `""` on a plan with no prevent list.
