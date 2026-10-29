import Foundation

/// What changed between two `computers` snapshots: Macs that joined or left, macOS versions
/// that changed, and Macs that crossed the stale rule. Macs are joined by Jamf ID, then serial
/// (`ComputerDateIndex`); a Mac with neither is counted in `unidentified`, never joined by name,
/// and one whose identifier more than one record of the other snapshot holds is counted in
/// `ambiguous`, never listed as joined or left.
struct SnapshotFleetDrift {
    struct StaleChange {
        let current: ComputerDates
        let priorAge: StaleAge?
        let currentAge: StaleAge?
    }

    let joined: [ComputerDates]
    let left: [ComputerDates]
    let osChanged: [(prior: ComputerDates, current: ComputerDates)]
    let becameStale: [StaleChange]
    let noLongerStale: [StaleChange]
    let unidentified: Int
    let ambiguous: Int
    /// True when either snapshot carries no check-in or inventory date at all (collected
    /// without `general`), so every Mac would read as never checked in.
    let staleNotCompared: Bool
    let currentCount: Int, priorCount: Int

    /// The share of the larger snapshot that joined or left, when that is more than
    /// max(20, a quarter of the smaller snapshot) or the smaller is under half the larger.
    /// Mass enrollment and retirement are normal, so this only prompts a check.
    /// The halving rule needs 20 Macs, so a tiny fleet's normal change (1 to 3) does not warn.
    var largeChangePercent: Int? {
        let (small, large) = (min(currentCount, priorCount), max(currentCount, priorCount))
        let moved = joined.count + left.count
        guard moved > 0,
              Double(moved) > max(20, Double(small) * 0.25) || (large >= 20 && 2 * small < large)
        else { return nil }
        return Int((Double(moved) / Double(large) * 100).rounded())
    }

    /// Each snapshot is judged as of its own collection time, so a Mac that went quiet after the
    /// baseline was taken shows as newly stale.
    init(
        current: [ComputerDates], currentAt: Date,
        prior: [ComputerDates], priorAt: Date, rule: StaleRule
    ) {
        func identified(_ macs: [ComputerDates]) -> [ComputerDates] {
            macs.filter { $0.jamfID != nil || $0.serial != nil }
        }
        let now = identified(current), before = identified(prior)
        (currentCount, priorCount) = (current.count, prior.count)
        unidentified = (current.count - now.count) + (prior.count - before.count)
        let priorIndex = ComputerDateIndex(before), currentIndex = ComputerDateIndex(now)
        func sortedByName(_ macs: [ComputerDates]) -> [ComputerDates] {
            macs.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "")
                == .orderedAscending }
        }
        func isNew(_ mac: ComputerDates, in index: ComputerDateIndex) -> Bool {
            !index.contains(jamfID: mac.jamfID, serial: mac.serial)
        }
        func isAmbiguous(_ mac: ComputerDates, in index: ComputerDateIndex) -> Bool {
            index.match(jamfID: mac.jamfID, serial: mac.serial) == nil && !isNew(mac, in: index)
        }
        joined = sortedByName(now.filter { isNew($0, in: priorIndex) })
        left = sortedByName(before.filter { isNew($0, in: currentIndex) })
        ambiguous = now.filter { isAmbiguous($0, in: priorIndex) }.count
            + before.filter { isAmbiguous($0, in: currentIndex) }.count
        func lacksDates(_ macs: [ComputerDates]) -> Bool {
            !macs.isEmpty && !macs.contains { $0.checkIn != nil || $0.inventory != nil }
        }
        staleNotCompared = lacksDates(current) || lacksDates(prior)

        func age(_ mac: ComputerDates, at date: Date) -> StaleAge? {
            rule.age(of: StaleInputs(
                checkIn: mac.checkIn, inventory: mac.inventory, contact: mac.contact,
                carriesDates: true), now: date)
        }
        func stale(_ age: StaleAge?) -> Bool { age.map { $0 > .days(rule.days) } ?? false }
        var osChanged: [(ComputerDates, ComputerDates)] = []
        var becameStale: [StaleChange] = [], noLongerStale: [StaleChange] = []
        for mac in sortedByName(now) {
            guard let old = priorIndex.match(jamfID: mac.jamfID, serial: mac.serial)
            else { continue }
            let was = OSVersionName.normalized(old.osVersion ?? "")
            let isNow = OSVersionName.normalized(mac.osVersion ?? "")
            if !was.isEmpty, !isNow.isEmpty, was != isNow { osChanged.append((old, mac)) }
            guard !staleNotCompared else { continue }
            let (oldAge, newAge) = (age(old, at: priorAt), age(mac, at: currentAt))
            let change = StaleChange(current: mac, priorAge: oldAge, currentAge: newAge)
            if !stale(oldAge) && stale(newAge) { becameStale.append(change) }
            if stale(oldAge) && !stale(newAge) { noLongerStale.append(change) }
        }
        self.osChanged = osChanged
        self.becameStale = becameStale
        self.noLongerStale = noLongerStale
    }
}

extension CoreDashboard {

