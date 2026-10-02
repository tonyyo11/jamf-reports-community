import Foundation

enum YAMLCodec {
    enum YAMLScalar: Equatable, Sendable {
        case string(String)
        case int(Int)
        case bool(Bool)
        case null
    }

    indirect enum YAMLValue: Equatable, Sendable {
        case scalar(YAMLScalar)
        case mapping(YAMLMapping)
        case sequence([YAMLValue])
    }

    struct YAMLEntry: Equatable, Sendable {
        var key: String
        var value: YAMLValue
    }

    struct YAMLMapping: Equatable, Sendable {
        var entries: [YAMLEntry]

        /// The last value set for `key`, the one the report engine's decoder reads.
        func value(for key: String) -> YAMLValue? {
            entries.last { $0.key == key }?.value
        }

        /// Replaces the value `value(for:)` returns, so an edit lands where it is read.
        mutating func set(_ key: String, value: YAMLValue) {
            if let index = entries.lastIndex(where: { $0.key == key }) {
                entries[index].value = value
            } else {
                entries.append(.init(key: key, value: value))
            }
        }
    }

    struct YAMLDocument: Equatable, Sendable {
        var originalText: String
        var root: YAMLValue
        /// Keys whose values were reconstructed from the corrupt
        /// `key: []` + orphaned `- item` pattern (written by GUI builds
        /// prior to the compact-sequence parser fix). Empty for well-formed
        /// documents. Callers should log a warning and re-save to heal the
        /// underlying file.
        var repairedKeys: Set<String> = []
        /// Lines the reader did not take as written, in line order. Empty for a well-formed file.
        var parseNotes: [ParseNote] = []
    }

