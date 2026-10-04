import Foundation

/// Best-effort read of `html.with_workbook` for the Customize screen and the Generate sheet.
/// Never throws: a missing workspace, absent file or unparseable config reads as off, since
/// neither screen owns that failure mode. Mirrors `ChartsConfigLoader`.
enum HTMLReportConfigLoader {
    static func withWorkbook(profile: String) -> Bool {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return false }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path),
              let html = (try? ConfigLoader.load(from: url))?.html
        else { return false }
        return html.writesWithWorkbook
    }
}

/// Scoped write-back for `html.with_workbook`, used by the Customize screen. Like
/// `ChartsConfigWriter` it is deliberately outside `ConfigService.managedTopLevelKeys`, and it
/// sets the one key on the `html:` block as the file holds it now, so `track_history`,
/// `history_file`, `section_limits` and any other key typed there stay.
enum HTMLReportConfigWriter {
    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            }
        }
    }

    /// Turning it off where the file never set it changes nothing, so Apply does not add an
    /// `html:` block to a config that has none.
    static func apply(withWorkbook: Bool, to root: inout YAMLCodec.YAMLMapping) {
        var html = root.value(for: "html")?.mapping ?? .init(entries: [])
        if !withWorkbook, html.value(for: "with_workbook") == nil { return }
        html.set("with_workbook", value: .scalar(.bool(withWorkbook)))
        root.set("html", value: .mapping(html))
    }

    @discardableResult
    static func save(
        withWorkbook: Bool, profile: String
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        return try ConfigService.saveBlock(key: "html", profile: profile) {
            apply(withWorkbook: withWorkbook, to: &$0)
        }
    }
}
