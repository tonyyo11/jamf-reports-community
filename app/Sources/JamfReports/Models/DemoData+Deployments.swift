import Foundation

extension DemoData {
    /// Three App Installers deployments and three patch policies on the 524-Mac fleet: one at
    /// warning, one pinned, one with nothing in scope, one not enabled.
    static let deploymentHealth: DeploymentHealthCard = {
        func app(_ id: String, _ name: String, failed: Int, installed: Int, pinned: Bool = false)
            -> DeploymentHealth.Row {
            .init(source: .appInstallers, id: id, name: name, enabled: true, failed: failed,
                  inScope: installed + failed, assignedElsewhere: 0,
                  deployedVersion: pinned ? "4.9" : "5.0", latestVersion: "5.0",
                  updateBehavior: pinned ? "MANUAL" : "AUTOMATIC", completed: nil, deferred: nil,
                  pending: nil, targetVersion: nil, softwareTitle: nil)
        }
        func policy(_ id: String, _ name: String, enabled: Bool, completed: Int, failed: Int)
            -> DeploymentHealth.Row {
            .init(source: .patchPolicy, id: id, name: name, enabled: enabled, failed: failed,
                  inScope: completed + failed, assignedElsewhere: nil, deployedVersion: nil,
                  latestVersion: nil, updateBehavior: nil, completed: completed, deferred: 0,
                  pending: 0, targetVersion: "5.0", softwareTitle: name)
        }
        return DeploymentHealthCard(
            states: [
                .appInstallers: .rows([
                    app("1", "Example Browser", failed: 62, installed: totalDevices - 62),
                    app("2", "Example Editor", failed: 3, installed: 117, pinned: true),
                    app("3", "Example Viewer", failed: 0, installed: 0),
                ], asOf: nil, leftOut: 0),
                .patchPolicy: .rows([
                    policy("1", "Example Browser latest", enabled: true,
                           completed: totalDevices - 9, failed: 9),
                    policy("2", "Example Viewer old", enabled: false, completed: 0, failed: 0),
                ], asOf: nil, leftOut: 0),
            ],
            levels: .defaults)
    }()
}