    /// A line the reader did not take as written. `line` counts from 1.
    struct ParseNote: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Indented `found` spaces where its block's keys sit at `expected`; not read.
            case indentation(found: Int, expected: Int)
            /// No `key: value` where a key was expected; not read.
            case noKey
            /// A tab in the indentation, which YAML does not allow; read as indented `spaces`.
            case tab(spaces: Int)
            /// The key is set again on `readLine`, and that value is the one read.
            case duplicateKey(String, readLine: Int)
            /// A `|` or `>` block value, which the reader does not support: the value reads as
            /// the indicator and the lines under it are not read.
            case blockScalar(key: String, indicator: String)
            /// List items with no key above them to belong to; not read.
            case orphanItems
        }

        let line: Int
        let kind: Kind

        /// What happened to the line. Keys pass through `ConfigSchema.displayText`; no value
        /// typed in the file is shown.
        var detail: String {
            switch kind {
            case .indentation(let found, let expected):
                "indented \(Self.spaces(found)) where \(Self.spaces(expected)) were expected, "
                    + "so it was not read"
            case .noKey:
                "no \"key: value\" on this line, so it was not read"
            case .tab(let spaces):
                "a tab in the indentation, which YAML does not allow; read as indented "
                    + Self.spaces(spaces)
            case .duplicateKey(let key, let readLine) where readLine == line:
                "\"\(ConfigSchema.displayText(key))\" is set twice on this line; "
                    + "the second value is the one read"
            case .duplicateKey(let key, let readLine):
                "\"\(ConfigSchema.displayText(key))\" is set again on line \(readLine), "
                    + "and that value is the one read"
            case .blockScalar(let key, let indicator):
                "\"\(ConfigSchema.displayText(key))\" uses a block value (\(indicator)), which "
                    + "is not supported: it reads as \"\(indicator)\" and the lines under it "
                    + "are not read"
            case .orphanItems:
                "a list item with no key above it, so it was not read"
            }
        }

        /// `Line N: <detail>`, as the Config screen lists it.
        var display: String { "Line \(line): \(detail)" }

        private static func spaces(_ count: Int) -> String {
            count == 1 ? "1 space" : "\(count) spaces"
        }
    }

    enum CodecError: Error, LocalizedError {
        case invalidTopLevel

        var errorDescription: String? {
            switch self {
            case .invalidTopLevel: "config.yaml must contain a top-level YAML mapping."
            }
        }
    }

    static func decode(_ text: String) throws -> YAMLDocument {
        // A byte-order mark is not part of the first key, and a CRLF is one line break: a
        // note's line number is then the one an editor shows, and `encode` does not write an
        // empty line after every line it keeps.
        let text = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var parser = Parser(text: text)
        let root = parser.parseBlock(indent: 0)
        guard case .mapping = root else { throw CodecError.invalidTopLevel }
        let notes = parser.notes.enumerated()
            .sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
            .map(\.element)
        return YAMLDocument(
            originalText: text, root: root, repairedKeys: parser.repairedKeys, parseNotes: notes)
    }

    static func emptyDocument() -> YAMLDocument {
        YAMLDocument(originalText: "", root: .mapping(.init(entries: [])))
    }

    static func encode(
        _ document: YAMLDocument,
        replacingTopLevelKeys keys: Set<String>
    ) throws -> String {
        guard case .mapping(let root) = document.root else { throw CodecError.invalidTopLevel }

        var output: [String] = []
        let lines = document.originalText.components(separatedBy: .newlines)
        var replaced: Set<String> = []
        var index = 0
        // Only the last copy of a repeated key is the one read, so only it is rewritten; an
        // earlier copy stays as typed.
        var lastLine: [String: Int] = [:]
        for (offset, line) in lines.enumerated() {
            if let key = topLevelKey(in: line), keys.contains(key) { lastLine[key] = offset }
        }

        while index < lines.count {
            if let key = topLevelKey(in: lines[index]),
               lastLine[key] == index,
               let value = root.value(for: key) {
                output.append(contentsOf: emitTopLevel(key: key, value: value))
                replaced.insert(key)
                index = endOfTopLevelBlock(in: lines, startingAt: index)
            } else {
                output.append(lines[index])
                index += 1
            }
        }

        if output.last == "" {
            output.removeLast()
        }

        for entry in root.entries where keys.contains(entry.key) && !replaced.contains(entry.key) {
            if !output.isEmpty { output.append("") }
            output.append(contentsOf: emitTopLevel(key: entry.key, value: entry.value))
        }

        return output.joined(separator: "\n") + "\n"
    }

    private static func topLevelKey(in line: String) -> String? {
        guard !line.isEmpty,
              line.first != " ",
              // Sequence items are never top-level keys. Treating them as
              // keys made endOfTopLevelBlock stop at orphaned `- name:` lines,
              // which preserved (and duplicated) corrupt content on re-encode.
              !line.hasPrefix("- "),
              !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
              let parsed = parseKeyValue(line) else {
            return nil
        }
        return parsed.key
    }

    private static func endOfTopLevelBlock(in lines: [String], startingAt start: Int) -> Int {
        var index = start + 1
        while index < lines.count {
            if topLevelKey(in: lines[index]) != nil { break }
            index += 1
        }
        return index
    }

    private static func emitTopLevel(key: String, value: YAMLValue) -> [String] {
        switch value {
        case .scalar(let scalar):
            return ["\(key): \(emitScalar(scalar))"]
        case .mapping(let mapping):
            if mapping.entries.isEmpty { return ["\(key): {}"] }
            return ["\(key):"] + emitMapping(mapping, indent: 2)
        case .sequence(let values):
            if values.isEmpty { return ["\(key): []"] }
            return ["\(key):"] + emitSequence(values, indent: 2)
        }
    }

    private static func emitMapping(_ mapping: YAMLMapping, indent: Int) -> [String] {
        let spaces = String(repeating: " ", count: indent)
        var lines: [String] = []
        for entry in mapping.entries {
            switch entry.value {
            case .scalar(let scalar):
                lines.append("\(spaces)\(entry.key): \(emitScalar(scalar))")
            case .mapping(let nested):
                if nested.entries.isEmpty {
                    lines.append("\(spaces)\(entry.key): {}")
                } else {
                    lines.append("\(spaces)\(entry.key):")
                    lines.append(contentsOf: emitMapping(nested, indent: indent + 2))
                }
            case .sequence(let values):
                if values.isEmpty {
                    lines.append("\(spaces)\(entry.key): []")
                } else {
                    lines.append("\(spaces)\(entry.key):")
                    lines.append(contentsOf: emitSequence(values, indent: indent + 2))
                }
            }
        }
        return lines
    }

    private static func emitSequence(_ values: [YAMLValue], indent: Int) -> [String] {
        let spaces = String(repeating: " ", count: indent)
        var lines: [String] = []
        for value in values {
            switch value {
            case .scalar(let scalar):
                lines.append("\(spaces)- \(emitScalar(scalar))")
            case .mapping(let mapping):
                guard let first = mapping.entries.first else {
                    lines.append("\(spaces)- {}")
                    continue
                }
                lines.append(contentsOf: emitSequenceMappingFirstLine(first, spaces: spaces, indent: indent))
                let rest = YAMLMapping(entries: Array(mapping.entries.dropFirst()))
                lines.append(contentsOf: emitMapping(rest, indent: indent + 2))
            case .sequence(let nested):
                lines.append("\(spaces)-")
                lines.append(contentsOf: emitSequence(nested, indent: indent + 2))
            }
        }
        return lines
    }

    private static func emitSequenceMappingFirstLine(
        _ entry: YAMLEntry,
        spaces: String,
        indent: Int
    ) -> [String] {
        switch entry.value {
        case .scalar(let scalar):
            return ["\(spaces)- \(entry.key): \(emitScalar(scalar))"]
        case .mapping(let nested):
            return ["\(spaces)- \(entry.key):"] + emitMapping(nested, indent: indent + 2)
        case .sequence(let values):
            if values.isEmpty { return ["\(spaces)- \(entry.key): []"] }
            return ["\(spaces)- \(entry.key):"] + emitSequence(values, indent: indent + 2)
        }
    }

    private static func emitScalar(_ scalar: YAMLScalar) -> String {
        switch scalar {
        case .int(let value): return "\(value)"
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .string(let value): return quotedIfNeeded(value)
        }
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        let special = CharacterSet(charactersIn: ":#&*!|>'\"%")
        let needsQuote = value.isEmpty
            || value.rangeOfCharacter(from: special) != nil
            || value.first?.isWhitespace == true
            || value.last?.isWhitespace == true
            || value.contains("\n") || value.contains("\r")
            || ["true", "false", "null", "~"].contains(value.lowercased())
            || Int(value) != nil
            // A string that LOOKS like flow/block syntax must stay quoted, or the
            // round-trip type-flips it (e.g. "[a, b]" re-parses as a sequence and
            // the whole config decode fails on the type mismatch).
            || value.hasPrefix("[") || value.hasPrefix("{") || value.hasPrefix("-")
        guard needsQuote else { return value }
        // Escape in order: backslash first, then other special chars.
        // \n and \r are always escaped so a value containing a literal newline
        // cannot break the YAML line structure even when wrapped in quotes.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    fileprivate static func parseKeyValue(_ line: String) -> (key: String, value: String)? {
        var inSingle = false
        var inDouble = false
        var previous: Character?

        for index in line.indices {
            let char = line[index]
            if char == "'", !inDouble { inSingle.toggle() }
            if char == "\"", !inSingle, previous != "\\" { inDouble.toggle() }
            if char == ":", !inSingle, !inDouble {
                let key = line[..<index].trimmingCharacters(in: .whitespaces)
                let valueStart = line.index(after: index)
                let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key, value)
            }
            previous = char
        }
        return nil
    }
}

