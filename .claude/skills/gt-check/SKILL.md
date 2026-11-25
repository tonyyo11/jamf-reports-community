---
name: gt-check
description: Second opinion on new catalog translations from General Translation (GT). Extracts the keys added or retranslated since a ref, has GT translate them with the project glossary, and reports where our translation fails a check GT's passes and where the two differ. Use before an RC or after a wave's sync-strings, until fluent reviewers take over. Never writes the catalog itself.
argument-hint: "REF [LOCALE ...]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/gt-check *)
---

# GT check

Claude writes the translations (Localization in CLAUDE.md); GT only checks the new ones. Two
machine translations agreeing does not prove either right: a disagreement is a string to read.

1. `${CLAUDE_SKILL_DIR}/scripts/gt-check delta --since REF --out <scratch>/delta.xcstrings`.
   REF is usually the last release tag. With 0 keys, stop.
2. If `git diff --quiet REF -- app/Localization/glossary.md` fails, run
   `gt-check glossary --out <scratch>/glossary.json` and `upsert_context_glossary` its entries
   into the GT context group "Jamf Reports app UI".
3. Find the GT project with `list_projects` (the one that group is assigned to). Base64 the delta
   and `upload_source_files` it (`fileFormat` XCSTRINGS, `fileId` `jr-delta`), then
   `translate_files` with `publish: false` for the locales asked (default all six: fr, es, de,
   pt-BR, it, ja). Poll `query_jobs` no more than every 30 s; `get_file_content` each locale to
   `<scratch>/gt-<locale>.xcstrings`. If GT refuses for quota, retry with fewer locales and say so.
4. `gt-check compare --gt de=<scratch>/gt-de.xcstrings ... --out <scratch>/report.md`.
5. Read the report. For each string in "Ours fails a check GT passes", say whether ours is wrong
   (a lost specifier or product name always is; a glossary term can be right in context) and
   propose the catalog fix. Skim "Different wording" for meaning changes only, not style. Apply
   fixes only after Tony agrees, then run the catalog tests.

Only the delta file leaves the Mac: catalog keys and translator notes, both already public in
the repo. Never send config.yaml, logs, snapshots or report files to GT.
