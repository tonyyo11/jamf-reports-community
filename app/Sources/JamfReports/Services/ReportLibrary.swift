import Foundation

enum WorkspacePathGuard {
    static func root(for profile: String) -> URL? {
        guard let url = ProfileService.workspaceURL(for: profile) else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func validate(_ url: URL, under root: URL) -> URL? {
        validate(url, underAny: [root])
    }

    /// `url` resolved, when it sits in any one of `roots`.
    static func validate(_ url: URL, underAny roots: [URL]) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let inside = roots.contains { root in
            resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
        }
        return inside ? resolved : nil
    }
}

enum FileDisplay {
    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

struct ReportLibrary {
    private let fileManager = FileManager.default
    private let allowedExtensions: Set<String> = ["xlsx", "html", "pdf", "csv"]
    private let maxCentralDirectoryBytes: UInt64 = 5 * 1024 * 1024
    // Compiled once for all deviceCountFromSummary calls.
    private static let timestampRegex = try? NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2})"#)

    struct Stats: Sendable {
        let count: Int
        let totalBytes: Int64
        let archivedCount: Int
    }

    /// The folder reports are listed from and the folders a listed file may sit in.
    private struct Location {
        let reports: URL
        let roots: [URL]
        let archive: URL?
    }

    /// `WorkspacePaths.readableReportsDir` is the folder the writers use, so a report written
    /// to a shared `output.output_dir` is listed, and a refused folder falls back as writing
    /// does. Files are kept to the workspace and that folder: a symlink out of either is dropped.
    private func location(for profile: String) -> Location? {
        guard let workspace = WorkspacePathGuard.root(for: profile),
              let reports = WorkspacePaths.readableReportsDir(for: profile) else { return nil }
        let roots = [workspace, reports]
        guard let validated = WorkspacePathGuard.validate(reports, underAny: roots) else {
            return nil
        }
        return Location(
            reports: validated, roots: roots, archive: try? WorkspacePaths.archiveDir(for: profile)
        )
    }

    func list(profile: String) -> [Report] {
        guard let location = location(for: profile) else { return [] }
        let scheduled = scheduledFiles(profile: profile, roots: location.roots)
        return reportFileURLs(in: location)
            .compactMap {
                report(from: $0, profile: profile, roots: location.roots, scheduled: scheduled)
            }
            .sorted { $0.mtime > $1.mtime }
            .map(\.report)
    }

    func stats(profile: String) -> Stats {
        guard let location = location(for: profile) else {
            return Stats(count: 0, totalBytes: 0, archivedCount: 0)
        }
        let rows = reportFileURLs(in: location)
            .compactMap { metadata(for: $0, roots: location.roots) }
        let archiveRoot = location.archive
            ?? location.reports.appendingPathComponent("archive", isDirectory: true)
        let archivePath = archiveRoot.path + "/"
        return Stats(
            count: rows.count,
            totalBytes: rows.reduce(Int64(0)) { $0 + $1.size },
            archivedCount: rows.filter { $0.url.path.hasPrefix(archivePath) }.count
        )
    }

    func url(profile: String, reportName: String) -> URL? {
        guard let location = location(for: profile) else { return nil }
        return reportFileURLs(in: location)
            .compactMap { metadata(for: $0, roots: location.roots) }
            .filter { $0.url.lastPathComponent == reportName }
            .sorted { $0.mtime > $1.mtime }
            .first?
            .url
    }

    private func reportFileURLs(in location: Location) -> [URL] {
        var urls = immediateReportFiles(in: location.reports, roots: location.roots)
        let archive = location.archive
            ?? location.reports.appendingPathComponent("archive", isDirectory: true)
        if let validatedArchive = WorkspacePathGuard.validate(archive, underAny: location.roots) {
            urls.append(contentsOf: recursiveReportFiles(
                in: validatedArchive, roots: location.roots))
        }
        return urls
    }

    private func immediateReportFiles(in directory: URL, roots: [URL]) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { candidate in
            guard allowedExtensions.contains(candidate.pathExtension.lowercased()),
                  let validated = WorkspacePathGuard.validate(candidate, underAny: roots),
                  isReadableFile(validated) else {
                return nil
            }
            return validated
        }
    }

    private func recursiveReportFiles(in directory: URL, roots: [URL]) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let candidate as URL in enumerator {
            guard allowedExtensions.contains(candidate.pathExtension.lowercased()),
                  let validated = WorkspacePathGuard.validate(candidate, underAny: roots),
                  isReadableFile(validated) else {
                continue
            }
            urls.append(validated)
        }
        return urls
    }

    private func report(
        from url: URL,
        profile: String,
        roots: [URL],
        scheduled: [String: String]
    ) -> (report: Report, mtime: Date)? {
        guard let metadata = metadata(for: url, roots: roots) else { return nil }
        let name = url.lastPathComponent
        let report = Report(
            name: name,
            size: FileDisplay.size(metadata.size),
            date: FileDisplay.date(metadata.mtime),
            source: Self.sourceLabel(forFilename: name, schedule: scheduled[name]),
            sheets: url.pathExtension.lowercased() == "xlsx" ? worksheetCount(in: url) : 0,
            devices: deviceCount(from: url, profile: profile, modified: metadata.mtime)
        )
        return (report, metadata.mtime)
    }

    private func metadata(for url: URL, roots: [URL]) -> (url: URL, size: Int64, mtime: Date)? {
        guard let validated = WorkspacePathGuard.validate(url, underAny: roots),
              isReadableFile(validated),
              let values = try? validated.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
              ),
              let size = values.fileSize,
              let mtime = values.contentModificationDate else {
            return nil
        }
        return (validated, Int64(size), mtime)
    }

    private func isReadableFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    /// The Type column: what the file is, then the schedule that wrote it when `schedule` is
    /// known. A file name cannot say which schedule (or whether any) produced it, so the
    /// name alone only ever gives the kind.
    static func sourceLabel(forFilename filename: String, schedule: String?) -> String {
        let kind = kindLabel(forFilename: filename)
        guard let schedule, !schedule.isEmpty else { return kind }
        return "\(kind) \u{00B7} \(schedule)"
    }

    /// What a file is, from the names the writers give (`ExportNaming`) and its extension.
    static func kindLabel(forFilename filename: String) -> String {
        let lowered = filename.lowercased()
        let exports: [(prefix: String, label: String)] = [
            ("period-report-", "Period report"),
            ("patch-compliance-", "Patch compliance CSV"),
            ("audit-findings-", "Audit findings CSV"),
            ("outreach-stale-devices-", "Offline outreach CSV"),
            ("devices-", "Devices CSV"),
            ("school-report_", "Jamf School workbook"),
        ]
        if let match = exports.first(where: { lowered.hasPrefix($0.prefix) }) {
            return match.label
        }
        switch URL(fileURLWithPath: lowered).pathExtension {
        case "xlsx": return "Workbook"
        case "html": return "HTML report"
        case "pdf": return "PDF report"
        case "csv":
            let isInventory = lowered.hasPrefix("inventory_")
                || lowered.hasPrefix("automation_inventory_")
            return isInventory ? "Inventory CSV" : "CSV export"
        default: return "Report file"
        }
    }

    /// File name to the schedule that wrote it, for the files a schedule's status file names.
    /// The status file holds only the schedule's latest run, and a run started from the app
    /// leaves none, so most files have no entry and show their kind alone.
    private func scheduledFiles(profile: String, roots: [URL]) -> [String: String] {
        guard let logs = try? WorkspacePaths.runHistoryDir(for: profile) else { return [:] }
        let automation = logs.deletingLastPathComponent()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: automation, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        let statusFiles = entries
            .filter { $0.lastPathComponent.hasSuffix("_status.json") }
            .compactMap { WorkspacePathGuard.validate($0, underAny: roots) }
        return Self.scheduledFiles(statusFiles: statusFiles)
    }

    /// Testable core of `scheduledFiles(profile:roots:)`: reads each status file's label and
    /// the report paths `ScheduledRunRecorder` wrote into it.
    static func scheduledFiles(statusFiles: [URL]) -> [String: String] {
        var named: [String: String] = [:]
        for url in statusFiles {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let label = json["label"] as? String, !label.isEmpty else { continue }
            let schedule = RunHistoryService.humanName(from: label)
            for key in ["xlsx_report_path", "html_report_path", "inventory_csv_path"] {
                guard let path = json[key] as? String, !path.isEmpty else { continue }
                named[URL(fileURLWithPath: path).lastPathComponent] = schedule
            }
        }
        return named
    }

    private func worksheetCount(in url: URL) -> Int {
        guard hasZipMagic(url),
              let centralDirectory = readCentralDirectory(from: url) else {
            return 0
        }
        return countWorksheetEntries(in: centralDirectory)
    }

    /// The device count from the daily summary of the date in the file name, for a workbook.
    /// Nil when there is no such summary, the name carries no date, `totalDevices` is
    /// non-numeric, or the summary has been rewritten since the workbook was (see
    /// `deviceCount(forReportURL:summariesDir:reportModified:)`). Other formats are nil.
    private func deviceCount(from url: URL, profile: String, modified: Date) -> Int? {
        guard url.pathExtension.lowercased() == "xlsx",
              let summariesDir = try? WorkspacePaths.summariesDir(for: profile) else {
            return nil
        }
        return deviceCount(forReportURL: url, summariesDir: summariesDir, reportModified: modified)
    }

    /// How long after a workbook its day's summary may be written and still count as the
    /// summary the workbook was generated beside: `generate` can emit the summary itself.
    static let summaryGrace: TimeInterval = 300

    /// Testable core: looks up the device count given the report URL and summaries directory.
    ///
    /// Extracts the `YYYY-MM-DD` date from `reportURL`'s filename, finds the matching
    /// `summary_<date>.json` in `summariesDir`, and returns `totalDevices`.
    /// Returns nil when the filename has no date, the summary is absent, or
    /// `totalDevices` is missing / non-numeric.
    ///
    /// The summary is one file per day and a later collect the same day rewrites it, so its
    /// count describes the workbook only while it is unchanged. With `reportModified`, a
    /// summary written more than `summaryGrace` after the workbook gives nil: the count
    /// would otherwise move under a file that did not change.
    func deviceCount(
        forReportURL reportURL: URL, summariesDir: URL, reportModified: Date? = nil
    ) -> Int? {
        let filename = reportURL.lastPathComponent
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent

        guard let regex = Self.timestampRegex,
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let range = Range(match.range(at: 1), in: stem) else {
            return nil
        }

        let dateString = String(stem[range])
        let summaryURL = summariesDir.appendingPathComponent("summary_\(dateString).json")

        guard FileManager.default.fileExists(atPath: summaryURL.path),
              let data = try? Data(contentsOf: summaryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let reportModified {
            let summaryModified = try? summaryURL.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate
            // An unreadable mtime proves nothing, so it gives no count.
            guard let summaryModified,
                  summaryModified <= reportModified.addingTimeInterval(Self.summaryGrace) else {
                return nil
            }
        }

        // JSON numbers may deserialize as Int or Double depending on the serializer. A Double
        // outside Int's range gives no count; `Int(_:)` would trap.
        return (json["totalDevices"] as? Int)
            ?? (json["totalDevices"] as? Double).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    private func hasZipMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4)) ?? Data()
        return data == Data([0x50, 0x4B, 0x03, 0x04])
    }

    private func readCentralDirectory(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else {
            return nil
        }
        defer { try? handle.close() }

        let tailLength = min(size, UInt64(65_557))
        guard tailLength >= 22 else { return nil }
        try? handle.seek(toOffset: size - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)),
              let eocdOffset = findEndOfCentralDirectory(in: tail),
              let centralSize = tail.littleEndianUInt32(at: eocdOffset + 12),
              let centralOffset = tail.littleEndianUInt32(at: eocdOffset + 16) else {
            return nil
        }

        let directorySize = UInt64(centralSize)
        let directoryOffset = UInt64(centralOffset)
        guard directorySize > 0,
              directorySize <= maxCentralDirectoryBytes,
              directoryOffset + directorySize <= size else {
            return nil
        }

        try? handle.seek(toOffset: directoryOffset)
        return try? handle.read(upToCount: Int(directorySize))
    }

    private func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        for index in stride(from: bytes.count - 22, through: 0, by: -1) {
            if Array(bytes[index..<index + 4]) == signature {
                return index
            }
        }
        return nil
    }

    private func countWorksheetEntries(in centralDirectory: Data) -> Int {
        var count = 0
        var offset = 0
        while offset + 46 <= centralDirectory.count {
            guard centralDirectory.matchesZipCentralHeader(at: offset),
                  let nameLength = centralDirectory.littleEndianUInt16(at: offset + 28),
                  let extraLength = centralDirectory.littleEndianUInt16(at: offset + 30),
                  let commentLength = centralDirectory.littleEndianUInt16(at: offset + 32) else {
                break
            }

            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= centralDirectory.count else { break }
            if let name = String(data: centralDirectory[nameStart..<nameEnd], encoding: .utf8) {
                let lower = name.lowercased()
                if lower.hasPrefix("xl/worksheets/sheet") && lower.hasSuffix(".xml") {
                    count += 1
                }
            }

            offset = nameEnd + Int(extraLength) + Int(commentLength)
        }
        return count
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard offset + 1 < count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset + 3 < count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func matchesZipCentralHeader(at offset: Int) -> Bool {
        guard offset + 3 < count else { return false }
        return self[offset] == 0x50
            && self[offset + 1] == 0x4B
            && self[offset + 2] == 0x01
            && self[offset + 3] == 0x02
    }
}