extension YAMLCodec.YAMLValue {
    var mapping: YAMLCodec.YAMLMapping? {
        if case .mapping(let value) = self { return value }
        return nil
    }

    var sequence: [YAMLCodec.YAMLValue]? {
        if case .sequence(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        guard case .scalar(let scalar) = self else { return nil }
        switch scalar {
        case .string(let value): return value
        case .int(let value): return "\(value)"
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        }
    }

    var intValue: Int? {
        guard case .scalar(let scalar) = self else { return nil }
        switch scalar {
        case .int(let value): return value
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        guard case .scalar(let scalar) = self else { return nil }
        switch scalar {
        case .bool(let value): return value
        case .string(let value):
            if value.lowercased() == "true" { return true }
            if value.lowercased() == "false" { return false }
            return nil
        default:
            return nil
        }
    }
}

private struct Parser {
    private let lines: [String]
    private var index = 0
    /// Keys whose orphaned `- item` lines were re-attached during parsing.
    /// See `YAMLCodec.YAMLDocument.repairedKeys`.
    private(set) var repairedKeys: Set<String> = []
    /// See `YAMLCodec.YAMLDocument.parseNotes`; collected in the order found.
    private(set) var notes: [YAMLCodec.ParseNote] = []
    /// The line of the key or item whose value is being read, for a duplicate key inside a
    /// flow mapping.
    private var valueLine = 0

    init(text: String) {
        self.lines = text.components(separatedBy: .newlines)
        for (offset, line) in lines.enumerated() {
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let content = line.dropFirst(lead.count)
            guard lead.contains("\t"), !content.isEmpty, !content.hasPrefix("#") else { continue }
            note(offset + 1, .tab(spaces: indentation(of: line)))
        }
    }

    private mutating func note(_ line: Int, _ kind: YAMLCodec.ParseNote.Kind) {
        notes.append(.init(line: line, kind: kind))
    }

    mutating func parseBlock(indent: Int) -> YAMLCodec.YAMLValue {
        skipIgnorable()
        guard index < lines.count else { return .mapping(.init(entries: [])) }
        let line = lines[index]
        if indentation(of: line) == indent, Self.isListItem(trimmedContent(line)) {
            return .sequence(parseSequence(indent: indent))
        }
        return .mapping(parseMapping(indent: indent))
    }

    /// `- item`, or a bare `-` whose item is the block on the lines under it.
    private static func isListItem(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed == "-"
    }

    /// `seedKeys` are keys already read for this mapping (a list item's first key, on its `- `
    /// line), so a repeat of one is noted.
    private mutating func parseMapping(
        indent: Int, seedKeys: [String: Int] = [:]
    ) -> YAMLCodec.YAMLMapping {
        var entries: [YAMLCodec.YAMLEntry] = []
        var keyLines = seedKeys
        // The column of the last key's nested block: where a stray deeper line most likely
        // belongs, so its note names that column.
        var childIndent: Int?

        while index < lines.count {
            skipIgnorable()
            guard index < lines.count else { break }

            let line = lines[index]
            let currentIndent = indentation(of: line)
            let trimmed = trimmedContent(line)
            if currentIndent < indent { break }
            if Self.isListItem(trimmed) {
                // Sequence items no key took. Well-formed documents never
                // reach here (a list under a bare `key:` is consumed by
                // parseNestedValue below), so this is a mis-indented item
                // or the corrupt `key: []` + orphaned `- item` pattern from
                // pre-fix GUI builds. Repair by attaching the items to the
                // previous key when it holds an empty/null value; otherwise
                // drop them — either way, keep parsing so the keys after the
                // orphans are not silently lost.
                let orphanLine = index + 1
                let orphans = parseSequence(indent: currentIndent)
                if let last = entries.indices.last,
                   entries[last].value == .sequence([]) || entries[last].value == .scalar(.null) {
                    entries[last].value = .sequence(orphans)
                    repairedKeys.insert(entries[last].key)
                } else if currentIndent > indent, let childIndent {
                    note(orphanLine, .indentation(found: currentIndent, expected: childIndent))
                } else {
                    note(orphanLine, .orphanItems)
                }
                continue
            }
            guard currentIndent == indent else {
                note(index + 1, .indentation(found: currentIndent, expected: childIndent ?? indent))
                index += 1
                continue
            }
            guard let parsed = YAMLCodec.parseKeyValue(stripInlineComment(trimmed)) else {
                note(index + 1, .noKey)
                index += 1
                continue
            }

            let keyLine = index + 1
            index += 1
            valueLine = keyLine
            let value: YAMLCodec.YAMLValue
            if parsed.value.isEmpty {
                // Compact block-sequence syntax, where list items share the parent key's
                // indent, is valid YAML (PyYAML / ruamel accept it):
                //   security_agents:
                //   - name: foo
                (value, childIndent) = parseNestedValue(below: indent, listAtSameColumn: true)
            } else {
                value = parseScalar(parsed.value)
                childIndent = nil
                skipBlockScalar(parsed.value, key: parsed.key, line: keyLine, indent: indent)
            }
            if let earlier = keyLines[parsed.key] {
                note(earlier, .duplicateKey(parsed.key, readLine: keyLine))
            }
            keyLines[parsed.key] = keyLine
            entries.append(.init(key: parsed.key, value: value))
        }

        return .init(entries: entries)
    }

    /// A `|` or `>` value is not supported. It keeps reading as the indicator, as before; the
    /// lines under it, which would each be skipped, are skipped here under one note.
    private mutating func skipBlockScalar(_ value: String, key: String, line: Int, indent: Int) {
        guard let first = value.first, first == "|" || first == ">", value.count <= 3,
              value.dropFirst().allSatisfy({ "+-123456789".contains($0) }) else { return }
        while index < lines.count,
              trimmedContent(lines[index]).isEmpty || indentation(of: lines[index]) > indent {
            index += 1
        }
        note(line, .blockScalar(key: key, indicator: value))
    }

    /// The value of a `key:` with nothing after the colon: the block on the following lines, at
    /// whatever column its first line sits, with that column. Null when nothing deeper follows
    /// (an empty mapping would later fail to decode as `[Element]` or `Optional<Element>`).
    private mutating func parseNestedValue(
        below column: Int, listAtSameColumn: Bool
    ) -> (YAMLCodec.YAMLValue, Int?) {
        guard let next = lines[index...].first(where: {
            let trimmed = trimmedContent($0)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }) else { return (.scalar(.null), nil) }
        let child = indentation(of: next)
        let isList = Self.isListItem(trimmedContent(next))
        guard child > column || (isList && listAtSameColumn && child == column) else {
            return (.scalar(.null), nil)
        }
        return (isList ? .sequence(parseSequence(indent: child))
                       : .mapping(parseMapping(indent: child)), child)
    }

    private mutating func parseSequence(indent: Int) -> [YAMLCodec.YAMLValue] {
        var values: [YAMLCodec.YAMLValue] = []

        while index < lines.count {
            skipIgnorable()
            guard index < lines.count else { break }

            let line = lines[index]
            let currentIndent = indentation(of: line)
            let trimmed = trimmedContent(line)
            if currentIndent < indent { break }
            guard currentIndent == indent, Self.isListItem(trimmed) else { break }

            let afterDash = trimmed.dropFirst()
            let rest = afterDash.trimmingCharacters(in: .whitespaces)
            // The column the item's text starts at: `-   name:` puts its keys 4 past the dash.
            let itemIndent = indent + 1 + afterDash.prefix { $0 == " " }.count
            let itemLine = index + 1
            index += 1
            valueLine = itemLine

            if rest.isEmpty {
                values.append(parseNestedValue(below: indent, listAtSameColumn: false).0)
            } else if rest.hasPrefix("{") || rest.hasPrefix("[") {
                // Flow-style item (`- {label: …}`). Must run before
                // parseKeyValue, which would otherwise split on the first
                // colon inside the braces and fabricate a `{label` key.
                values.append(parseScalar(rest))
            } else if let parsed = YAMLCodec.parseKeyValue(stripInlineComment(rest)) {
                let first: YAMLCodec.YAMLValue
                if parsed.value.isEmpty {
                    first = parseNestedValue(below: itemIndent, listAtSameColumn: true).0
                } else {
                    first = parseScalar(parsed.value)
                    skipBlockScalar(
                        parsed.value, key: parsed.key, line: itemLine, indent: itemIndent)
                }
                var entries = [YAMLCodec.YAMLEntry(key: parsed.key, value: first)]
                let continuation = parseMapping(
                    indent: itemIndent, seedKeys: [parsed.key: itemLine])
                entries.append(contentsOf: continuation.entries)
                values.append(.mapping(.init(entries: entries)))
            } else {
                values.append(parseScalar(rest))
            }
        }

        return values
    }

    private mutating func skipIgnorable() {
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
            } else {
                break
            }
        }
    }