    /// The two newest-day `computers` snapshots: the newest, and the newest stamped on an
    /// earlier local calendar day. Same-day collects are one day of history, not a baseline.
    private func driftSnapshots() ->
        (current: (url: URL, date: Date), prior: (url: URL, date: Date))? {
        let snapshots = TrendStore.datedSnapshots(of: "computers", in: dataDir)
        guard let current = snapshots.last else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: current.date)
        guard let prior = snapshots.last(where: { calendar.startOfDay(for: $0.date) < today })
        else { return nil }
        return (current, prior)
    }

    func writeFleetDrift() throws {
        guard let pair = driftSnapshots() else {
            throw CoreDashboardError.noCachedData(names: ["computers (two different days)"])
        }
        func read(_ url: URL) throws -> Data {
            try BoundedFile.read(url, limit: BoundedFile.limit(for: url), followSymlinks: false)
        }
        guard let current = ComputerDates.decodeSnapshot(try read(pair.current.url)),
              let prior = ComputerDates.decodeSnapshot(try read(pair.prior.url)) else {
            throw CoreDashboardError.noCachedData(names: ["computers"])
        }
        let rule = config.staleRule
        let drift = SnapshotFleetDrift(
            current: current, currentAt: pair.current.date,
            prior: prior, priorAt: pair.prior.date, rule: rule)

        let ws = workbook.addSheet("Fleet Drift")
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var row = ws.writeSheetHeader(
            title: "Fleet Drift",
            subtitle: "Collected \(stamp.string(from: pair.current.date)) vs "
                + "\(stamp.string(from: pair.prior.date)) | \(ruleSubtitle(rule)) | "
                + "Generated: \(ISO8601Time.string(Date()))",
            ncols: 6)
        ws.setColumnWidth(0, 0, 34)
        ws.setColumnWidth(1, 5, 22)
        if let percent = drift.largeChangePercent {
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            let warning = "Large change: \(drift.joined.count) joined and \(drift.left.count) left "
                + "since \(day.string(from: pair.prior.date)) (\(percent)% of the fleet). If this "
                + "was not a planned enrollment or retirement, check that the last collect "
                + "finished; a partial collect can make Macs look departed."
            // Row 2 is the header's blank row, so the sections keep their rows.
            ws.write(warning, row: row - 1, col: 0, format: .yellow)
            let line = "[warn] Fleet Drift: \(warning)"
            print("  " + line)
            onLine?(.init(timestamp: Date(), level: .warn, text: line))
            AttentionLog.raise(.fleetDriftLargeChange,
                               "Fleet Drift: \(drift.joined.count) joined and \(drift.left.count) "
                                   + "left (\(percent)% of the fleet)")
        } else {
            AttentionLog.clear(.fleetDriftLargeChange)
        }

        func section(
            _ title: String, note: String? = nil, empty: String = "No changes",
            _ headers: [String], _ cells: [[String]]
        ) {
            row = Self.writeSectionWithNote(
                ws: ws, row: row, title: title, note: note, headers: headers, dataRows: cells,
                empty: empty)
        }
        func listing(_ mac: ComputerDates) -> [String] {
            [mac.name ?? "", mac.serial ?? "", mac.osVersion ?? "",
             mac.checkIn.map(ISO8601Time.string) ?? ""]
        }
        func days(_ age: StaleAge?) -> String {
            switch age {
            case .days(let count)?: "\(count)"
            case .never?: "Never"
            case nil: ""
            }
        }
        let listHeaders = ["Name", "Serial", "OS", "Last Check-in"]
        let staleHeaders = ["Name", "Serial", "Prior Days Stale", "Current Days Stale"]
        let notes = [
            drift.unidentified > 0
                ? "\(drift.unidentified) Macs with no Jamf ID or serial left out" : nil,
            drift.ambiguous > 0
                ? "\(drift.ambiguous) Macs whose Jamf ID or serial more than one record holds "
                    + "left out" : nil,
        ].compactMap { $0 }
        section("New Enrollments", note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                listHeaders, drift.joined.map(listing))
        section("Departed Devices", listHeaders, drift.left.map(listing))
        let staleNote = drift.staleNotCompared
            ? "Not compared: a snapshot has no check-in or inventory dates" : nil
        let staleEmpty = drift.staleNotCompared ? "Not compared" : "No changes"
        func staleRow(_ change: SnapshotFleetDrift.StaleChange) -> [String] {
            [change.current.name ?? "", change.current.serial ?? "",
             days(change.priorAge), days(change.currentAge)]
        }
        section("New Stale", note: staleNote, empty: staleEmpty, staleHeaders,
                drift.becameStale.map(staleRow))
        section("Recovered Stale", note: staleNote, empty: staleEmpty, staleHeaders,
                drift.noLongerStale.map(staleRow))
        section("OS Changed", ["Name", "Serial", "Prior OS", "Current OS"], drift.osChanged.map {
            [$0.current.name ?? "", $0.current.serial ?? "",
             $0.prior.osVersion ?? "", $0.current.osVersion ?? ""]
        })
    }

    @discardableResult
    private static func writeSectionWithNote(
        ws: Worksheet,
        row: Int,
        title: String,
        note: String?,
        headers: [String],
        dataRows: [[String]],
        empty: String
    ) -> Int {
        var r = row
        ws.write(title, row: r, col: 0, format: .header)
        if let note { ws.write(note, row: r, col: 1, format: .subtitle) }
        r += 1
        for (colIdx, header) in headers.enumerated() {
            ws.write(header, row: r, col: colIdx, format: .header)
        }
        r += 1
        if dataRows.isEmpty {
            ws.write(empty, row: r, col: 0, format: .cell)
            r += 1
        } else {
            for cells in dataRows {
                for (colIdx, cell) in cells.enumerated() {
                    ws.write(cell, row: r, col: colIdx, format: .cell)
                }
                r += 1
            }
        }
        r += 1  // blank separator row
        return r
    }
}
