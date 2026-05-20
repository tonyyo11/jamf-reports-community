import SwiftUI

/// Single-device lookup screen. Search by serial, hostname/display name, asset
/// tag, or any identifier `jamf-cli pro device <id>` (computers) or
/// `jamf-cli pro mobile-devices get <id>` (mobile) accepts.
///
/// Resolution flow:
///   1. Term is matched against a cache-backed `DeviceLookupIndex` covering
///      both computers-list and mobile-devices-list snapshots.
///   2. Single match → fetch that device's detail directly.
///   3. Multiple matches → show candidate chips so the user picks the right
///      device (e.g. when a name appears in both inventories).
///   4. No cache match → fall back to treating the term as a numeric ID and
///      try a computer detail call, then a mobile detail call.
///   5. Still nothing → show a "Refresh inventory" button so the user can
///      re-collect lists without having to leave this screen.
struct DeviceLookupView: View {
    @Environment(WorkspaceStore.self) private var workspace

    @State private var searchTerm = ""
    @State private var submittedTerm = ""
    @State private var resolvedKind: DeviceLookupIndex.Kind?
    @State private var state: LookupState = .idle
    @State private var detail: DeviceDetail?
    @State private var requestKey = ""
    @State private var index = DeviceLookupIndex()
    @State private var candidates: [DeviceLookupIndex.Candidate] = []
    @State private var refreshing = false
    /// Set to the snapshot's mtime when the most recent fetch silently fell back
    /// to cached data (`CLIBridge.DeviceDetailResult.fromCache == true`); nil when
    /// the live API call succeeded. Drives the staleness banner above the result.
    @State private var staleSince: Date?
    @FocusState private var searchFocused: Bool

    enum LookupState: Equatable {
        case idle
        case loading
        case loaded
        case ambiguous
        case unavailable(String)
        case noMatchOfferRefresh(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                searchCard
                resultCard
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .onAppear {
            searchFocused = true
            index.load(profile: workspace.profile)
        }
        .onChange(of: workspace.profile) { _, newValue in
            index.load(profile: newValue)
            // Profile change invalidates any in-flight lookup.
            state = .idle
            detail = nil
            candidates = []
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
        .searchable(text: $searchTerm, placement: .toolbar, prompt: "Serial, hostname, asset tag, or device ID")
    }

    private var header: some View {
        PageHeader(
            kicker: "Device",
            title: "Device Lookup",
            subtitle: "Resolve a single computer or mobile device by serial, hostname, asset tag, or ID."
        )
    }

    private var searchCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                FieldLabel(label: "Identifier")
                HStack(spacing: 8) {
                    PNPTextField(
                        value: $searchTerm,
                        placeholder: "Serial, hostname, asset tag, or device ID",
                        mono: true
                    )
                    .focused($searchFocused)
                    .onSubmit { performLookup() }
                    PNPButton(
                        title: state == .loading ? "Looking up…" : "Lookup",
                        icon: state == .loading ? "hourglass" : "magnifyingglass",
                        style: .gold
                    ) {
                        performLookup()
                    }
                    .disabled(state == .loading || trimmedTerm.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                FieldHelp(text: helpLineText)
            }
        }
    }

    private var helpLineText: String {
        let count = index.candidates.count
        let countLabel: String
        if count == 0 {
            countLabel = "no cached inventory yet — run Refresh to populate"
        } else {
            let computers = index.candidates.lazy.filter { $0.kind == .computer }.count
            let mobiles = count - computers
            countLabel = "\(computers) computers · \(mobiles) mobile devices indexed"
        }
        return "Auto-resolves serials and names against `\(workspace.profile)` cached inventory. \(countLabel)."
    }

