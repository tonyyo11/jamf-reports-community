import Foundation
import CryptoKit

// MARK: - Prior CSV Discovery

/// Mirrors `_load_prior_snapshot` (Python line 2545).
///
/// Finds the newest CSV under `historicalDir` that:
///  - is not the same file as `currentCSVURL`
///  - does not have the same size + SHA-256 as `currentCSVURL`
///  - shares the same column schema as `currentCSVURL`
enum PriorCSVLoader {

    struct Result {
        let rows: [CSVRow]
        let label: String  // filename only, for sheet subtitle
    }

    /// Load the prior snapshot, or return `nil` if no suitable candidate is found.
    static func load(historicalDir: URL, currentCSVURL: URL) -> Result? {
        let fm = FileManager.default
        guard let currentData = try? Data(contentsOf: currentCSVURL),
              let (currentHeaders, _) = try? CSVParser.parse(currentData) else {
            return nil
        }
        let currentSize = currentData.count
        let currentHash = SHA256.hash(data: currentData).map { String(format: "%02x", $0) }.joined()

        guard let entries = try? fm.contentsOfDirectory(
            at: historicalDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = entries
            .filter { $0.pathExtension.lowercased() == "csv" }
            .compactMap { url -> (url: URL, modified: Date)? in
                let mod = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate ?? Date.distantPast
                return (url, mod)
            }
            .sorted { $0.modified > $1.modified }

        for (url, _) in candidates {
            // Skip if same canonical path as current CSV.
            let canonCurrent = (try? currentCSVURL.resourceValues(
                forKeys: [.canonicalPathKey]
            ))?.canonicalPath ?? currentCSVURL.path
            let canonCandidate = (try? url.resourceValues(
                forKeys: [.canonicalPathKey]
            ))?.canonicalPath ?? url.path
            if canonCandidate == canonCurrent { continue }

            guard let candidateData = try? Data(contentsOf: url) else { continue }

            // Skip if same size + same hash (archived copy of current).
            if candidateData.count == currentSize {
                let candidateHash = SHA256.hash(data: candidateData)
                    .map { String(format: "%02x", $0) }.joined()
                if candidateHash == currentHash { continue }
            }

            // Skip if column schema differs.
            guard let (candidateHeaders, _) = try? CSVParser.parse(candidateData) else { continue }
            guard candidateHeaders == currentHeaders else {
                print("[skip] \(url.lastPathComponent): column schema differs")
                continue
            }

            guard let (_, rows) = try? CSVParser.parse(candidateData) else { continue }
            return Result(rows: rows, label: url.lastPathComponent)
        }
        return nil
    }
}

// MARK: - Fleet Drift writer

/// Mirrors `_write_fleet_drift` (Python line 8879).
struct FleetDriftWriter {

    let config: ReportConfig
    let currentRows: [CSVRow]
    let priorRows: [CSVRow]
    let priorLabel: String
    let workbook: Workbook

    // MARK: - Public API