    private mutating func parseScalar(_ raw: String) -> YAMLCodec.YAMLValue {
        let value = stripInlineComment(raw).trimmingCharacters(in: .whitespaces)
        if value == "[]" { return .sequence([]) }
        if value == "{}" { return .mapping(.init(entries: [])) }
        // Flow-style collections — `{label: "Pass", min_failures: 0}` /
        // `[a, b]`. config.example.yaml's compliance bands ship in this form,
        // so the block-only parser turned every seeded workspace's config
        // unparseable ("config.yaml could not be parsed", #181 field report).
        // Malformed flow text falls through to a plain string scalar.
        if value.hasPrefix("{"), value.hasSuffix("}"), value.count >= 2,
           let mapping = parseFlowMapping(value) {
            return mapping
        }
        if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2,
           let sequence = parseFlowSequence(value) {
            return sequence
        }
        if value == "null" || value == "~" { return .scalar(.null) }
        if value.lowercased() == "true" { return .scalar(.bool(true)) }
        if value.lowercased() == "false" { return .scalar(.bool(false)) }
        if let int = Int(value) { return .scalar(.int(int)) }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return .scalar(.string(unescapeDoubleQuoted(String(value.dropFirst().dropLast()))))
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return .scalar(.string(unescapeSingleQuoted(String(value.dropFirst().dropLast()))))
        }
        return .scalar(.string(value))
    }

    /// Parse `{key: value, key: value}`. Returns nil when any part is not a
    /// `key: value` pair, so almost-flow text degrades to a string scalar
    /// instead of silently dropping content.
    private mutating func parseFlowMapping(_ value: String) -> YAMLCodec.YAMLValue? {
        let inner = String(value.dropFirst().dropLast())
        var entries: [YAMLCodec.YAMLEntry] = []
        // Notes for a mapping that degrades to a string are taken back with it.
        let notesBefore = notes.count
        for part in splitFlowParts(inner) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let parsed = YAMLCodec.parseKeyValue(trimmed), !parsed.value.isEmpty else {
                notes.removeSubrange(notesBefore...)
                return nil
            }
            let key = unquoteFlowKey(parsed.key)
            if entries.contains(where: { $0.key == key }) {
                note(valueLine, .duplicateKey(key, readLine: valueLine))
            }
            entries.append(.init(key: key, value: parseScalar(parsed.value)))
        }
        return .mapping(.init(entries: entries))
    }

    /// Parse `[a, b, {k: v}]`. Elements recurse through `parseScalar`, so
    /// nested flow collections work.
    private mutating func parseFlowSequence(_ value: String) -> YAMLCodec.YAMLValue? {
        let inner = String(value.dropFirst().dropLast())
        var values: [YAMLCodec.YAMLValue] = []
        for part in splitFlowParts(inner) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            values.append(parseScalar(trimmed))
        }
        return .sequence(values)
    }

    /// Split flow-collection content on top-level commas — commas inside
    /// quotes or nested `{}` / `[]` do not split.
    private func splitFlowParts(_ inner: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inSingle = false
        var inDouble = false
        var previous: Character?
        for char in inner {
            if char == "'", !inDouble { inSingle.toggle() }
            if char == "\"", !inSingle, previous != "\\" { inDouble.toggle() }
            if !inSingle, !inDouble {
                switch char {
                case "{", "[": depth += 1
                case "}", "]": depth -= 1
                case "," where depth == 0:
                    parts.append(current)
                    current = ""
                    previous = char
                    continue
                default: break
                }
            }
            current.append(char)
            previous = char
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(current)
        }
        return parts
    }

    private func unquoteFlowKey(_ key: String) -> String {
        if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
            return unescapeDoubleQuoted(String(key.dropFirst().dropLast()))
        }
        if key.hasPrefix("'"), key.hasSuffix("'"), key.count >= 2 {
            return unescapeSingleQuoted(String(key.dropFirst().dropLast()))
        }
        return key
    }

    /// Inside single quotes, `''` is one `'`.
    private func unescapeSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "''", with: "'")
    }

    private func unescapeDoubleQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func stripInlineComment(_ value: String) -> String {
        var inSingle = false
        var inDouble = false
        var previous: Character?

        for index in value.indices {
            let char = value[index]
            if char == "'", !inDouble { inSingle.toggle() }
            if char == "\"", !inSingle, previous != "\\" { inDouble.toggle() }
            if char == "#", !inSingle, !inDouble {
                if index == value.startIndex || previous?.isWhitespace == true {
                    return String(value[..<index]).trimmingCharacters(in: .whitespaces)
                }
            }
            previous = char
        }
        return value
    }

    private func trimmedContent(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}
