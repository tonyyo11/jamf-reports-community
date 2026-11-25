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
        let landed = health.credentials.map(\.fact) + [health.notifications]
        guard landed.contains(where: {
            if case .value = $0 { return true }
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
        if health.notifications != .notCollected {
            row += 1
            writeNotifications(ws, health, row: row)
        }
    }

    /// Notifications by type as Jamf names them; Jamf filters them by user and site, so zero
    /// is what this login sees.
    private func writeNotifications(_ ws: Worksheet, _ health: ServerHealth, row start: Int) {
        var row = start
        ws.write("Notifications", row: row, col: 0, format: .header)
        row += 1
        guard let (figure, _) = health.notificationFigure else {
            ws.write(ServerHealth.text(for: health.notifications), row: row, col: 0, format: .yellow)
            return
        }
        for (col, header) in ["Type", "Count"].enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        if figure.total == 0 {
            ws.write(ServerHealth.text(for: health.notifications), row: row, col: 0, format: .cell)
            return
        }
        for entry in figure.shown {
            ws.write(entry.name, row: row, col: 0, format: .cell)
            ws.write(entry.count, row: row, col: 1, format: .cell)
            row += 1
        }
        if figure.types.count > figure.shown.count {
            ws.write(
                "\(figure.shown.count) of \(figure.types.count) types", row: row, col: 0,
                format: .cell)
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