    @ViewBuilder
    private var resultCard: some View {
        if workspace.demoMode {
            Card(padding: 18) {
                Text("Device lookup is available in live mode only.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        } else {
            switch state {
            case .idle:
                EmptyView()
            case .loading:
                Card(padding: 18) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Resolving \(submittedTerm) via jamf-cli…")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
            case .loaded:
                if let detail {
                    detailCard(detail)
                }
            case .ambiguous:
                ambiguousCard
            case .unavailable(let message):
                unavailableCard(message)
            case .noMatchOfferRefresh(let message):
                noMatchCard(message)
            }
        }
    }

    private var ambiguousCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Multiple matches for \(submittedTerm)")
                Text("Pick the device you want to inspect.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.fgMuted)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates) { cand in
                        candidateRow(cand)
                    }
                }
            }
        }
    }

    private func candidateRow(_ cand: DeviceLookupIndex.Candidate) -> some View {
        Button {
            fetchDetail(id: cand.id, kind: cand.kind)
        } label: {
            HStack(spacing: 10) {
                Pill(text: cand.kind.displayLabel,
                     tone: cand.kind == .computer ? .teal : .gold,
                     icon: cand.kind == .computer ? "desktopcomputer" : "ipad")
                VStack(alignment: .leading, spacing: 2) {
                    Text(cand.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    HStack(spacing: 8) {
                        Mono(text: "ID \(cand.id)", size: 10.5, color: Theme.Colors.fgMuted)
                        if let serial = cand.serial, !serial.isEmpty {
                            Mono(text: serial, size: 10.5, color: Theme.Colors.fgMuted)
                        }
                        if let os = cand.osVersion, !os.isEmpty {
                            Mono(text: os, size: 10.5, color: Theme.Colors.fgMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    private func unavailableCard(_ message: String) -> some View {
        Card(padding: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text(clarifiedUnavailableMessage(message))
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.warn)
            }
        }
    }

    private func clarifiedUnavailableMessage(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") {
            return "Authentication failed — check your jamf-cli profile token."
        }
        if lower.contains("timeout") || lower.contains("connection") || lower.contains("network") {
            return "Network unreachable — check your connection to Jamf Pro."
        }
        if lower.contains("decode") || lower.contains("parse") {
            return "Cached data may be stale — run Collect to refresh."
        }
        return message
    }

    private func noMatchCard(_ message: String) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "magnifyingglass.circle")
                        .foregroundStyle(Theme.Colors.fgMuted)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                HStack(spacing: 8) {
                    PNPButton(
                        title: refreshing ? "Refreshing…" : "Refresh inventory",
                        icon: refreshing ? "hourglass" : "arrow.clockwise",
                        size: .sm
                    ) {
                        refreshIndex()
                    }
                    .disabled(refreshing)
                    if let listURL = workspace.computerListURL() {
                        PNPButton(
                            title: "Open Computers in Jamf Pro",
                            icon: "arrow.up.right.square",
                            style: .neutral,
                            size: .sm
                        ) {
                            SystemActions.open(listURL)
                        }
                    }
                    Text("Re-runs `jamf-cli pro computers list` and `mobile-devices list`, then retries.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
            }
        }
    }

    private func detailCard(_ detail: DeviceDetail) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                if let since = staleSince {
                    // PR-13: migrated to shared StaleDataBanner component.
                    // Visually identical to the prior inline banner — the
                    // `.stale(at:)` case carries the same icon, copy
                    // template ("Stale data — last fetched X ago"), and
                    // warn-toned chrome.
                    StaleDataBanner(source: .stale(at: since))
                }
                HStack {
                    SectionHeader(title: detailTitle(detail))
                    Spacer()
                    if let kind = resolvedKind {
                        Pill(text: kind.displayLabel,
                             tone: kind == .computer ? .teal : .gold,
                             icon: kind == .computer ? "desktopcomputer" : "ipad")
                    }
                    Pill(text: "Loaded", tone: .teal, icon: "checkmark")
                    if let url = computerConsoleURL(for: detail) {
                        PNPButton(
                            title: "Open in Jamf Pro",
                            icon: "arrow.up.right.square",
                            size: .sm
                        ) {
                            SystemActions.open(url)
                        }
                    }
                }

                ForEach(detail.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: section.title, size: 13)
                        ForEach(section.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.label)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.fgMuted)
                                    .frame(width: 140, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.value)
                                        .font(.footnote)
                                        .foregroundStyle(Theme.Colors.fg2)
                                        .textSelection(.enabled)
                                    if !item.note.isEmpty {
                                        Mono(text: item.note, size: 10.5, color: Theme.Colors.fgMuted)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                ForEach(detail.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warn)
                }
            }
        }
    }

    // MARK: - Lookup

    private func performLookup() {
        let term = trimmedTerm
        guard !term.isEmpty else { return }
        let profile = workspace.profile

        submittedTerm = term
        let matches = index.resolve(term)
        candidates = matches
        switch matches.count {
        case 0:
            // No cache hit — fall back to direct ID lookup against both kinds.
            fallbackToIDLookup(term: term, profile: profile)
        case 1:
            fetchDetail(id: matches[0].id, kind: matches[0].kind)
        default:
            state = .ambiguous
            detail = nil
            resolvedKind = nil
        }
    }

    private func fetchDetail(id: String, kind: DeviceLookupIndex.Kind) {
        let profile = workspace.profile
        let key = "\(profile)|\(kind.rawValue)|\(id)"
        requestKey = key
        state = .loading
        detail = nil
        resolvedKind = kind
        staleSince = nil

        Task {
            let result: CLIBridge.DeviceDetailResult?
            switch kind {
            case .computer:
                result = await CLIBridge().deviceDetailWithProvenance(profile: profile, deviceID: id)
            case .mobile:
                result = await CLIBridge().mobileDeviceDetailWithProvenance(profile: profile, deviceID: id)
            }
            guard requestKey == key else { return }
            guard let result else {
                state = .unavailable(
                    "jamf-cli could not load the \(kind.displayLabel.lowercased()) detail for ID `\(id)` on profile `\(profile)`. Run `\(cliCommand(kind: kind, profile: profile, id: id))` in a terminal for the underlying error."
                )
                return
            }
            staleSince = result.fromCache ? snapshotMTime(result.cacheURL) : nil
            do {
                let decoded = try DeviceDetail.decode(from: result.data, lookupID: id)
                detail = decoded
                state = .loaded
            } catch {
                state = .unavailable("Could not decode jamf-cli response for \(id) on profile `\(profile)`.")
            }
        }
    }

    /// Cache miss path: try the term as a numeric ID against both kinds.
    /// Computers first because they're the common case; if that fails, try mobile.
    /// Final failure offers a refresh.
    private func fallbackToIDLookup(term: String, profile: String) {
        let key = "\(profile)|fallback|\(term)"
        requestKey = key
        state = .loading
        detail = nil
        resolvedKind = nil
        staleSince = nil

        Task {
            let bridge = CLIBridge()
            if let result = await bridge.deviceDetailWithProvenance(profile: profile, deviceID: term) {
                guard requestKey == key else { return }
                if let decoded = try? DeviceDetail.decode(from: result.data, lookupID: term) {
                    resolvedKind = .computer
                    detail = decoded
                    staleSince = result.fromCache ? snapshotMTime(result.cacheURL) : nil
                    state = .loaded
                    return
                }
            }
            if let result = await bridge.mobileDeviceDetailWithProvenance(profile: profile, deviceID: term) {
                guard requestKey == key else { return }
                if let decoded = try? DeviceDetail.decode(from: result.data, lookupID: term) {
                    resolvedKind = .mobile
                    detail = decoded
                    staleSince = result.fromCache ? snapshotMTime(result.cacheURL) : nil
                    state = .loaded
                    return
                }
            }
            guard requestKey == key else { return }
            state = .noMatchOfferRefresh(
                "No cached match for `\(term)` on profile `\(profile)`, and direct ID lookups for computer and mobile both failed. The cache may be stale."
            )
        }
    }

    /// Read the contentModificationDate of a cache file; returns nil on stat failure.
    private func snapshotMTime(_ url: URL?) -> Date? {
        guard let url else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private func refreshIndex() {
        let profile = workspace.profile
        refreshing = true
        Task {
            // `collect` already re-fetches the full set of cached snapshots,
            // including computers-list and mobile-devices-list. It's heavier
            // than strictly necessary, but it goes through the audited
            // CLI bridge surface and keeps this screen from owning bespoke
            // jamf-cli invocation logic.
            _ = await CLIBridge().collect(profile: profile) { _ in }
            index.load(profile: profile)
            refreshing = false
            // Auto-retry the original lookup against the freshly loaded index.
            if !submittedTerm.isEmpty {
                performLookup()
            }
        }
    }

    private var trimmedTerm: String {
        searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cliCommand(kind: DeviceLookupIndex.Kind, profile: String, id: String) -> String {
        switch kind {
        case .computer: "jamf-cli -p \(profile) pro device \(id)"
        case .mobile:   "jamf-cli -p \(profile) pro mobile-devices get \(id)"
        }
    }

    private func detailTitle(_ detail: DeviceDetail) -> String {
        let candidates = ["name", "computer name", "device name", "host name", "hostname", "display name"]
        for section in detail.sections {
            for item in section.items where candidates.contains(item.label.lowercased()) {
                if !item.value.isEmpty { return item.value }
            }
        }
        return detail.lookupID
    }

    private func computerConsoleURL(for detail: DeviceDetail) -> URL? {
        // Mobile devices use a different Jamf Pro URL path — only build a
        // console deep-link when we resolved a computer.
        guard resolvedKind != .mobile else { return nil }
        let candidates = ["jamf id", "id", "computer id", "udid"]
        for section in detail.sections {
            for item in section.items where candidates.contains(item.label.lowercased()) {
                if let url = workspace.consoleURL(forComputerID: item.value) {
                    return url
                }
            }
        }
        return nil
    }
}
