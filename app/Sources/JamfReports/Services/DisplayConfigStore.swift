import Foundation

/// Best-effort read of `display.percent_decimals` for the screens. Never throws: a missing
/// workspace, absent file or config that does not decode reads as one decimal.
enum DisplayConfigLoader {
    static func percentFormat(profile: String) -> PercentFormat {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return .standard }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path),
              let config = try? ConfigLoader.load(from: url)
        else { return .standard }
        return config.percentFormat
    }
}

/// Scoped write-back for `display.percent_decimals`, used by the Customize screen, like
/// `HTMLReportConfigWriter`: one key on the `display:` block as the file holds it now.
enum DisplayConfigWriter {
    /// Leaving one decimal where the file never set the key changes nothing.
    static func apply(percentDecimals: Int, to root: inout YAMLCodec.YAMLMapping) {
        var display = root.value(for: "display")?.mapping ?? .init(entries: [])
        let value = percentDecimals == 0 ? 0 : 1
        if value == 1, display.value(for: "percent_decimals") == nil { return }
        display.set("percent_decimals", value: .scalar(.int(value)))
        root.set("display", value: .mapping(display))
    }

    @discardableResult
    static func save(
        percentDecimals: Int, profile: String
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else {
            throw HTMLReportConfigWriter.WriteError.invalidProfile(profile)
        }
        return try ConfigService.saveBlock(key: "display", profile: profile) {
            apply(percentDecimals: percentDecimals, to: &$0)
        }
    }
}
