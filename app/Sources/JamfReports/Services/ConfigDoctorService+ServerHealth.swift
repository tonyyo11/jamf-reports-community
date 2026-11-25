import Foundation

extension ConfigDoctorService {

    /// `.suggest`: the API role is refused a server-health source. Not-set-up kinds are no
    /// finding. Privilege names come from jamf-cli's hint only; without one the row says so.
    static func serverHealthRows(refused: [String: FailureCause]) -> [DoctorRow] {
        let missing = refused.filter { $0.value.kind == .missingPermission }
            .sorted { $0.key < $1.key }
        guard !missing.isEmpty else { return [] }
        let lines = missing.map { kind, cause in
            let source = ServerHealth.sourceName(kind)
            return cause.names.isEmpty
                ? L("this login cannot read \(source); check the API role's privileges for it")
                : L("\(source) needs \(cause.names.joined(separator: ", "))")
        }
        return [DoctorRow(
            id: "server_health.not_permitted",
            severity: .suggest,
            title: L("Some server health sources are not permitted"),
            detail: lines.joined(separator: "\n"),
            hint: L("Add the privilege to the API role, then Collect now. Without it the source stays off and is checked again weekly.")
        )]
    }

    /// Reads the state folder only; a Jamf School or Protect-only workspace runs none of them.
    static func serverHealthRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        guard !environment.isProtectOnly,
              ProfileProductType.detect(from: config, profile: profile).type == .jamfPro
        else { return [] }
        return serverHealthRows(refused: StateFileStore.advisoryCauses(profile: profile))
    }
}
