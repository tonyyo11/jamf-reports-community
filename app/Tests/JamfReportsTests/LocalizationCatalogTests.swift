import Foundation
import Testing

/// Machine translations nobody fluent reviews, so these are the proof they are complete and safe to
/// show: every key has every language, format specifiers line up, and product and config names stay.
struct LocalizationCatalogTests {
    static let languages = ["fr", "es", "de"]
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
        return patterns.flatMap { text.matches(of: $0).map { String($0.output) } }
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
