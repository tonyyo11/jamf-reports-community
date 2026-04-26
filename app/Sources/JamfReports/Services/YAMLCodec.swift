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

        func value(for key: String) -> YAMLValue? {
            entries.first { $0.key == key }?.value
        }

        mutating func set(_ key: String, value: YAMLValue) {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                entries[index].value = value
            } else {
                entries.append(.init(key: key, value: value))
            }
        }
    }

    struct YAMLDocument: Equatable, Sendable {
        var originalText: String
        var root: YAMLValue
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
        var parser = Parser(text: text)
        let root = parser.parseBlock(indent: 0)
        guard case .mapping = root else { throw CodecError.invalidTopLevel }
        return YAMLDocument(originalText: text, root: root)
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

        while index < lines.count {
            if let key = topLevelKey(in: lines[index]),
               keys.contains(key),
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
            || ["true", "false", "null", "~"].contains(value.lowercased())
            || Int(value) != nil
        guard needsQuote else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

    init(text: String) {
        self.lines = text.components(separatedBy: .newlines)
    }

    mutating func parseBlock(indent: Int) -> YAMLCodec.YAMLValue {
        skipIgnorable()
        guard index < lines.count else { return .mapping(.init(entries: [])) }
        let line = lines[index]
        if indentation(of: line) == indent,
           trimmedContent(line).hasPrefix("- ") {
            return .sequence(parseSequence(indent: indent))
        }
        return .mapping(parseMapping(indent: indent))
    }

    private mutating func parseMapping(indent: Int) -> YAMLCodec.YAMLMapping {
        var entries: [YAMLCodec.YAMLEntry] = []

        while index < lines.count {
            skipIgnorable()
            guard index < lines.count else { break }

            let line = lines[index]
            let currentIndent = indentation(of: line)
            let trimmed = trimmedContent(line)
            if currentIndent < indent || trimmed.hasPrefix("- ") { break }
            guard currentIndent == indent else {
                index += 1
                continue
            }
            guard let parsed = YAMLCodec.parseKeyValue(stripInlineComment(trimmed)) else {
                index += 1
                continue
            }

            index += 1
            let value: YAMLCodec.YAMLValue
            if parsed.value.isEmpty {
                value = parseBlock(indent: indent + 2)
            } else {
                value = parseScalar(parsed.value)
            }
            entries.append(.init(key: parsed.key, value: value))
        }

        return .init(entries: entries)
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
            guard currentIndent == indent, trimmed.hasPrefix("- ") else { break }

            let restStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
            let rest = String(trimmed[restStart...]).trimmingCharacters(in: .whitespaces)
            index += 1

            if rest.isEmpty {
                values.append(parseBlock(indent: indent + 2))
            } else if let parsed = YAMLCodec.parseKeyValue(stripInlineComment(rest)) {
                var entries = [YAMLCodec.YAMLEntry(
                    key: parsed.key,
                    value: parsed.value.isEmpty ? parseBlock(indent: indent + 2) : parseScalar(parsed.value)
                )]
                let continuation = parseMapping(indent: indent + 2)
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

    private func parseScalar(_ raw: String) -> YAMLCodec.YAMLValue {
        let value = stripInlineComment(raw).trimmingCharacters(in: .whitespaces)
        if value == "[]" { return .sequence([]) }
        if value == "{}" { return .mapping(.init(entries: [])) }
        if value == "null" || value == "~" { return .scalar(.null) }
        if value.lowercased() == "true" { return .scalar(.bool(true)) }
        if value.lowercased() == "false" { return .scalar(.bool(false)) }
        if let int = Int(value) { return .scalar(.int(int)) }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            return .scalar(.string(unescapeDoubleQuoted(String(value.dropFirst().dropLast()))))
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return .scalar(.string(String(value.dropFirst().dropLast())))
        }
        return .scalar(.string(value))
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
