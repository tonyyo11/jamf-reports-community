import Foundation

extension CoreDashboard {

    // MARK: - Management Health
    // Source: the `computers` snapshot through `ManagementHealth`, and the newest
    // `device-enrollment-instances` snapshot through `EnrollmentTokenSnapshot`.

    func writeManagementHealth() throws {
        let names = ["computers", "computers-list", "computers_list"]
        let loaded: Any
        do {
            loaded = try loadLatestJSON(names: names)
        } catch let error as CoreDashboardError {
            throw error
        } catch {
            throw warnManagementUnreadable(names)
        }
        // A snapshot that is not a list of computers is unreadable, not an empty fleet.
        guard let rows = loaded as? [[String: Any]] else { throw warnManagementUnreadable(names) }
        guard !rows.isEmpty else { throw CoreDashboardError.noCachedData(names: names) }
        let now = Date()
        let warningDays = config.thresholds?.resolvedCertWarningDays
            ?? ManagementHealth.defaultWarningDays
        guard let health = ManagementReport.health(
            computers: rows, rule: config.staleRule, warningDays: warningDays, now: now)
        else { throw CoreDashboardError.noCachedData(names: names) }

        let ws = workbook.addSheet("Management Health")
        var row = ws.writeSheetHeader(
            title: t("Management Health"),
            subtitle: "Profile warning window: \(warningDays) days | "
                + "Generated: \(ISO8601Time.string(now))",
            ncols: 5)
        ws.setColumnWidth(0, 0, 46)
        ws.setColumnWidth(1, 1, 22)
        ws.setColumnWidth(2, 2, 30)
        ws.setColumnWidth(3, 3, 26)
        ws.setColumnWidth(4, 4, 12)

        row = writeManagementSummary(ws, health, row: row)
        row = writeManagementToggles(ws, health, row: row + 1)
        row = writeManagementValues(ws, health, row: row + 1)
        row = writeEnrollmentTokens(ws, dataDir: dataDir, warningDays: warningDays, now: now,
                                    row: row + 1)
        writeManagementDetail(ws, ManagementReport.detailRows(health, now: now),
                              judgedGapsOrWarnings: health.judgedGapsOrWarnings, row: row + 1)
    }

    /// Logs one `[warn]` naming the kind and returns the error that skips the sheet.
    private func warnManagementUnreadable(_ names: [String]) -> CoreDashboardError {
        let line = "[warn] Management Health: the \(names[0]) snapshot could not be read; "
            + "the sheet was skipped."
        if let onLine {
            onLine(.init(timestamp: Date(), level: .warn, text: line))
        } else {
            print("  " + line)
        }
        return .noCachedData(names: names)
    }

    private func writeManagementSummary(
        _ ws: Worksheet, _ health: ManagementHealth, row start: Int
    ) -> Int {
        var row = start
        for (col, header) in ["Finding", "Macs", "Evaluated", "Kind"].enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for finding in ManagementHealth.Finding.allCases {
            guard let figure = health.figures[finding] else { continue }
            var title = finding.title
            if finding == .binaryBehind, let newest = health.newestBinary {
                title += " (\(newest.label))"
            }
            let fmt: CellFormat = figure.count == 0 ? .cell
                : finding.kind == .gap ? .red : finding.kind == .warning ? .yellow : .cell
            ws.write(title, row: row, col: 0, format: fmt)
            ws.write(figure.count, row: row, col: 1, format: fmt)
            ws.write(figure.evaluated, row: row, col: 2, format: fmt)
            ws.write(ManagementReport.kindText(finding.kind), row: row, col: 3, format: fmt)
            row += 1
        }
        return row
    }

