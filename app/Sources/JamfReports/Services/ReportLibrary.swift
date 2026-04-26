import Foundation

enum WorkspacePathGuard {
    static func root(for profile: String) -> URL? {
        guard let url = ProfileService.workspaceURL(for: profile) else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func validate(_ url: URL, under root: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return resolved
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
    private let allowedExtensions: Set<String> = ["xlsx", "html", "csv"]
    private let maxCentralDirectoryBytes: UInt64 = 5 * 1024 * 1024

    struct Stats: Sendable {
        let count: Int
        let totalBytes: Int64
        let archivedCount: Int
    }

    func list(profile: String) -> [Report] {
        guard let root = WorkspacePathGuard.root(for: profile) else { return [] }
        let reportsRoot = root.appendingPathComponent("Generated Reports", isDirectory: true)
        guard let validatedReportsRoot = WorkspacePathGuard.validate(
            reportsRoot,
            under: root
        ) else {
            return []
        }

        return reportFileURLs(in: validatedReportsRoot, root: root)
            .compactMap { report(from: $0, profile: profile, root: root) }
            .sorted { $0.mtime > $1.mtime }
            .map(\.report)
    }

    func stats(profile: String) -> Stats {
        guard let root = WorkspacePathGuard.root(for: profile) else {
            return Stats(count: 0, totalBytes: 0, archivedCount: 0)
        }
        let reportsRoot = root.appendingPathComponent("Generated Reports", isDirectory: true)
        guard let validatedReportsRoot = WorkspacePathGuard.validate(
            reportsRoot,
            under: root
        ) else {
            return Stats(count: 0, totalBytes: 0, archivedCount: 0)
        }

        let rows = reportFileURLs(in: validatedReportsRoot, root: root)
            .compactMap { metadata(for: $0, root: root) }
        let archivePath = validatedReportsRoot
            .appendingPathComponent("archive", isDirectory: true)
            .path + "/"
        return Stats(
            count: rows.count,
            totalBytes: rows.reduce(Int64(0)) { $0 + $1.size },
            archivedCount: rows.filter { $0.url.path.hasPrefix(archivePath) }.count
        )
    }

    func url(profile: String, reportName: String) -> URL? {
        guard let root = WorkspacePathGuard.root(for: profile) else { return nil }
        let reportsRoot = root.appendingPathComponent("Generated Reports", isDirectory: true)
        guard let validatedReportsRoot = WorkspacePathGuard.validate(
            reportsRoot,
            under: root
        ) else {
            return nil
        }

        return reportFileURLs(in: validatedReportsRoot, root: root)
            .compactMap { metadata(for: $0, root: root) }
            .filter { $0.url.lastPathComponent == reportName }
            .sorted { $0.mtime > $1.mtime }
            .first?
            .url
    }

    private func reportFileURLs(in reportsRoot: URL, root: URL) -> [URL] {
        var urls: [URL] = []
        urls.append(contentsOf: immediateReportFiles(in: reportsRoot, root: root))

        let archive = reportsRoot.appendingPathComponent("archive", isDirectory: true)
        if let validatedArchive = WorkspacePathGuard.validate(archive, under: root) {
            urls.append(contentsOf: recursiveReportFiles(in: validatedArchive, root: root))
        }

        return urls
    }

    private func immediateReportFiles(in directory: URL, root: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { candidate in
            guard allowedExtensions.contains(candidate.pathExtension.lowercased()),
                  let validated = WorkspacePathGuard.validate(candidate, under: root),
                  isReadableFile(validated) else {
                return nil
            }
            return validated
        }
    }

    private func recursiveReportFiles(in directory: URL, root: URL) -> [URL] {
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
                  let validated = WorkspacePathGuard.validate(candidate, under: root),
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
        root: URL
    ) -> (report: Report, mtime: Date)? {
        guard let metadata = metadata(for: url, root: root) else { return nil }
        let name = url.lastPathComponent
        let report = Report(
            name: name,
            size: FileDisplay.size(metadata.size),
            date: FileDisplay.date(metadata.mtime),
            source: inferredSource(from: name, profile: profile),
            sheets: url.pathExtension.lowercased() == "xlsx" ? worksheetCount(in: url) : 0,
            devices: 0
        )
        return (report, metadata.mtime)
    }

    private func metadata(for url: URL, root: URL) -> (url: URL, size: Int64, mtime: Date)? {
        guard let validated = WorkspacePathGuard.validate(url, under: root),
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

    private func inferredSource(from filename: String, profile: String) -> String {
        let stem = stripTimestamp(
            URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        )
        let lowered = stem.lowercased()

        if lowered.contains("jamf_report") { return "Weekly Executive" }
        if lowered.contains("compliance") { return "Monthly Compliance" }
        if lowered.contains("mobile") { return "Mobile Inventory" }
        if lowered.contains("school_report") || lowered.contains("school") { return "Jamf School" }
        if lowered.contains("inventory") { return "Inventory Export" }

        var label = stem
        for token in profileTokens(profile) {
            label = label.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
        }
        label = label.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Manual Run" : titleCase(label)
    }

    private func profileTokens(_ profile: String) -> [String] {
        let normalized = profile.replacingOccurrences(of: "-", with: "_")
        return [profile, normalized]
    }

    private func stripTimestamp(_ stem: String) -> String {
        let pattern = #"[_-]\d{4}-\d{2}-\d{2}(?:[_T]\d{4,6})?$"#
        return stem.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private func titleCase(_ value: String) -> String {
        value
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private func worksheetCount(in url: URL) -> Int {
        guard hasZipMagic(url),
              let centralDirectory = readCentralDirectory(from: url) else {
            return 0
        }
        return countWorksheetEntries(in: centralDirectory)
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
