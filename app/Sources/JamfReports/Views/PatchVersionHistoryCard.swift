import SwiftUI

/// What the Version History card shows for one title: every version Jamf defines, newest
/// first, with the window each was the latest, or why the list is missing or partial.
struct PatchVersionHistoryModel: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        /// The row's place in the list: Jamf can list one version twice.
        let position: Int
        let version: String
        let released: Date?
        /// The version's last window outcome; nil when it was never the latest in the history.
        let outcome: VersionWindow.Outcome?
        let daysTo90: Int?
        let windows: Int
        var id: String { "\(position)|\(version)" }
    }

    enum Note: Equatable, Sendable {
        case notRead
        case couldNotBeRead
        case titleNotRead
        case noVersions
        case datesFrom(Date)
        case newest100
    }

    static let visibleRows = 20
    /// jamf-cli 1.29-1.37 may stop at one page of 100 definitions.
    static let pageSize = 100

    let rows: [Row]
    let notes: [Note]
    /// The fleet figure needs windows; with none it would print zeros for nothing measured.
    let showsFleetFigure: Bool

    init(titleId: String, versions: [VersionVelocity], dates: VersionDatesRead) {
        showsFleetFigure = !versions.isEmpty
        let windows = versions.filter { $0.titleId == titleId }
        var notes: [Note] = []
        var defined: [PatchVersionDate] = []
        switch dates {
        case .absent: notes.append(.notRead)
        case .unreadable: notes.append(.couldNotBeRead)
        case .rows(let all, _, _):
            let mine = all.filter { $0.titleId == titleId }
            if mine.isEmpty { notes.append(.titleNotRead) }
            if mine.contains(where: { $0.noVersions == true }) { notes.append(.noVersions) }
            if let stamp = mine.compactMap(\.staleSince).first,
               let day = PatchReleaseDateService.stampDate(stamp) {
                notes.append(.datesFrom(day))
            }
            defined = mine.filter { $0.version != nil }
            if defined.count == Self.pageSize { notes.append(.newest100) }
        }
        var rows: [Row] = defined.map { row in
            let version = row.version ?? ""
            let match = windows.first { $0.version == version }
            return Row(
                position: 0,
                version: version,
                released: match?.releaseDate
                    ?? row.releaseDate.flatMap(SOFAFeedService.parseSOFADate),
                outcome: match?.windows.last?.outcome,
                daysTo90: match?.windows.last?.daysTo90,
                windows: match?.windows.count ?? 0)
        }
        // Versions seen as the latest that the definitions do not list (or none were read), on
        // top, the one whose last window opened latest first.
        let listed = Set(rows.map(\.version))
        let unlisted = windows
            .filter { !listed.contains($0.version) }
            .sorted {
                ($0.windows.last?.start ?? .distantPast) > ($1.windows.last?.start ?? .distantPast)
            }
            .map { version in
                Row(position: 0, version: version.version, released: version.releaseDate,
                    outcome: version.windows.last?.outcome,
                    daysTo90: version.windows.last?.daysTo90,
                    windows: version.windows.count)
            }
        self.rows = (unlisted + rows).enumerated().map { index, row in
            Row(position: index, version: row.version, released: row.released,
                outcome: row.outcome, daysTo90: row.daysTo90, windows: row.windows)
        }
        self.notes = notes
    }
}

/// The Patch screen's Version History card: a title picker over every title Jamf reports,
/// the chosen title's versions, and the fleet's days to 90% over the last 90 days.
struct PatchVersionHistoryCard: View {
    let titles: [PatchStatusRow]
    let versions: [VersionVelocity]
    let dates: VersionDatesRead
    /// False until the slow history read finishes, so loading never reads as "not read".
    let loaded: Bool
    let now: Date
    @Binding var titleId: String?
    @State private var showAll = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let model = PatchVersionHistoryModel(
            titleId: chosen.wrappedValue, versions: versions, dates: dates)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L("Version History"))
                if !loaded {
                    Text("Loading version history…")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else if !model.showsFleetFigure {
                    Text("Version history appears after a few days of collected patch history.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                } else {
                    fleetFigure
                }
                if loaded, !titles.isEmpty {
                    Picker(L("Title"), selection: chosen) {
                        ForEach(sortedTitles, id: \.id) { title in
                            Text(title.title).tag(title.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 360)
                    titleDetail(model)
                }
            }
        }
    }

    private var sortedTitles: [PatchStatusRow] {
        titles.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var chosen: Binding<String> {
        Binding(get: { titleId ?? sortedTitles.first?.id ?? "" },
                set: { titleId = $0; showAll = false })
    }

    private var fleetFigure: some View {
        let summary = PatchVelocityBuilder.summary(versions, now: now)
        let figure = summary.median.map { median in
            L("Last 90 days: median \(median) days from release to 90%, 90th percentile \(summary.p90 ?? median), over \(summary.crossed) windows.")
        } ?? (summary.crossed == 1
            ? L("Last 90 days: 1 window reached 90%, too few for a median.")
            : L("Last 90 days: \(summary.crossed) windows reached 90%, too few for a median."))
        return VStack(alignment: .leading, spacing: 2) {
            Text(figure).font(.callout)
            Text(L("Superseded before 90%: \(summary.superseded) · Not yet at 90%: \(summary.notYet) · Already at 90% when first seen: \(summary.alreadyAt90) · No release date: \(summary.noReleaseDate)"))
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
    }

    @ViewBuilder
    private func titleDetail(_ model: PatchVersionHistoryModel) -> some View {
        ForEach(model.notes, id: \.self) { note in
            Text(noteText(note))
                .font(.caption)
                .foregroundStyle(Theme.Colors.warn)
        }
        let shown = showAll
            ? model.rows : Array(model.rows.prefix(PatchVersionHistoryModel.visibleRows))
        ForEach(shown) { row in
            versionRow(row)
        }
        if model.rows.count > PatchVersionHistoryModel.visibleRows && !showAll {
            Button(L("Show all \(model.rows.count)")) { showAll = true }
                .buttonStyle(.link)
        }
    }

    private func versionRow(_ row: PatchVersionHistoryModel.Row) -> some View {
        HStack(spacing: 12) {
            Text(row.version)
                .font(.callout.monospacedDigit())
                .frame(width: 140, alignment: .leading)
            Text(row.released.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                .font(.caption)
                .frame(width: 110, alignment: .leading)
            Text(row.outcome.map { LShown($0.label) } ?? L("Never the latest in this history"))
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
            Spacer()
            Text(row.daysTo90.map { $0 == 1 ? L("1 day to 90%") : L("\($0) days to 90%") } ?? "—")
                .font(.caption.monospacedDigit())
        }
    }

    private func noteText(_ note: PatchVersionHistoryModel.Note) -> String {
        switch note {
        case .notRead: return L("Release dates not read yet: the patch definitions have not been collected.")
        case .couldNotBeRead: return L("Release dates could not be read.")
        case .titleNotRead: return L("Release dates not read for this title.")
        case .noVersions: return L("Jamf lists no versions for this title.")
        case .datesFrom(let day):
            return L("Dates from \(day.formatted(date: .abbreviated, time: .omitted)); this title did not answer since.")
        case .newest100: return L("The 100 newest versions.")
        }
    }
}

extension PatchVersionHistoryModel.Note: Hashable {}
