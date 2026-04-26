import Foundation

struct SnapshotFamily: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let glob: String
    let snapshotCount: Int
    let latestDate: Date?
    let totalBytes: Int64
    let usedBy: String
}

struct SnapshotArchiveService {
    private let fileManager = FileManager.default

    private let knownUses: [String: String] = [
        "computers": "Trends · Compliance",
        "mobile": "Mobile Inventory",
        "compliance": "Future automation",
        "patching": "Archive only",
    ]

    func families(profile: String) -> [SnapshotFamily] {
        guard let root = WorkspacePathGuard.root(for: profile) else { return [] }
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        guard let validatedSnapshots = WorkspacePathGuard.validate(snapshots, under: root),
              let entries = try? fileManager.contentsOfDirectory(
                at: validatedSnapshots,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return entries.compactMap { candidate in
            guard let familyURL = WorkspacePathGuard.validate(candidate, under: root),
                  (try? familyURL.resourceValues(
                    forKeys: [.isDirectoryKey]
                  ))?.isDirectory == true else {
                return nil
            }
            return family(from: familyURL, root: root)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func family(from directory: URL, root: URL) -> SnapshotFamily {
        let files = csvFiles(in: directory, root: root)
        let name = directory.lastPathComponent
        let latest = files.compactMap(\.mtime).max()
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        return SnapshotFamily(
            name: name,
            glob: inferredGlob(from: files.map(\.url), fallback: name),
            snapshotCount: files.count,
            latestDate: latest,
            totalBytes: bytes,
            usedBy: knownUses[name.lowercased()] ?? ""
        )
    }

    private func csvFiles(in directory: URL, root: URL) -> [(url: URL, size: Int64, mtime: Date?)] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [(url: URL, size: Int64, mtime: Date?)] = []
        for case let candidate as URL in enumerator {
            guard candidate.pathExtension.lowercased() == "csv",
                  let validated = WorkspacePathGuard.validate(candidate, under: root),
                  let values = try? validated.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            files.append((validated, Int64(size), values.contentModificationDate))
        }
        return files
    }

    private func inferredGlob(from urls: [URL], fallback: String) -> String {
        let ignored: Set<String> = [
            "csv",
            "export",
            "jamf",
            "report",
            "snapshot",
            "snapshots",
            "only",
            "plus",
            "cli",
        ]
        var counts: [String: Int] = [:]
        for url in urls {
            let tokens = url.deletingPathExtension().lastPathComponent
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { token in
                    !ignored.contains(token)
                        && token.count > 2
                        && token.range(of: #"^\d{4,8}$"#, options: .regularExpression) == nil
                        && token.range(of: #"^\d{6}$"#, options: .regularExpression) == nil
                }
            for token in tokens {
                counts[token, default: 0] += 1
            }
        }

        let token = counts.sorted {
            if $0.value == $1.value { return $0.key.count > $1.key.count }
            return $0.value > $1.value
        }.first?.key ?? fallback.lowercased()
        return "*\(token)*.csv"
    }
}