    /// Write the "Fleet Drift" sheet to `workbook`.
    func writeFleetDrift() {
        let ws = workbook.addSheet("Fleet Drift")
        let ts = ISO8601DateFormatter().string(from: Date())
        var row = ws.writeSheetHeader(
            title: "Fleet Drift",
            subtitle: "Current CSV vs \(priorLabel) | Generated: \(ts)",
            ncols: 6
        )
        ws.setColumnWidth(0, 0, 34)
        ws.setColumnWidth(1, 5, 22)

        let staleThreshold = config.thresholds?.resolvedStaleDays ?? 30
        guard let serialColName = config.columns?.columnName(for: .serialNumber) else {
            ws.write("serial_number column not configured — Fleet Drift unavailable.",
                     row: row, col: 0, format: .cell)
            return
        }

        // Build serial → row dicts, uppercasing serials and deduplicating (first occurrence wins).
        let currentMap = buildSerialMap(rows: currentRows, serialCol: serialColName)
        let priorMap = buildSerialMap(rows: priorRows, serialCol: serialColName)

        let currentSerials = Set(currentMap.keys)
        let priorSerials = Set(priorMap.keys)

        // --- New Enrollments ---
        let newSerials = currentSerials.subtracting(priorSerials)
        let newRows = newSerials.sorted().compactMap { currentMap[$0] }
        row = writeSection(
            ws: ws, row: row,
            title: "New Enrollments",
            headers: ["Name", "Serial", "OS", "Last Check-in", "Department"],
            dataRows: newRows.map { makeEnrollmentCells($0) }
        )

        // --- Departed Devices ---
        let departedSerials = priorSerials.subtracting(currentSerials)
        let departedRows = departedSerials.sorted().compactMap { priorMap[$0] }
        row = writeSection(
            ws: ws, row: row,
            title: "Departed Devices",
            headers: ["Name", "Serial", "OS", "Last Check-in", "Department"],
            dataRows: departedRows.map { makeEnrollmentCells($0) }
        )

        // --- New Stale ---
        let commonSerials = currentSerials.intersection(priorSerials).sorted()
        let newStale = commonSerials.filter { serial in
            let curDays = daysSince(checkIn: currentMap[serial])
            let priorDays = daysSince(checkIn: priorMap[serial])
            return !isStale(days: priorDays, threshold: staleThreshold)
                && isStale(days: curDays, threshold: staleThreshold)
        }
        row = writeSection(
            ws: ws, row: row,
            title: "New Stale",
            headers: ["Name", "Serial", "Prior Days Stale", "Current Days Stale"],
            dataRows: newStale.compactMap { serial -> [String]? in
                guard let cur = currentMap[serial], let prior = priorMap[serial] else { return nil }
                return makeStaleChangeCells(cur: cur, prior: prior)
            }
        )

        // --- Recovered Stale ---
        let recoveredStale = commonSerials.filter { serial in
            let curDays = daysSince(checkIn: currentMap[serial])
            let priorDays = daysSince(checkIn: priorMap[serial])
            return isStale(days: priorDays, threshold: staleThreshold)
                && !isStale(days: curDays, threshold: staleThreshold)
        }
        row = writeSection(
            ws: ws, row: row,
            title: "Recovered Stale",
            headers: ["Name", "Serial", "Prior Days Stale", "Current Days Stale"],
            dataRows: recoveredStale.compactMap { serial -> [String]? in
                guard let cur = currentMap[serial], let prior = priorMap[serial] else { return nil }
                return makeStaleChangeCells(cur: cur, prior: prior)
            }
        )

        // --- OS Changed ---
        let osChanged = commonSerials.filter { serial in
            guard let cur = currentMap[serial], let prior = priorMap[serial] else { return false }
            let curOS = osValue(cur)
            let priorOS = osValue(prior)
            return !curOS.isEmpty && !priorOS.isEmpty && curOS != priorOS
        }
        row = writeSection(
            ws: ws, row: row,
            title: "OS Changed",
            headers: ["Name", "Serial", "Prior OS", "Current OS"],
            dataRows: osChanged.compactMap { serial -> [String]? in
                guard let cur = currentMap[serial], let prior = priorMap[serial] else { return nil }
                return [nameValue(cur), serial, osValue(prior), osValue(cur)]
            }
        )

        // --- Compliance Changed ---
        let complianceNote: String?
        let failColName = config.compliance?.failuresCountColumn
        if failColName == nil || failColName?.isEmpty == true {
            complianceNote = "failures_count_column not configured"
        } else {
            complianceNote = nil
        }

        let complianceChanged = commonSerials.filter { serial in
            guard let fc = failColName, !fc.isEmpty,
                  let cur = currentMap[serial], let prior = priorMap[serial] else { return false }
            let curN = Int(cur[fc]?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
            let priorN = Int(prior[fc]?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
            return curN >= 0 && priorN >= 0 && curN != priorN
        }
        row = writeSectionWithNote(
            ws: ws, row: row,
            title: "Compliance Changed",
            note: complianceNote,
            headers: ["Name", "Serial", "Prior Failures", "Current Failures", "Status"],
            dataRows: complianceChanged.compactMap { serial -> [String]? in
                guard let fc = failColName, !fc.isEmpty,
                      let cur = currentMap[serial], let prior = priorMap[serial] else { return nil }
                let curN = Int(cur[fc]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                let priorN = Int(prior[fc]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                let status: String
                if curN == 0 { status = "Recovered" }
                else if priorN == 0 { status = "Regressed" }
                else { status = "Changed" }
                return [nameValue(cur), serial, "\(priorN)", "\(curN)", status]
            }
        )
        _ = row
    }

    // MARK: - Private section writers

    @discardableResult
    private func writeSection(
        ws: Worksheet,
        row: Int,
        title: String,
        headers: [String],
        dataRows: [[String]]
    ) -> Int {
        return writeSectionWithNote(ws: ws, row: row, title: title, note: nil,
                                    headers: headers, dataRows: dataRows)
    }

    @discardableResult
    private func writeSectionWithNote(
        ws: Worksheet,
        row: Int,
        title: String,
        note: String?,
        headers: [String],
        dataRows: [[String]]
    ) -> Int {
        var r = row
        ws.write(title, row: r, col: 0, format: .header)
        if let note { ws.write(note, row: r, col: 1, format: .subtitle) }
        r += 1
        for (colIdx, header) in headers.enumerated() {
            ws.write(header, row: r, col: colIdx, format: .header)
        }
        r += 1
        if dataRows.isEmpty {
            ws.write("No changes", row: r, col: 0, format: .cell)
            r += 1
        } else {
            for cells in dataRows {
                for (colIdx, cell) in cells.enumerated() {
                    ws.write(cell, row: r, col: colIdx, format: .cell)
                }
                r += 1
            }
        }
        r += 1  // blank separator row
        return r
    }

    // MARK: - Private helpers

    private func buildSerialMap(rows: [CSVRow], serialCol: String) -> [String: CSVRow] {
        var map: [String: CSVRow] = [:]
        var dupCount = 0
        for row in rows {
            let serial = (row[serialCol] ?? "").uppercased().trimmingCharacters(in: .whitespaces)
            guard !serial.isEmpty else { continue }
            if map[serial] != nil { dupCount += 1; continue }
            map[serial] = row
        }
        if dupCount > 0 { print("[warn] \(dupCount) duplicate serials in CSV (first occurrence wins)") }
        return map
    }

    private func nameValue(_ row: CSVRow) -> String {
        guard let colName = config.columns?.columnName(for: .computerName) else { return "" }
        return row[colName] ?? ""
    }

    private func osValue(_ row: CSVRow) -> String {
        guard let colName = config.columns?.columnName(for: .operatingSystem) else { return "" }
        return row[colName] ?? ""
    }

    private func checkinValue(_ row: CSVRow) -> String {
        guard let colName = config.columns?.columnName(for: .lastCheckin) else { return "" }
        return row[colName] ?? ""
    }

    private func departmentValue(_ row: CSVRow) -> String {
        guard let colName = config.columns?.columnName(for: .department) else { return "" }
        return row[colName] ?? ""
    }

    private func daysSince(checkIn row: CSVRow?) -> Int? {
        guard let row else { return nil }
        let raw = checkinValue(row)
        guard !raw.isEmpty else { return nil }
        return DateParser().parse(raw).map { Int(Date().timeIntervalSince($0) / 86400) }
    }

    private func isStale(days: Int?, threshold: Int) -> Bool {
        guard let days else { return false }
        return days > threshold
    }

    private func makeEnrollmentCells(_ row: CSVRow) -> [String] {
        guard let serialColName = config.columns?.columnName(for: .serialNumber) else {
            return ["", "", "", "", ""]
        }
        return [
            nameValue(row),
            (row[serialColName] ?? "").uppercased(),
            osValue(row),
            checkinValue(row),
            departmentValue(row),
        ]
    }

    private func makeStaleChangeCells(cur: CSVRow, prior: CSVRow) -> [String]? {
        guard let serialColName = config.columns?.columnName(for: .serialNumber) else { return nil }
        let serial = (cur[serialColName] ?? "").uppercased()
        let priorDays = daysSince(checkIn: prior).map { "\($0)" } ?? ""
        let curDays = daysSince(checkIn: cur).map { "\($0)" } ?? ""
        return [nameValue(cur), serial, priorDays, curDays]
    }
}
