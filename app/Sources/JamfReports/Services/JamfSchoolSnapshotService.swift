import Foundation

struct JamfSchoolResourceCount: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case overview
        case devices
        case apps
        case profiles
        case classes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .devices: "Devices"
            case .apps: "Apps"
            case .profiles: "Profiles"
            case .classes: "Classes"
            }
        }

        var cacheNames: [String] {
            switch self {
            case .overview: ["school-overview", "school_overview"]
            case .devices: ["school-devices", "school_devices"]
            case .apps: ["school-apps", "school_apps"]
            case .profiles: ["school-profiles", "school_profiles"]
            case .classes: ["school-classes", "school_classes"]
            }
        }
    }

    var id: String { "\(kind.rawValue)-\(source.path)" }
    let kind: Kind
    let count: Int
    let capturedAt: Date
    let source: URL
}

struct JamfSchoolSnapshotSummary: Sendable {
    let profile: String
    let cacheDirectories: [URL]
    let latestCounts: [JamfSchoolResourceCount]
    let history: [JamfSchoolResourceCount]

    var hasData: Bool { !history.isEmpty }

    func latestCount(for kind: JamfSchoolResourceCount.Kind) -> JamfSchoolResourceCount? {
        latestCounts.first { $0.kind == kind }
    }
}

enum JamfSchoolSnapshotService {
    static func load(profile: String) -> JamfSchoolSnapshotSummary {
        let directories = candidateCacheDirectories(profile: profile)
        let snapshots = discoverSnapshots(in: directories)
        let latest = JamfSchoolResourceCount.Kind.allCases.compactMap { kind in
            snapshots
                .filter { $0.kind == kind }
                .max { $0.capturedAt < $1.capturedAt }
        }

        return JamfSchoolSnapshotSummary(
            profile: profile,
            cacheDirectories: directories,
            latestCounts: latest.sorted { $0.kind.rawValue < $1.kind.rawValue },
            history: snapshots.sorted { $0.capturedAt > $1.capturedAt }
        )
    }

    static func candidateCacheDirectories(profile: String) -> [URL] {
        var candidates: [URL] = []
        if let workspace = ProfileService.workspaceURL(for: profile) {
            candidates.append(workspace.appendingPathComponent("school-cli-data", isDirectory: true))
            candidates.append(workspace.appendingPathComponent("jamf-cli-data", isDirectory: true))
            candidates.append(workspace.appendingPathComponent("jamf-cli-data/school", isDirectory: true))
            candidates.append(workspace.appendingPathComponent("school", isDirectory: true))
            candidates.append(workspace.appendingPathComponent("school/jamf-cli-data", isDirectory: true))
            candidates.append(contentsOf: configuredSchoolDataDirs(in: workspace))
            candidates.append(contentsOf: cliDataLikeDirectories(in: workspace))
        }
        return uniqueExistingDirectories(candidates)
    }

    private static func discoverSnapshots(in directories: [URL]) -> [JamfSchoolResourceCount] {
        var snapshots: [JamfSchoolResourceCount] = []
        for directory in directories {
            for kind in JamfSchoolResourceCount.Kind.allCases {
                for file in jsonFiles(for: kind, in: directory) {
                    guard let count = countJSONItems(at: file) else { continue }
                    snapshots.append(.init(
                        kind: kind,
                        count: count,
                        capturedAt: capturedDate(for: file),
                        source: file
                    ))
                }
            }
        }
        return snapshots
    }

    private static func jsonFiles(for kind: JamfSchoolResourceCount.Kind, in directory: URL) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for name in kind.cacheNames {
            let resourceDirectory = directory.appendingPathComponent(name, isDirectory: true)
            if let contents = try? fm.contentsOfDirectory(
                at: resourceDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                files.append(contentsOf: contents.filter { isJSONSnapshot($0) })
            }

            if let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                files.append(contentsOf: contents.filter {
                    isJSONSnapshot($0) && $0.deletingPathExtension().lastPathComponent.hasPrefix("\(name)_")
                })
            }
        }
        return files
    }

    private static func countJSONItems(at url: URL) -> Int? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return countItems(in: object)
    }

    private static func countItems(in object: Any) -> Int {
        if let array = object as? [Any] {
            return array.count
        }
        guard let dictionary = object as? [String: Any] else {
            return 1
        }

        let listKeys = [
            "items", "results", "data", "devices", "apps", "profiles", "classes",
            "deviceGroups", "device_groups", "users", "groups", "locations",
        ]
        for key in listKeys {
            if let array = dictionary[key] as? [Any] {
                return array.count
            }
        }

        for key in ["total", "count", "deviceCount", "device_count", "appCount", "profileCount", "classCount"] {
            if let count = dictionary[key] as? Int {
                return count
            }
            if let number = dictionary[key] as? NSNumber {
                return number.intValue
            }
            if let text = dictionary[key] as? String, let count = Int(text) {
                return count
            }
        }

        return dictionary.isEmpty ? 0 : dictionary.count
    }

    private static func configuredSchoolDataDirs(in workspace: URL) -> [URL] {
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }

        var inSchoolBlock = false
        var directories: [URL] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inSchoolBlock = trimmed == "school_cli:"
                continue
            }
            guard inSchoolBlock, trimmed.hasPrefix("data_dir:") else { continue }
            let rawValue = trimmed
                .dropFirst("data_dir:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !rawValue.isEmpty else { continue }
            let url = URL(fileURLWithPath: rawValue, relativeTo: workspace).standardizedFileURL
            directories.append(url)
        }
        return directories
    }

    private static func cliDataLikeDirectories(in workspace: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                return false
            }
            let name = url.lastPathComponent.lowercased()
            return name.contains("cli-data") || name.contains("jamf-cli-data")
        }
    }

    private static func isJSONSnapshot(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "json" else { return false }
        guard !url.lastPathComponent.contains(".partial") else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func capturedDate(for url: URL) -> Date {
        if let date = dateFromFilename(url.deletingPathExtension().lastPathComponent) {
            return date
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }

    private static func dateFromFilename(_ name: String) -> Date? {
        let patterns = [
            #"(\d{4}-\d{2}-\d{2}T\d{6})"#,
            #"(\d{4}-\d{2}-\d{2}_\d{6})"#,
            #"(\d{4}-\d{2}-\d{2})"#,
        ]
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                let range = Range(match.range(at: 1), in: name)
            else {
                continue
            }
            let value = String(name[range])
            if let date = parseDate(value) {
                return date
            }
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HHmmss", "yyyy-MM-dd_HHmmss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func uniqueExistingDirectories(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique: [URL] = []
        for url in urls {
            let normalized = url.standardizedFileURL
            guard
                seen.insert(normalized.path).inserted,
                (try? normalized.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else {
                continue
            }
            unique.append(normalized)
        }
        return unique.sorted { $0.path < $1.path }
    }
}
