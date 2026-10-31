# Localizing the app: French, Spanish, German

Machine translated. Nobody fluent reviewed it. Automated checks prove completeness and format
safety, not nuance.

## Inventory (dev/2-12-0, 2026-10-30)

Candidate UI literals, unique: Views 2,769, Models 530 (much of it demo data), Services 2,081 (a
mix of UI and log text), Theme 105, Tips 24. Engine 1,578 and CLI 90 stay English. Expected catalog:
about 5,000 keys, 25,000 English words. 437 `Text("...")` literals localize by themselves; the
rest go through house components and models that take `String`, which SwiftUI never localizes.
135 plural ternaries, 41 enums with a display string as raw value.

## Decisions

- **What is translated:** the GUI: screens, toasts, banners, Config Doctor rows, error
  explanations shown in the app.
- **What stays English:** workbook tabs and columns, the HTML report, PDF, CSV, CLI output, log
  lines and their `[partial]`/`[warn]` markers, webhook cards, model prompts, diagnostic
  bundles, jamf-cli's own messages, `config.yaml` keys, demo data (it stands in for tenant data). Text that has to stay English in a shared
  path stays English on screen too.
- **One seam:** `L("text \(n)")` (`Services/Localization.swift`) returns a `String`, so `String`
  APIs, house components and tests keep their shape. Its parameter is `String.LocalizationValue`,
  which the compiler's `-emit-localized-strings` extracts. `Text("literal")` stays as it is.
- **Headless stays English:** only the GUI entry point turns on a real table; everything else
  reads one that does not exist, so a service shared with it returns its English source.
  `Localization.english { }` does the same in the GUI around reports, collect, exports, AI input.
- **Bundle:** the catalog lives at `app/Localization/Localizable.xcstrings`, outside the SwiftPM
  target, so no `Bundle.module` and no `defaultLocalization`. `build-app.sh` runs
  `xcstringstool compile` into `Contents/Resources/<lang>.lproj` and sets `CFBundleLocalizations`.
  `Text` and `String(localized:)` default to `Bundle.main`, which is the `.app`, although the code
  lives in the library target. `swift run` and tests have no table and show English.
- **Plurals:** `n == 1 ? L("\(n) device") : L("\(n) devices")`, two whole sentences. Right for
  fr, es and de; a language with more plural forms would need catalog variations.
- **Floors:** `String(localized:)` is macOS 12. `#bundle` is not used (Swift 6.2+).
- **Displayed value compared to a value:** a literal that is also compared, switched on or
  parsed is not wrapped by the sweep, and each is reviewed.

## Proof

- Catalog: every key has every language, state `translated`, specifiers match, protected terms
  stay, no source literal is missing from the catalog.
- Leak check: the suite runs once with a pseudo-language; reports, logs and CLI must hold none.
- Layout: demo mode tabs at `PageScaffold.minSupportedWidth` under each language.

## Layers

1. Seam, catalog, build, tests.
2. Wrap Views and Theme, then Models and UI services.
3. Translate with per-language glossaries, formal register.
4. Layout check, docs, CHANGELOG.
