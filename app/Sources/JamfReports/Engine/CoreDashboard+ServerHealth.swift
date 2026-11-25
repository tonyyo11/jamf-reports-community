import Foundation

extension CoreDashboard {

    // MARK: - Server and Admin Health
    // Source: the server-health snapshots through `ServerHealth`.

    func writeServerAdminHealth() throws {
        let now = Date()
        let warningDays = config.thresholds?.resolvedCertWarningDays
            ?? ManagementHealth.defaultWarningDays
        let health = ServerHealth.load(dataDir: dataDir, warningDays: warningDays, now: now)
        // A tab of "not permitted" rows would say nothing; the Audit card carries those.
        guard health.credentials.contains(where: {
            if case .value = $0.fact { return true }
            return false
        }) else { throw CoreDashboardError.noServerHealthData }

        let ws = workbook.addSheet(SheetID.serverAdminHealth.rawValue)
        var row = ws.writeSheetHeader(
            title: t("Server and Admin Health"),
            subtitle: "Warning window: \(warningDays) days | Generated: \(ISO8601Time.string(now))",
            ncols: 5)
        ws.setColumnWidth(0, 0, 28)
        ws.setColumnWidth(1, 1, 22)
        ws.setColumnWidth(2, 2, 12)
        ws.setColumnWidth(3, 3, 44)
        ws.setColumnWidth(4, 4, 22)

        ws.write("Credentials", row: row, col: 0, format: .header)
        row += 1
        let headers = ["Credential", "Expires", "Days left", "State", "As of"]
        for (col, header) in headers.enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for credential in health.credentials where credential.fact != .notCollected {
            writeCredentialRow(ws, credential, row: row)
            row += 1
        }
    }

    private func writeCredentialRow(
        _ ws: Worksheet, _ row: ServerHealth.CredentialRow, row line: Int
    ) {
        guard case .value(.credential(let credential), _) = row.fact else {
            ws.write(row.label, row: line, col: 0, format: .cell)
            ws.write(ServerHealth.text(for: row.fact), row: line, col: 3, format: .yellow)
            return
        }
        let format: CellFormat = credential.state == .expired ? .red
            : credential.state == .expiring ? .yellow : .cell
        ws.write(row.label, row: line, col: 0, format: format)
        ws.write(ServerHealth.expiryDay(credential) ?? "", row: line, col: 1, format: format)
        if let left = credential.daysLeft { ws.write(left, row: line, col: 2, format: format) }
        ws.write(ManagementReport.stateText(credential.state), row: line, col: 3, format: format)
        if let asOf = row.asOf {
            ws.write(ISO8601Time.string(asOf), row: line, col: 4, format: .cell)
        }
    }
}
