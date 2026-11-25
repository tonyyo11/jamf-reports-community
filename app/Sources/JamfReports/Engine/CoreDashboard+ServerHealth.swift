import Foundation

extension CoreDashboard {

    // MARK: - Server and Admin Health
    // Source: the server-health snapshots through `ServerHealth`.

    func writeServerAdminHealth() throws {
        let now = Date()
        let warningDays = config.thresholds?.resolvedCertWarningDays
            ?? ManagementHealth.defaultWarningDays
        let health = ServerHealth.load(
            dataDir: dataDir, warningDays: warningDays, now: now, optIn: optInKinds)
        // A tab of "not permitted" rows would say nothing; the Audit card carries those.
        let landed = health.credentials.map(\.fact) + [health.notifications]
            + health.adminHygiene.map(\.fact)
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
            row = writeNotifications(ws, health, row: row)
        }
        let hygiene = health.adminHygiene.filter { $0.fact != .notCollected }
        if !hygiene.isEmpty {
            row += 1
            writeAdminHygiene(ws, hygiene, row: row)
        }
    }

    /// Counts only, as the opt-in reductions save them: never a name, email or client ID.
    private func writeAdminHygiene(
        _ ws: Worksheet, _ rows: [ServerHealth.HygieneRow], row start: Int
    ) {
        var row = start
        ws.write("Admin hygiene", row: row, col: 0, format: .header)
        row += 1
        for (col, header) in ["Source", "Figure", "Count"].enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for entry in rows {
            guard case .value(let fact, _) = entry.fact else {
                ws.write(entry.label, row: row, col: 0, format: .cell)
                ws.write(ServerHealth.text(for: entry.fact), row: row, col: 1, format: .yellow)
                row += 1
                continue
            }
            for figure in ServerHealth.figures(of: fact) {
                ws.write(entry.label, row: row, col: 0, format: .cell)
                ws.write(figure.label, row: row, col: 1, format: .cell)
                ws.write(figure.count, row: row, col: 2, format: .cell)
                row += 1
            }
        }
    }

    /// Notifications by type as Jamf names them; Jamf filters them by user and site, so zero
    /// is what this login sees.
    @discardableResult
    private func writeNotifications(
        _ ws: Worksheet, _ health: ServerHealth, row start: Int
    ) -> Int {
        var row = start
        ws.write("Notifications", row: row, col: 0, format: .header)
        row += 1
        guard let (figure, stale) = health.notificationFigure else {
            ws.write(ServerHealth.text(for: health.notifications), row: row, col: 0, format: .yellow)
            return row + 1
        }
        // A kind that has failed since: the figure is the last one landed, not today's.
        if let stale {
            ws.write(
                "As of \(ServerHealth.day(stale)), no longer measured", row: row, col: 0,
                format: .yellow)
            row += 1
        }
        for (col, header) in ["Type", "Count"].enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        if figure.total == 0 {
            ws.write(ServerHealth.text(for: health.notifications), row: row, col: 0, format: .cell)
            return row + 1
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
            row += 1
        }
        return row
    }

    private func writeCredentialRow(
        _ ws: Worksheet, _ row: ServerHealth.CredentialRow, row line: Int
    ) {
        guard case .value(.credential(let credential), let stale) = row.fact else {
            ws.write(row.label, row: line, col: 0, format: .cell)
            ws.write(ServerHealth.text(for: row.fact), row: line, col: 3, format: .yellow)
            return
        }
        let format: CellFormat = credential.state == .expired ? .red
            : credential.state == .expiring ? .yellow : .cell
        ws.write(row.label, row: line, col: 0, format: format)
        ws.write(ServerHealth.expiryDay(credential) ?? "", row: line, col: 1, format: format)
        if let left = credential.daysLeft { ws.write(left, row: line, col: 2, format: format) }
        let state = ManagementReport.stateText(credential.state)
        let note = stale.map { " (as of \(ServerHealth.day($0)), no longer measured)" } ?? ""
        ws.write(state + note, row: line, col: 3, format: format)
        if let asOf = row.asOf {
            ws.write(ISO8601Time.string(asOf), row: line, col: 4, format: .cell)
        }
    }
}
