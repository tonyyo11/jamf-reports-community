import Foundation

/// The two chart options the Customize screen exposes: whether standalone PNGs
/// are written beside the workbook (`charts.save_png`) and whether OS adoption
/// gets one series per major version (`charts.os_adoption.per_major_charts`).
struct ChartsOptions: Sendable, Equatable {
    var savePNGs: Bool
    var perMajorCharts: Bool

    /// Matches what `ScaffoldService` writes into a fresh config and what the
    /// engine did before `save_png` was honoured, so a workspace with no
    /// `charts:` block behaves as it always has. The report engine reads an absent
    /// `per_major_charts` from here too, so the screen and the report agree.
    static let defaults = ChartsOptions(savePNGs: true, perMajorCharts: true)
}

/// Best-effort read of a profile's chart options. Never throws: a missing
/// workspace, absent file or unparseable config degrades to `.defaults` rather
/// than surfacing a config error on the Customize screen, which does not own
/// that failure mode. Mirrors `NotifyConfigLoader`.
enum ChartsConfigLoader {
    static func load(profile: String) -> ChartsOptions {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return .defaults }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path),
              let charts = (try? ConfigLoader.load(from: url))?.charts
        else { return .defaults }
        return ChartsOptions(
            savePNGs: charts.savePng ?? ChartsOptions.defaults.savePNGs,
            perMajorCharts: charts.osAdoption?.perMajorCharts
                ?? ChartsOptions.defaults.perMajorCharts
        )
    }
}

/// Scoped write-back for the two chart options, used by the Customize screen.
///
/// Deliberately NOT routed through `ConfigService.save`/`managedTopLevelKeys`,
/// for the same reason as `NotifyConfigWriter`: that surface round-trips a fixed
/// key list for the Config tab editor.
///
/// `charts:` is a nested block carrying `historical_csv_dir`, the compliance
/// trend `bands:` list and three sub-blocks, so this reads the existing mapping
/// and sets individual keys rather than replacing the block. Replacing it would
/// silently discard every option this screen does not model — the same
/// read-modify-write discipline `ConfigService` uses for `output` and `jamf_cli`.
enum ChartsConfigWriter {
    enum WriteError: Error, LocalizedError {
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let profile): "Invalid profile name: \(profile)"
            }
        }
    }

    /// Sets the two options on `root`'s `charts:` block and keeps every other key in it.
    static func apply(_ options: ChartsOptions, to root: inout YAMLCodec.YAMLMapping) {
        var charts = root.value(for: "charts")?.mapping ?? .init(entries: [])
        charts.set("save_png", value: .scalar(.bool(options.savePNGs)))

        var osAdoption = charts.value(for: "os_adoption")?.mapping ?? .init(entries: [])
        osAdoption.set("per_major_charts", value: .scalar(.bool(options.perMajorCharts)))
        charts.set("os_adoption", value: .mapping(osAdoption))

        root.set("charts", value: .mapping(charts))
    }

    @discardableResult
    static func save(
        _ options: ChartsOptions, profile: String
    ) throws -> (stamp: ConfigFileStamp, report: ConfigSaveReport) {
        guard ProfileService.isValid(profile) else { throw WriteError.invalidProfile(profile) }
        return try ConfigService.saveBlock(key: "charts", profile: profile) {
            apply(options, to: &$0)
        }
    }
}
