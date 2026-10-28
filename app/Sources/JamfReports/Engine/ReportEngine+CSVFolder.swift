import Foundation

/// The CSV folder: one CSV per workbook tab in a folder beside the workbook. It serializes the
/// cells the tabs' writers already put on the `Workbook`, so no tab has a second row builder, and
/// `sheets.only/skip/order` have already been applied to the tabs it reads.
extension Worksheet {
    /// The tab's rows as CSV text, padded to the widest row. Cell text was guarded when it was
    /// written (`CellValue.safe`), so only RFC 4180 quoting is applied here, never a second guard.
    /// Nil for a tab with no cells (the Charts tab holds images only).
    func csvText() -> String? {
        let cells = dedupedCells
        guard !cells.isEmpty else { return nil }
        let width = (cells.map(\.col).max() ?? 0) + 1
        var rows: [Int: [Int: String]] = [:]
        for cell in cells {
            rows[cell.row, default: [:]][cell.col] = Self.csvCellText(cell.value, cell.format)
        }
        let last = rows.keys.max() ?? 0
        return (0...last).map { index in
            let row = rows[index] ?? [:]
            return (0..<width).map { StaleDeviceService.csvQuoted(row[$0] ?? "") }
                .joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    /// What the cell shows in Excel: a percentage format displays the fraction as `83.3%`.
    private static func csvCellText(_ value: CellValue, _ format: CellFormat?) -> String {
        switch value {
        case .blank: return ""
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number):
            switch format {
            case .pct, .pctGreen, .pctYellow, .pctRed: return String(format: "%.1f%%", number * 100)
            default: return number == number.rounded() && abs(number) < 1e15
                ? String(Int(number)) : String(number)
            }
        }
    }
}

extension Workbook {
    enum CSVFolderError: Error, LocalizedError {
        case linkedFolder(String)
        case duplicateFileName(String)

        var errorDescription: String? {
            switch self {
            case .linkedFolder(let name):
                return "\(name) is a symbolic link, so nothing was written there"
            case .duplicateFileName(let name):
                return "two tabs would both be written as \(name)"
            }
        }
    }

    /// Writes one `<tab name>.csv` per tab into `folder`, replacing a folder of that name as a
    /// whole: the files are staged in a hidden sibling first, so a failure leaves the old folder
    /// and no half-written one. Returns how many files were written; a workbook whose tabs
    /// hold no cells writes nothing and leaves `folder` alone.
    @discardableResult
    func writeCSVFolder(to folder: URL) throws -> Int {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // A link planted at the folder's name would be replaced, not followed, but a person
        // who put it there did not expect either.
        if let type = (try? fm.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            throw CSVFolderError.linkedFolder(folder.lastPathComponent)
        }
        let staging = parent.appendingPathComponent(
            ".\(folder.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var installed = false
        defer { if !installed { try? fm.removeItem(at: staging) } }

        var written = 0
        for sheet in worksheets {
            guard let text = sheet.csvText() else { continue }
            let name = ProfileName.pathComponent(sheet.name) + ".csv"
            let target = staging.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else {
                throw CSVFolderError.duplicateFileName(name)
            }
            try Data(text.utf8).write(to: target, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            written += 1
        }
        guard written > 0 else { return 0 }

        if fm.fileExists(atPath: folder.path) {
            _ = try fm.replaceItemAt(folder, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: folder)
        }
        installed = true
        return written
    }
}

extension ReportEngine {
    /// Marks the `[warn]` line for a CSV folder that was not written.
    static let csvFolderFailureMarker = "[warn] CSV folder not written: "

    /// The CSV folder's place for a workbook: the workbook's own name with `_csv`, so the pair
    /// share a stem (`report_prod_2026-10-04_091500.xlsx` and `report_prod_2026-10-04_091500_csv`),
    /// which is also how run rotation finds the folder to move with its workbook.
    static func csvFolderURL(besideWorkbook workbookURL: URL) -> URL {
        let stem = workbookURL.deletingPathExtension().lastPathComponent
        return workbookURL.deletingLastPathComponent()
            .appendingPathComponent(stem + "_csv", isDirectory: true)
    }

    /// Writes the CSV folder beside `workbookURL` when the caller asked (`requested`: the
    /// Generate sheet's format, the CLI flag) or `output.csv_folder` is on, from the tabs
    /// `workbook` holds. The workbook is already on disk when this runs, so a failure is one
    /// `[warn]` line, never an error and never `[partial]` (a retry cannot help), as for the
    /// companion HTML. Returns the folder written.
    @discardableResult
    static func writeCSVFolder(
        of workbook: Workbook, besideWorkbook workbookURL: URL, requested: Bool,
        config: ReportConfig, onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> URL? {
        guard requested || config.output?.writesCSVFolder == true else { return nil }
        let folder = csvFolderURL(besideWorkbook: workbookURL)
        do {
            let count = try workbook.writeCSVFolder(to: folder)
            guard count > 0 else {
                onLine?(.init(timestamp: Date(), level: .warn,
                              text: csvFolderFailureMarker + "no tab holds any rows"))
                return nil
            }
            onLine?(.init(timestamp: Date(), level: .ok,
                          text: "[ok] CSV folder written: \(folder.lastPathComponent) "
                              + "(\(count) file\(count == 1 ? "" : "s"))"))
            return folder
        } catch {
            let reason = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            let message = csvFolderFailureMarker + reason
            AppLogger.report.warning("\(message, privacy: .private)")
            if let onLine {
                onLine(.init(timestamp: Date(), level: .warn, text: message))
            } else {
                print(message)
            }
            return nil
        }
    }
}
