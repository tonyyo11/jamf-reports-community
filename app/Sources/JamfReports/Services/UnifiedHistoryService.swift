import Foundation

/// Builds a profile-scoped inventory of historical artifacts used by the GUI.
///
/// The index is intentionally read-only. It gathers known artifact families from the
/// workspace without assuming config has already been loaded or that every directory exists.
enum UnifiedHistoryService {

    enum ArtifactKind: String, CaseIterable, Sendable {
        case csvSnapshot = "CSV Snapshots"
        case jamfCLIJSON = "jamf-cli JSON"
        case htmlHistoryJSON = "HTML History JSON"
        case generatedReport = "Generated Reports"
        case automationLog = "Automation Logs"

        var icon: String {
            switch self {
            case .csvSnapshot: "tablecells"
            case .jamfCLIJSON: "curlybraces"
            case .htmlHistoryJSON: "chart.line.uptrend.xyaxis"
            case .generatedReport: "doc.text"
            case .automationLog: "terminal"
            }
        }
    }

    struct Artifact: Identifiable, Hashable, Sendable {
        var id: String { url.path }
        let kind: ArtifactKind
        let url: URL
        let family: String
        let modifiedAt: Date
        let byteCount: Int64

        var name: String { url.lastPathComponent }
    }

    struct KindSummary: Identifiable, Sendable {
        var id: ArtifactKind { kind }
        let kind: ArtifactKind
        let count: Int
        let byteCount: Int64
        let latest: Date?
    }

    struct ProfileIndex: Sendable {
        let profile: String
        let workspaceURL: URL
        let generatedAt: Date
        let artifacts: [Artifact]
        let summaries: [KindSummary]

        var totalByteCount: Int64 {
            artifacts.reduce(0) { $0 + $1.byteCount }
        }
    }

    static func index(profile: String) -> ProfileIndex? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }

        var artifacts: [Artifact] = []
        artifacts += csvSnapshots(in: workspace)
        artifacts += jamfCLIJSON(in: workspace)
        artifacts += htmlHistoryJSON(in: workspace)
        artifacts += generatedReports(in: workspace)
        artifacts += automationLogs(in: workspace)

        let deduped = Dictionary(artifacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted {
                if $0.modifiedAt == $1.modifiedAt { return $0.name < $1.name }
                return $0.modifiedAt > $1.modifiedAt
            }

        let summaries = ArtifactKind.allCases.map { kind in
            let items = deduped.filter { $0.kind == kind }
            return KindSummary(
                kind: kind,
                count: items.count,
                byteCount: items.reduce(0) { $0 + $1.byteCount },
                latest: items.map(\.modifiedAt).max()
            )
        }

        return ProfileIndex(
            profile: profile,
            workspaceURL: workspace,
            generatedAt: Date(),
            artifacts: deduped,
            summaries: summaries
        )
    }

    private static func csvSnapshots(in workspace: URL) -> [Artifact] {
        let directories = [
            workspace.appendingPathComponent("snapshots", isDirectory: true),
            workspace.appendingPathComponent("historical-csv", isDirectory: true),
            workspace.appendingPathComponent("csv-history", isDirectory: true),
            workspace.appendingPathComponent("csv-inbox", isDirectory: true),
            workspace.appendingPathComponent("automation/snapshots", isDirectory: true),
            workspace.appendingPathComponent("automation/csv-history", isDirectory: true),
        ]
        return directories.flatMap { files(in: $0, extensions: ["csv"]).map {
            artifact(kind: .csvSnapshot, url: $0, family: familyName(for: $0, root: workspace))
        } }
    }

    private static func jamfCLIJSON(in workspace: URL) -> [Artifact] {
        let directory = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        return files(in: directory, extensions: ["json"]).map {
            artifact(kind: .jamfCLIJSON, url: $0, family: familyName(for: $0, root: directory))
        }
    }

    private static func htmlHistoryJSON(in workspace: URL) -> [Artifact] {
        let homeHistory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jamf-report-history.json")
        var urls = [
            homeHistory,
            workspace.appendingPathComponent(".jamf-report-history.json"),
            workspace.appendingPathComponent("html-history.json"),
            workspace.appendingPathComponent("Generated Reports/html-history.json"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }

        let generatedReports = workspace.appendingPathComponent("Generated Reports", isDirectory: true)
        urls += files(in: generatedReports, extensions: ["json"])
            .filter { $0.lastPathComponent.lowercased().contains("history") }

        return urls.map {
            artifact(kind: .htmlHistoryJSON, url: $0, family: "html-history")
        }
    }

    private static func generatedReports(in workspace: URL) -> [Artifact] {
        let directory = workspace.appendingPathComponent("Generated Reports", isDirectory: true)
        return files(in: directory, extensions: ["xlsx", "html", "csv", "pptx"]).map {
            artifact(kind: .generatedReport, url: $0, family: $0.pathExtension.lowercased())
        }
    }

    private static func automationLogs(in workspace: URL) -> [Artifact] {
        let directory = workspace.appendingPathComponent("automation/logs", isDirectory: true)
        return files(in: directory, extensions: ["log"]).map {
            artifact(kind: .automationLog, url: $0, family: logFamily(for: $0))
        }
    }

    private static func files(in directory: URL, extensions allowedExtensions: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let safeRoot = directory.resolvingSymlinksInPath().path + "/"
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(safeRoot),
                  allowedExtensions.contains(resolved.pathExtension.lowercased()) else {
                return nil
            }
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? resolved : nil
        }
    }

    private static func artifact(kind: ArtifactKind, url: URL, family: String) -> Artifact {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Artifact(
            kind: kind,
            url: url,
            family: family,
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            byteCount: Int64(values?.fileSize ?? 0)
        )
    }

    private static func familyName(for url: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        if components.count > rootComponents.count {
            return components[rootComponents.count]
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func logFamily(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let dot = stem.lastIndex(of: ".") else { return stem }
        return String(stem[stem.index(after: dot)...])
    }
}
