import Foundation

/// What a generate run produced besides the workbook it wrote.
struct GeneratedReport: Sendable {
    let failures: [SheetFailure]
    /// The CSV folder written beside the workbook, nil when none was.
    let csvFolder: URL?
}

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
        case stagingFolderNotMade(String)

        var errorDescription: String? {
            switch self {
            case .stagingFolderNotMade(let name): return "could not make a staging folder for \(name)"
            }
        }
    }

    /// Writes one `<tab name>.csv` per tab into `folder`, replacing a folder of that name as a
    /// whole (`AtomicInstall`): the files are staged in a hidden sibling first, so a failure
    /// leaves the old folder and no half-written one, and a link at the folder's name is
    /// replaced, never written through. Returns how many files were written; a workbook whose
    /// tabs hold no cells writes nothing and leaves `folder` alone. Two tabs whose names differ
    /// only by case or accents get `_2`, `_3`, ... as tab names do, since the volume would
    /// otherwise make them one file.
    @discardableResult
    func writeCSVFolder(to folder: URL, now: Date = Date()) throws -> Int {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        AtomicInstall.removeStaleStaging(in: parent, now: now)
        let staging = parent.appendingPathComponent(
            ".\(folder.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var installed = false
        defer { if !installed { AtomicInstall.discard(staging) } }

        // Files are created through the staging folder's descriptor, so swapping the folder for
        // a link after it was made cannot send them elsewhere.
        let directory = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        var written = 0
        var used: Set<String> = []
        for sheet in worksheets {
            guard let text = sheet.csvText() else { continue }
            let name = Self.uniqueFileName(ProfileName.pathComponent(sheet.name), used: &used)
            try Self.createFile(Data(text.utf8), named: name, inFolder: directory)
            written += 1
        }
        guard written > 0 else { return 0 }
        // The folder installed is the one written to.
        var held = stat(), named = stat()
        guard fstat(directory, &held) == 0, lstat(staging.path, &named) == 0,
              held.st_ino == named.st_ino, held.st_dev == named.st_dev else {
            throw CSVFolderError.stagingFolderNotMade(folder.lastPathComponent)
        }

        try AtomicInstall.install(staging, at: folder)
        installed = true
        return written
    }

    /// Creates `name` (0600) in the folder open as `directory`, exclusively and never through a
    /// link, and writes `data` to that one descriptor.
    private static func createFile(_ data: Data, named name: String, inFolder directory: Int32) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    /// `<base>.csv`, or `<base>_2.csv` and on when the volume would read the name as one
    /// already used (`ProfileName.folderKey`: case and accents folded).
    private static func uniqueFileName(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while !used.insert(ProfileName.folderKey(candidate + ".csv")).inserted {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        return candidate + ".csv"
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
            .appendingPathComponent(stem + csvFolderSuffix, isDirectory: true)
    }

    /// What a CSV folder's name ends in. The one test for "is this a CSV folder's name": never
    /// the extension, since a profile such as `acme.example.com` puts a dot in the name.
    static let csvFolderSuffix = "_csv"

    static func isCSVFolderName(_ name: String) -> Bool { name.hasSuffix(csvFolderSuffix) }

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
