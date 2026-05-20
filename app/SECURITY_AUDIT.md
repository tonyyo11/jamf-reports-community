# Security Audit

Security review findings and mitigations for the JamfReports macOS app.

Each entry records a review's date, scope, findings, and resolution.
Reviews are change-scoped unless explicitly noted as a full-project audit.

## 2026-05-20 — PR-25 change review

**Scope:** the three changes in PR-25 — the `OOXMLWriter` xlsx ZIP/XML
generation fix, the new Patch Compliance CSV export
(`PatchStatusService.complianceCSV`, `PatchView.exportPatchComplianceCSV`),
and the sidebar monogram change.

### Findings

#### MUST-FIX — formula injection in the Patch CSV export (resolved)

`PatchStatusService.csvField` initially applied only RFC 4180 quoting and
did not neutralize values beginning with `=`, `+`, `-`, or `@`. Patch
titles originate from jamf-cli / Jamf Pro patch definitions, which can
include third-party Title Editor and community-sourced titles, so a
crafted title such as `=HYPERLINK(...)` could be evaluated as a formula
when the exported CSV is opened in Excel or Numbers.

The xlsx export path already neutralizes this in
`OOXMLWriter.sanitizeString`, and the Python CLI's `_safe_write` is the
documented contract; the CSV path diverging from it on the same class of
data was the defect.

**Resolution (PR-25):** `csvField` now prefixes a tab to any value that
starts with a formula character before RFC 4180 quoting, matching the
xlsx path. Covered by
`PatchStatusServiceTests.testComplianceCSVNeutralizesFormulaInjection`.

### Verified clean

- **`OOXMLWriter` ZIP-entry provider** — the chunked-provider slice logic
  is bounds-correct: a `start < data.count` guard, a
  `min(start + requested, data.count)` end clamp, and zero-length parts
  return empty `Data`.
- **`xmlEscape`** — replaces `&` first, so entity-introducing characters
  are not double-escaped; covers the five XML entities.
- **`CellValue.safe` / `sanitizeString`** — strips C0/C1 control
  characters (keeps tab/LF/CR), caps cell length, and neutralizes
  formula-injection prefixes.
- **`PatchView.exportPatchComplianceCSV`** — `NSSavePanel` constrains the
  write to a user-chosen path; the write is atomic; success and failure
  both surface a toast.
- **Sidebar monogram** — `prefix(4)` over a profile slug already validated
  by `ProfileService`; cosmetic, with no security surface.

### Notes

This is a change-scoped review, not a full-project audit. A broader audit
should cover the LaunchAgent surface, credential handling via the
`jamf-cli` stdin path, and the `SystemActions` path allow-list.
