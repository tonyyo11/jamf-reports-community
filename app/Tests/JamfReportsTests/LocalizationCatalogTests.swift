import Foundation
import Testing

/// Machine translations nobody fluent reviews, so these are the proof they are complete and safe to
/// show: every key has every language, format specifiers line up, and product and config names stay.
struct LocalizationCatalogTests {
    static let languages = ["fr", "es", "de", "pt-BR", "it", "ja"]
    static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Entry {
        let key: String
        let shouldTranslate: Bool
        let isStale: Bool
        /// Language to (state, value); a plural variation lists one per case.
        let units: [String: [(state: String, value: String)]]
    }

    static let catalog: [Entry] = {
        let url = appDirectory.appendingPathComponent("Localization/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]] else { return [] }
        return strings.map { key, body in
            var units: [String: [(state: String, value: String)]] = [:]
            let localizations = body["localizations"] as? [String: [String: Any]] ?? [:]
            for (language, localization) in localizations {
                units[language] = Self.units(in: localization)
            }
            return Entry(
                key: key,
                shouldTranslate: body["shouldTranslate"] as? Bool ?? true,
                isStale: body["extractionState"] as? String == "stale",
                units: units
            )
        }
    }()

    private static func units(in node: [String: Any]) -> [(state: String, value: String)] {
        if let unit = node["stringUnit"] as? [String: Any] {
            return [(unit["state"] as? String ?? "", unit["value"] as? String ?? "")]
        }
        guard let plural = (node["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
        else { return [] }
        return plural.values.flatMap { units(in: $0) }
    }

    static var translatable: [Entry] { catalog.filter { $0.shouldTranslate && !$0.isStale } }

    @Test func catalogLoads() {
        #expect(Self.catalog.count > 1000)
    }

    @Test func everyKeyIsTranslatedInEveryLanguage() {
        var missing: [String] = []
        for entry in Self.translatable {
            for language in Self.languages {
                let units = entry.units[language] ?? []
                if units.isEmpty || units.contains(where: { $0.state != "translated" || $0.value.isEmpty }) {
                    missing.append("\(language): \(entry.key)")
                }
            }
        }
        #expect(missing.isEmpty, "\(missing.count) untranslated, first: \(missing.prefix(10))")
    }

    /// rc1 showed "重大" beside an English "WARNING": a translation can be filled in with the source.
    @Test func japaneseStatusPillsAreTranslated() {
        let pills = ["CRITICAL", "WARNING", "WARN", "INFO", "FAIL", "PASS", "RUNNING", "PARTIAL"]
        let untranslated = pills.filter { key in
            Self.catalog.first { $0.key == key }?.units["ja"]?.first?.value ?? key == key
        }
        #expect(untranslated.isEmpty, "\(untranslated)")
    }

    @Test func noKeyIsStale() {
        let stale = Self.catalog.filter(\.isStale).map(\.key)
        #expect(stale.isEmpty, "run scripts/sync-strings.zsh --prune-stale: \(stale.prefix(10))")
    }

    /// `%@` and `%lld` by type, in any order; a positional one is `%2$@`.
    static func specifiers(in text: String) -> [String] {
        let withoutEscapes = text.replacingOccurrences(of: "%%", with: "")
        let pattern = /%(?:\d+\$)?(?:ld|lld|lu|llu|d|u|f|\.\d+f|@|arg)/
        return withoutEscapes.matches(of: pattern).map {
            String($0.output).replacing(/\d+\$/, with: "")
        }.sorted()
    }

    /// The type each argument is read as: `%2$@` is argument 2, an unnumbered one the next in
    /// order. A translation that moves unnumbered placeholders reads a number as an object.
    static func argumentTypes(in text: String) -> [Int: String] {
        let pattern = /%(?:(\d+)\$)?(ld|lld|lu|llu|d|u|f|\.\d+f|@|arg)/
        var next = 0
        var types: [Int: String] = [:]
        for match in text.replacingOccurrences(of: "%%", with: "").matches(of: pattern) {
            let index: Int
            if let position = match.output.1.flatMap({ Int($0) }) {
                index = position
            } else {
                next += 1
                index = next
            }
            types[index] = String(match.output.2)
        }
        return types
    }

    /// Positions, when used: each argument exactly once and of the source's type.
    static func positionalProblem(source: String, translation: String) -> String? {
        let positional = translation.matches(of: /%(\d+)\$((?:ld|lld|lu|llu|d|u|f|\.\d+f|@))/)
        guard !positional.isEmpty else { return nil }
        let sourceTypes = source.replacingOccurrences(of: "%%", with: "")
            .matches(of: /%(?:ld|lld|lu|llu|d|u|f|\.\d+f|@)/).map { String($0.output.dropFirst()) }
        for match in positional {
            guard let index = Int(match.output.1), index >= 1, index <= sourceTypes.count else {
                return "position out of range"
            }
            if sourceTypes[index - 1] != String(match.output.2) { return "type differs at \(index)" }
        }
        if Set(positional.map(\.output.1)).count != positional.count { return "position repeated" }
        return nil
    }

    @Test func formatSpecifiersMatchSource() {
        var problems: [String] = []
        for entry in Self.translatable {
            let expected = Self.specifiers(in: entry.key)
            for language in Self.languages {
                for unit in entry.units[language] ?? [] {
                    if Self.specifiers(in: unit.value) != expected {
                        problems.append("\(language): \(entry.key) -> \(unit.value)")
                    } else if Self.argumentTypes(in: unit.value)
                                != Self.argumentTypes(in: entry.key) {
                        problems.append("\(language) order: \(entry.key) -> \(unit.value)")
                    } else if let why = Self.positionalProblem(source: entry.key, translation: unit.value) {
                        problems.append("\(language) \(why): \(entry.key) -> \(unit.value)")
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count): \(problems.prefix(10))")
    }

    static let protectedTerms = [
        "Jamf Pro", "Jamf Protect", "Jamf School", "Jamf Account", "Jamf Cloud", "jamf-cli",
        "jamf-reports", "Jamf Reports", "Jamf Security Cloud", "FileVault", "Gatekeeper", "SIP",
        "XProtect", "mSCP", "config.yaml", "macOS", "iPadOS", "iOS", "Homebrew", "GitHub", "OAuth2",
        "SOFA", "DDM", "APNs", "UDID", "SHA-256", "Touch ID", "Apple silicon",
    ]

    /// Backticked code, config keys, command flags and file names must survive untouched.
    static func codeTokens(in text: String) -> [String] {
        let patterns: [Regex<Substring>] = [
            /`[^`]+`/, /\b[a-z]+(?:_[a-z0-9]+)+\b/, /\B--[a-z][a-z-]+/, /~\/[\w.\/-]*[\w\/]/,
            /\/(?:usr|opt|Users|Library|Applications)\/[\w.\/-]*[\w\/]/, /\b[\w-]+\.(?:yaml|json|xlsx|html|csv|plist|mobileconfig)\b/,
        ]
        // A backticked argument (`%@`) may become positional (`%1$@`); the specifier test covers it.
        return patterns.flatMap { text.matches(of: $0).map { String($0.output) } }
            .filter { !$0.contains("%") }
    }

    @Test func protectedTermsStayUntranslated() {
        var problems: [String] = []
        for entry in Self.translatable {
            let required = Self.protectedTerms.filter { entry.key.contains($0) }
                + Self.codeTokens(in: entry.key)
            for language in Self.languages {
                for unit in entry.units[language] ?? [] {
                    // German joins a name into a compound with hyphens: Jamf-Pro-Datensatz.
                    for term in required where !unit.value.contains(term)
                        && !unit.value.contains(term.replacingOccurrences(of: " ", with: "-")) {
                        problems.append("\(language) lost \(term): \(entry.key) -> \(unit.value)")
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count): \(problems.prefix(10))")
    }

    /// A formatter with no locale takes the Mac's language and calendar: a report's times change
    /// language, and a fixed `yyyy-MM-dd` reads another year under a Buddhist or Japanese calendar.
    /// Only the Reports list's own display may follow the Mac.
    @Test func reportAndFixedFormatDatesSetTheirLocale() throws {
        let root = Self.appDirectory.appendingPathComponent("Sources/JamfReports")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 100)
        let declaration = try Regex(#"\bDateFormatter\(\)"#)
        var missing: [String] = []
        for file in files where file.lastPathComponent != "ReportLibrary.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(declaration) {
                let window = lines[index..<min(index + 7, lines.count)].joined(separator: "\n")
                let inReport = file.path.contains("/Engine/")
                guard (inReport || window.contains("dateFormat")), !window.contains(".locale")
                else { continue }
                missing.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(missing == [])
    }

    /// `LShown` finds a template's text only by its exact English, so a reworded template must
    /// reword its key too. The templates' own text is what `shownKeys` has to list.
    @Test func everyTemplateStringIsInTheCatalog() throws {
        let folder = Self.appDirectory.appendingPathComponent("Sources/JamfReports/Engine/Templates")
        let keys = Set(Self.catalog.map(\.key))
        let property = try Regex(#"let (?:displayName|description|audience) = ((?:"[^"]*"(?: \+\s*)?)+)"#)
        let literal = try Regex(#""([^"]*)""#)
        var found = 0
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in source.matches(of: property) {
                guard let value = match.output[1].substring else { continue }
                let text = value.matches(of: literal)
                    .compactMap { $0.output[1].substring }.joined()
                found += 1
                #expect(keys.contains(text), "\(file.lastPathComponent): \(text)")
            }
        }
        #expect(found == 24)
    }

    @Test func noXMLEntitiesOrPlaceholdersInTranslations() {
        var problems: [String] = []
        for entry in Self.translatable {
            for language in Self.languages {
                for unit in entry.units[language] ?? []
                where unit.value.contains("&amp;") || unit.value.contains("&lt;") || unit.value.contains("TODO") {
                    problems.append("\(language): \(unit.value)")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(10))")
    }

    /// A string added to the source with no catalog entry would show English in every language.
    @Test func everySourceLiteralIsInTheCatalog() throws {
        let keys = Self.catalog.map(\.key)
        let exact = Set(keys)
        let templates = keys.filter { $0.contains("%") }.map(Self.wildcard)
        let root = Self.appDirectory.appendingPathComponent("Sources/JamfReports")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var missing: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "Localization.swift",
                  !url.lastPathComponent.hasPrefix("DemoData") else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for match in source.matches(of: /\b(?:L|LK|Text)\("((?:[^"\\\n]|\\.)*)"\)/) {
                let literal = String(match.output.1)
                let key = Self.unescaped(literal)
                if literal.contains("\\(") {
                    let flattened = key.replacing(/\\\((?:[^()"]|"[^"]*"|\([^()]*\))*\)/, with: "\u{1}")
                    if flattened.contains("\\(") { continue }
                    if !templates.contains(where: { flattened.wholeMatch(of: $0) != nil }) {
                        missing.append(key)
                    }
                } else if !exact.contains(key), !exact.contains(key.replacingOccurrences(of: "%", with: "%%")) {
                    missing.append(key)
                }
            }
        }
        #expect(missing.isEmpty, "run scripts/sync-strings.zsh; \(missing.count): \(missing.prefix(40))")
    }

    /// `.help(demo ? DemoData.liveOnlyHelp : "…")` types the literal as a `String`, which SwiftUI
    /// shows verbatim: the live branch needs `L("…")` like the demo one. An empty branch is fine. An empty branch is fine.
    @Test func demoTooltipsTranslateTheirLiveBranch() throws {
        let root = Self.appDirectory.appendingPathComponent("Sources/JamfReports")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let bare = /liveOnlyHelp\s*:\s*"[^"]/
        var found: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains(bare) { found.append(url.lastPathComponent) }
        }
        #expect(found.isEmpty, "wrap the live branch in L(\"…\"): \(found)")
    }

    /// A Swift literal's text as the compiler sees it, with its escapes decoded.
    private static func unescaped(_ literal: String) -> String {
        var text = literal.replacing(/\\u\{([0-9A-Fa-f]+)\}/) { match in
            UInt32(match.output.1, radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } ?? ""
        }
        for (escaped, plain) in [("\\\"", "\""), ("\\'", "'"), ("\\n", "\n"), ("\\t", "\t"), ("\\\\", "\\")] {
            text = text.replacingOccurrences(of: escaped, with: plain)
        }
        return text
    }

    /// A key like `%lld of %@` as a pattern that matches the same literal with `\u{1}` per argument.
    private static func wildcard(_ key: String) -> Regex<AnyRegexOutput> {
        let escaped = NSRegularExpression.escapedPattern(for: key.replacingOccurrences(of: "%%", with: "\u{2}"))
            .replacingOccurrences(of: "\u{2}", with: "%")
            .replacingOccurrences(
                of: #"%(?:\\\.\d+f|lld|ld|@|d|f|\\\.\df)"#, with: ".", options: .regularExpression
            )
        return (try? Regex(escaped)) ?? (try! Regex("^$"))
    }
}
