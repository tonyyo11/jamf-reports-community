import SwiftUI

/// Single-device lookup screen. Search by serial, hostname, asset tag, or any
/// identifier `jamf-cli pro device <id>` accepts. Reuses the existing
/// `DeviceDetail` model and `CLIBridge.deviceDetail` plumbing — this screen is a
/// search-driven entrypoint to the same data Devices renders inline.
struct DeviceLookupView: View {
    @Environment(WorkspaceStore.self) private var workspace

    @State private var searchTerm = ""
    @State private var submittedTerm = ""
    @State private var state: LookupState = .idle
    @State private var detail: DeviceDetail?
    @State private var requestKey = ""
    @FocusState private var searchFocused: Bool

    enum LookupState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable(String)
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Device",
            title: "Device Lookup",
            subtitle: "Resolve a single device by serial, hostname, or asset tag via jamf-cli."
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
                }
                FieldHelp(text: "Calls `jamf-cli -p \(workspace.profile) pro device <id>` and caches the JSON under the active workspace.")
            }
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if workspace.demoMode {
            Card(padding: 18) {
                Text("Device lookup is available in live mode only.")
                    .font(.system(size: 12.5))
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
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
            case .loaded:
                if let detail {
                    detailCard(detail)
                }
            case .unavailable(let message):
                Card(padding: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.warn)
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Colors.warn)
                    }
                }
            }
        }
    }

    private func detailCard(_ detail: DeviceDetail) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: detailTitle(detail))
                    Spacer()
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
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.Colors.fgMuted)
                                    .frame(width: 140, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.value)
                                        .font(.system(size: 12.2))
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
                        .font(.system(size: 11.5))
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
        let key = "\(profile)|\(term)"
        requestKey = key
        state = .loading
        detail = nil

        Task {
            guard let data = await CLIBridge().deviceDetail(profile: profile, deviceID: term) else {
                if requestKey == key {
                    state = .unavailable("jamf-cli could not resolve \(term). Check the identifier or run `jamf-cli pro device \(term)` in a terminal for the underlying error.")
                }
                return
            }
            do {
                let decoded = try DeviceDetail.decode(from: data, lookupID: term)
                if requestKey == key {
                    detail = decoded
                    state = .loaded
                }
            } catch {
                if requestKey == key {
                    state = .unavailable("Could not decode jamf-cli response for \(term).")
                }
            }
        }
    }

    private var trimmedTerm: String {
        searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detailTitle(_ detail: DeviceDetail) -> String {
        let candidates = ["name", "computer name", "device name", "host name", "hostname"]
        for section in detail.sections {
            for item in section.items where candidates.contains(item.label.lowercased()) {
                if !item.value.isEmpty { return item.value }
            }
        }
        return detail.lookupID
    }

    private func computerConsoleURL(for detail: DeviceDetail) -> URL? {
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
