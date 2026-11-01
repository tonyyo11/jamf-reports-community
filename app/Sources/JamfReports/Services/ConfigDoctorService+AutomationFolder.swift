import Foundation

extension ConfigDoctorService {

    /// One `.warn` row when the workspace's `automation` folder is a link
    /// (`WorkspacePaths.confinedFolder` refuses it). Metric-alert and overdue de-duplication
    /// move to this Mac (`AutomationStateFile`); run logs are not written through the link.
    static func automationFolderRows(workspace: URL?) -> [DoctorRow] {
        guard let workspace, AutomationStateFile.isRefused(in: workspace) else { return [] }
        return [DoctorRow(
            id: "automation.folder_refused",
            severity: .warn,
            title: L("The automation folder is a link"),
            detail: L("The automation folder is a link; alert de-duplication is kept on this Mac instead. Run History records are not written until the link is removed."),
            hint: L("Replace the link with a real folder. Alerts, the overdue digest and self-remediation keep working from this Mac's own record meanwhile.")
        )]
    }
}