    /// On, off and not-reported counts of the neutral settings; never graded.
    private func writeManagementToggles(
        _ ws: Worksheet, _ health: ManagementHealth, row start: Int
    ) -> Int {
        var row = start
        for (col, header) in ["Setting", "On", "Off", "Not reported"].enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for toggle in ManagementHealth.Toggle.allCases {
            guard let counts = health.toggles[toggle] else { continue }
            ws.write(ManagementReport.title(toggle), row: row, col: 0, format: .cell)
            ws.write(counts.on.count, row: row, col: 1, format: .cell)
            ws.write(counts.off.count, row: row, col: 2, format: .cell)
            ws.write(health.managedCount - counts.evaluated, row: row, col: 3, format: .cell)
            row += 1
        }
        return row
    }

    /// Macs per value, as Jamf gives the value.
    private func writeManagementValues(
        _ ws: Worksheet, _ health: ManagementHealth, row start: Int
    ) -> Int {
        var row = start
        let breakdowns: [ManagementHealth.Breakdown] = [
            .attestationProblem, .batteryHealth, .externalBootLevel, .appleEnrollmentType,
        ]
        for (col, header) in ["Field", "Value", "Macs"].enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for breakdown in breakdowns {
            for entry in health.values(breakdown) {
                ws.write(ManagementReport.title(breakdown), row: row, col: 0, format: .cell)
                ws.write(entry.value, row: row, col: 1, format: .cell)
                ws.write(entry.records.count, row: row, col: 2, format: .cell)
                row += 1
            }
        }
        return row
    }

    private func writeEnrollmentTokens(
        _ ws: Worksheet, dataDir: URL, warningDays: Int, now: Date, row start: Int
    ) -> Int {
        var row = start
        ws.write("Automated Device Enrollment", row: row, col: 0, format: .header)
        row += 1
        let snapshot = EnrollmentTokenSnapshot.load(
            dataDir: dataDir, warningDays: warningDays, now: now)
        if snapshot.readFailed {
            ws.write("The enrollment instances snapshot could not be read.",
                     row: row, col: 0, format: .yellow)
            return row + 1
        }
        guard snapshot.isDetected else {
            ws.write("Enrollment instances not collected.", row: row, col: 0, format: .cell)
            return row + 1
        }
        guard !snapshot.tokens.isEmpty else {
            ws.write("No Automated Device Enrollment instances.", row: row, col: 0, format: .cell)
            return row + 1
        }
        for (col, header) in ["Name", "Token expires", "Days left", "State"].enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for token in snapshot.tokens {
            let fmt: CellFormat = token.state == .expired ? .red
                : token.state == .expiring ? .yellow : .cell
            ws.write(token.name ?? "", row: row, col: 0, format: fmt)
            ws.write(Self.dayText(ManagementReport.expiryDay(token, now: now)),
                     row: row, col: 1, format: fmt)
            if let left = token.daysLeft {
                ws.write(left, row: row, col: 2, format: fmt)
            } else {
                ws.write("", row: row, col: 2, format: fmt)
            }
            ws.write(ManagementReport.stateText(token.state), row: row, col: 3, format: fmt)
            row += 1
        }
        return row
    }

    private func writeManagementDetail(
        _ ws: Worksheet, _ rows: [ManagementReport.DetailRow], judgedGapsOrWarnings: Bool,
        row start: Int
    ) {
        var row = start
        guard !rows.isEmpty || judgedGapsOrWarnings else { return }
        ws.write("Macs with a gap or warning", row: row, col: 0, format: .header)
        row += 1
        guard !rows.isEmpty else {
            ws.write("No Mac has a management gap or warning.", row: row, col: 0, format: .cell)
            return
        }
        for (col, header) in ["Computer", "Serial", "Finding", "Value", "Days"].enumerated() {
            ws.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for entry in rows {
            let fmt: CellFormat = entry.finding.kind == .gap ? .red : .yellow
            ws.write(entry.record.name, row: row, col: 0, format: fmt)
            ws.write(entry.record.serial, row: row, col: 1, format: fmt)
            ws.write(entry.finding.title, row: row, col: 2, format: fmt)
            ws.write(entry.value, row: row, col: 3, format: fmt)
            if let days = entry.days {
                ws.write(days, row: row, col: 4, format: fmt)
            } else {
                ws.write("", row: row, col: 4, format: fmt)
            }
            row += 1
        }
    }
}
