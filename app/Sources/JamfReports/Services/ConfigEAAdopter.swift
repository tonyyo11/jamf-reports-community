import Foundation

/// Adopts proposed Extension Attributes into a profile's `config.yaml` `custom_eas`.
///
/// Adoption is strictly ADDITIVE: it loads the existing config, appends new EAs,
/// and saves through `ConfigService.save` — which only rewrites managed top-level
/// keys and re-reads everything else, so unrelated config is preserved verbatim.
/// Proposals whose column already exists in `custom_eas` are skipped.
enum ConfigEAAdopter {

    /// Append `proposals` to a profile's `custom_eas`, skipping duplicate columns.
    ///
    /// - Parameters:
    ///   - proposals: EA candidates the user selected to adopt.
    ///   - profile: Profile slug whose `config.yaml` is updated.
    ///   - workspaceRoot: Optional workspace root override (for tests).
    /// - Returns: The number of EAs actually appended (excludes skipped duplicates).
    /// - Throws: `ConfigService` load/save errors.
    @discardableResult
    static func adoptEAs(
        _ proposals: [ScaffoldService.ProposedEA],
        profile: String,
        workspaceRoot: URL? = nil
    ) throws -> Int {
        let loaded = try ConfigService.load(profile: profile, workspaceRoot: workspaceRoot)
        var state = loaded.state

        let existingColumns = Set(state.customEAs.map { $0.column.lowercased() })
        var added = 0
        for proposal in proposals {
            guard !existingColumns.contains(proposal.column.lowercased()) else { continue }
            state.customEAs.append(customEA(from: proposal))
            added += 1
        }

        guard added > 0 else { return 0 }

        _ = try ConfigService.save(
            profile: profile,
            state: state,
            existingDocument: loaded.document,
            workspaceRoot: workspaceRoot
        )
        return added
    }

    /// Map a `ProposedEA` to the flat `ConfigCustomEA` editing model.
    ///
    /// For boolean EAs the sample value becomes a sensible default `true_value`.
    /// Threshold/version/date fields default empty — the user tunes them later
    /// in the Config screen.
    static func customEA(from proposal: ScaffoldService.ProposedEA) -> ConfigCustomEA {
        ConfigCustomEA(
            name: proposal.name,
            column: proposal.column,
            type: proposal.type,
            trueValue: proposal.type == "boolean" ? proposal.sampleValue : "",
            warningThreshold: "",
            criticalThreshold: "",
            currentVersions: [],
            warningDays: ""
        )
    }
}
