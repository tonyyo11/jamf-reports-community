import Foundation

/// One Extension Attribute jamf-cli already collected, offered for adoption into `config.yaml`.
/// Carries values only — never the device a value came from.
struct CollectedEACandidate: Identifiable, Sendable, Equatable {
    let name: String
    /// Rows with a value in the newest `ea-results`.
    let valueCount: Int
    let distinctValueCount: Int
    /// One of `boolean|date|percentage|version|text`.
    let type: String
    /// The most common value (ties: alphabetical): the default `true_value` and connected value.
    let sampleValue: String
    /// The first values seen, capped at `CollectedEACandidates.sampleCap`, for the parse check.
    let sampleValues: [String]
    /// Defined in Jamf Pro, but `ea-results` holds no value for it.
    var hasNoValues: Bool { valueCount == 0 }
    /// Already a `custom_eas` or `security_agents` column.
    let alreadyTracked: Bool
    var id: String { name }

    /// `column` is the EA name: `ea-results` rows are keyed by it.
    var proposal: ProposedEA {
        ProposedEA(name: name, column: name, type: type, sampleValue: sampleValue)
    }
}

enum CollectedEACandidates {
    static let sampleCap = 50

    /// Candidates from the newest `ea-results` and `computer-extension-attributes` snapshots of
    /// `dataDir`, flagged against the columns `config.yaml` already tracks.
    static func load(dataDir: URL, tracked: Set<String>) -> [CollectedEACandidate] {
        func newest(_ kind: String) -> Data? {
            FileManager.newestJSONFile(in: dataDir.appendingPathComponent(kind, isDirectory: true))
                .flatMap { BoundedFile.readLogged($0) }
        }
        let rows = newest("ea-results").flatMap { EAResultRow.decodeSnapshot($0).rows } ?? []
        let definitions = newest("computer-extension-attributes")
            .flatMap { try? JSONDecoder().decode([ExtensionAttribute].self, from: $0) } ?? []
        return build(rows: rows, definitions: definitions, tracked: tracked)
    }

    static func build(
        rows: [EAResultRow], definitions: [ExtensionAttribute], tracked: Set<String>
    ) -> [CollectedEACandidate] {
        var counts: [String: [String: Int]] = [:]
        var firstSeen: [String: [String]] = [:]
        for row in rows {
            guard let name = row.eaName, !name.isEmpty else { continue }
            if counts[name] == nil { counts[name] = [:] }
            let raw = row.value?.stringValue ?? ""
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            counts[name, default: [:]][value, default: 0] += 1
            if firstSeen[name, default: []].count < sampleCap {
                firstSeen[name, default: []].append(value)
            }
        }
        // First definition wins: display names are not unique.
        var dataTypes: [String: String] = [:]
        for def in definitions {
            guard let name = def.name, !name.isEmpty else { continue }
            if dataTypes[name] == nil { dataTypes[name] = (def.dataType ?? "").uppercased() }
            if counts[name] == nil { counts[name] = [:] }
        }
        let trackedLower = Set(tracked.map { $0.lowercased() })
        return counts.map { name, valueCounts in
            let top = valueCounts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
            let samples = firstSeen[name] ?? []
            let type = guessType(
                dataType: dataTypes[name] ?? "", values: Array(valueCounts.keys),
                top: top, samples: samples)
            return CollectedEACandidate(
                name: name,
                valueCount: valueCounts.values.reduce(0, +),
                distinctValueCount: valueCounts.count,
                type: type,
                sampleValue: top,
                sampleValues: samples,
                alreadyTracked: trackedLower.contains(name.lowercased()))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Jamf's own data type decides a date; an integer is a percentage only when every value
    /// fits 0-100; a string goes through the CSV guess over the values alone (the name would
    /// misread "Enrolled Via DEP" as a date).
    private static func guessType(
        dataType: String, values: [String], top: String, samples: [String]
    ) -> String {
        if dataType == "DATE" { return "date" }
        if values.isEmpty { return "text" }
        if dataType == "INTEGER" {
            let fits = values.allSatisfy { Double($0).map { (0...100).contains($0) } ?? false }
            return fits ? "percentage" : "text"
        }
        return EATypeGuess.guess(header: "", sampleValue: top, samples: samples)
    }
}
