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
            + optInRows(profile: profile, config: config)
    }

    /// `collect_opt_in` read from the file as typed (the decoder reads a non-list as empty), and
    /// the LAPS privilege warning while that source is on. Both `.warn`, never `.fail`.
    static func optInRows(profile: String, config: ReportConfig) -> [DoctorRow] {
        var rows: [DoctorRow] = []
        let raw = ProfileService.workspaceURL(for: profile)
            .flatMap { try? ConfigLoader.readText(at: $0.appendingPathComponent("config.yaml")) }
            .flatMap { try? ConfigLoader.rawMapping(fromYAML: $0) }
            .flatMap { ConfigLoader.rawValue(at: ["jamf_cli", "collect_opt_in"], in: $0) }
        var problems: [String] = []
        if let raw {
            if let list = raw as? [Any] {
                let unknown = list.compactMap { entry -> String? in
                    let name = (entry as? String).map(ReportEngine.normalizedKind)
                    return name.flatMap(ReportEngine.serverHealthOptInKinds.contains) == true
                        ? nil : ConfigSchema.displayText(String(describing: entry))
                }
                if !unknown.isEmpty {
                    let names = unknown.joined(separator: ", ")
                    problems.append(unknown.count > 1
                        ? L("\(names) are not admin hygiene sources, so they turn nothing on.")
                        : L("\(names) is not an admin hygiene source, so it turns nothing on."))
                }
            } else {
                problems.append(
                    L("jamf_cli.collect_opt_in is not a list, so no admin hygiene source is on."))
            }
        }
        if !problems.isEmpty {
            rows.append(DoctorRow(
                id: "server_health.opt_in_unknown", severity: .warn,
                title: L("jamf_cli.collect_opt_in is not used as written"),
                detail: problems.joined(separator: "\n"),
                hint: L("Turn sources on with the switches on Data Sources, or list laps-pending-rotations, admin-accounts or api-integrations.")))
        }
        let optedIn = SharedConfigPin.collectOptIn(
            configured: config.jamfCli?.collectOptIn, profile: profile)
        if optedIn.contains(ServerHealth.lapsKind) {
            rows.append(DoctorRow(
                id: "server_health.laps_privilege", severity: .warn,
                title: L("LAPS rotations need a privilege that can read LAPS passwords"),
                detail: L("View Local Admin Password also lets the API role read the passwords LAPS holds. Jamf Reports saves only a count."),
                hint: L("Turn LAPS rotations off on Data Sources to take the privilege off the API role.")))
        }
        return rows
    }
}
