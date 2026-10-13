import AppKit
import SwiftUI
import TipKit

struct SourcesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var csvFiles: [InboxFile] = []
    @State private var families: [SnapshotFamily] = []
    @State private var inboxWatcher = CSVInboxService.DirectoryWatcher()
    @State private var pendingClearFile: InboxFile?
    @State private var pendingClearProfile: String?
    @State private var showClearConfirm = false
    @State private var clearError: String?
    @State private var showClearError = false
    @State private var resolutionError: String?
    @State private var showElevateScopeConfirm = false
    @State private var pendingScopeProfile: String?
    @State private var scopeRefreshTrigger = 0
    @State private var capabilitySnapshot: CLICapabilitySnapshot?
    @State private var capabilityService: CapabilityService?
    @State private var doctorOutcome: CLIDoctorService.Outcome?
    @State private var doctorRunning = false
    @State private var cliBridge = CLIBridge()
    @State private var showingProtectConnect = false
    @State private var connectedProducts = ConnectedProducts.none
    @State private var cliProfileNames: [String]?
    @State private var showingEAWalkthrough = false
    @State private var showingReauth = false
    @State private var sourcesPlan: CollectSourcesPlan?
    /// Newest snapshot per kind, read off the main actor when the plan is built.
    @State private var cachedAt: [String: Date] = [:]
    @State private var expandedProducts: Set<CollectSourcesPlan.Product> = []

    private var isSchoolWorkspace: Bool {
        sourcesPlan?.sources.first?.product == .school
    }

    /// The plan's commands that run, and of those the ones with a snapshot.
    private var runningSources: [CollectSourcesPlan.Source] {
        sourcesPlan?.sources.filter { $0.skipReason == nil } ?? []
    }

    private var cachedSourceCount: Int {
        runningSources.filter { cachedAt[$0.kind] != nil }.count
    }

    var body: some View {
        PageScaffold(spacing: 14) {
            header

            if let error = resolutionError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.danger)
                    Text(error)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Colors.danger)
                    Spacer()
                }
                .padding(12)
                .background(Theme.Colors.danger.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(alignment: .top, spacing: 14) {
                cliCard
                csvCard
            }
            doctorCard
            ConnectionCard()
            // Both are Jamf Pro: the matrix lists `pro` commands, and a School workspace never
            // collects Protect (`ProfileProductType.detect`).
            if !isSchoolWorkspace { capabilityCard }
            familiesCard
            if !isSchoolWorkspace { additionalProductsCard }
        }
        .sheet(isPresented: $showingProtectConnect, onDismiss: reloadConnectedProducts) {
            ProductConnectSheetView(profileSlug: workspace.profile)
        }
        .sheet(isPresented: $showingEAWalkthrough) {
            CSVEAWalkthroughSheet(profile: workspace.profile)
        }
        .sheet(isPresented: $showingReauth) {
            ReauthenticateSheet(
                profileSlug: workspace.profile,
                prefillURL: activeProfileServerURL,
                prefillAuthMethod: activeProfileAuthMethod,
                onSaved: { runDoctor() }
            )
        }
        .onAppear {
            reload()
            startInboxWatcher()
            reloadCapabilities()
        }
        .onChange(of: workspace.profile) { _, _ in
            pendingClearFile = nil
            pendingClearProfile = nil
            showClearConfirm = false
            doctorOutcome = nil
            doctorRunning = false
            reload()
            startInboxWatcher()
            reloadCapabilities()
        }
        .onDisappear {
            inboxWatcher.stop()
        }
        .confirmationDialog(
            "Clear \"\(pendingClearFile?.name ?? "")\"?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear inbox file", role: .destructive) {
                clearPendingFile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the CSV file from disk.")
        }
        .alert("CSV Inbox Error", isPresented: $showClearError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(clearError ?? "Unknown error")
        }
        .confirmationDialog(
            "Elevate \"\(pendingScopeProfile ?? "")\" to Full Admin?",
            isPresented: $showElevateScopeConfirm,
            titleVisibility: .visible
        ) {
            Button("Elevate to Full Admin", role: .destructive) {
                if let target = pendingScopeProfile {
                    ProfileService.setScope(.fullAdmin, for: target)
                    scopeRefreshTrigger &+= 1
                }
                pendingScopeProfile = nil
            }
            Button("Cancel", role: .cancel) {
                pendingScopeProfile = nil
            }
        } message: {
            Text(Self.scopeExplanation(.fullAdmin))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: "Inputs to the workbook", tone: .gold)
            Text("Data Sources")
                .font(Theme.Fonts.serif(26, weight: .bold))
                .foregroundStyle(Theme.Text.primary)
            Text("Live API · cached snapshots · CSV inboxes · historical archives")
                .font(.footnote)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
    }

    private var cliCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.Colors.gold)
                        .font(.system(size: 16))
                    SectionHeader(title: "jamf-cli · live")
                    Spacer()
                    Pill(
                        text: cachedSourceCount == 0
                            ? "No cache"
                            : "\(cachedSourceCount) cached",
                        tone: cachedSourceCount == 0 ? .muted : .teal
                    )
                }
                // One line when it fits; otherwise the cache path takes its own line
                // rather than wrapping every word into a narrow column.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        cliProfileLine(label: "jamf-cli profile")
                        Text("·")
                        cliCacheLine
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        // The card title already says jamf-cli; drop it before the
                        // profile name has to truncate.
                        ViewThatFits(in: .horizontal) {
                            cliProfileLine(label: "jamf-cli profile")
                            cliProfileLine(label: "profile")
                        }
                        cliCacheLine
                    }
                }
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.Text.tertiary(contrast))
                scopeCaption

                sourcesList
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// What a full collect runs for this workspace, a group per product, from the same lists
    /// the collects run (`CollectSourcesPlan`).
    @ViewBuilder
    private var sourcesList: some View {
        if let plan = sourcesPlan {
            Text("What a full collect runs for this workspace.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(CollectSourcesPlan.Product.allCases, id: \.self) { product in
                    let sources = plan.sources(for: product)
                    if !sources.isEmpty { sourceGroup(product, sources) }
                }
            }
        } else {
            Text("Reading what this workspace collects…")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
        }
    }

    private func sourceGroup(
        _ product: CollectSourcesPlan.Product, _ sources: [CollectSourcesPlan.Source]
    ) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedProducts.contains(product) },
            set: { open in
                if open { expandedProducts.insert(product) } else { expandedProducts.remove(product) }
            }
        )) {
            VStack(spacing: 0) {
                ForEach(sources) { source in
                    sourceRow(source)
                    if source.id != sources.last?.id {
                        Divider().background(Theme.Hairline.standard)
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(product.rawValue)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                Spacer()
                Text(Self.groupSummary(sources, cachedAt: cachedAt))
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
    }

    private func sourceRow(_ source: CollectSourcesPlan.Source) -> some View {
        // The label wraps at its full height: truncated, it still reserved the wrapped
        // height below the cards row.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Mono(text: source.command,
                 color: source.skipReason == nil ? Theme.Text.secondary
                    : Theme.Text.tertiary(contrast))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.sourceStatus(source, cachedAt: cachedAt[source.kind]))
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    /// "12 run · 10 cached · 4 skipped", each part only when it is not zero.
    nonisolated static func groupSummary(
        _ sources: [CollectSourcesPlan.Source], cachedAt: [String: Date]
    ) -> String {
        let running = sources.filter { $0.skipReason == nil }
        let cached = running.filter { cachedAt[$0.kind] != nil }.count
        let skipped = sources.count - running.count
        var parts = ["\(running.count) run"]
        if cached > 0 { parts.append("\(cached) cached") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    nonisolated static func sourceStatus(
        _ source: CollectSourcesPlan.Source, cachedAt: Date?
    ) -> String {
        if let reason = source.skipReason { return "skipped: \(reason)" }
        guard let cachedAt else { return "not cached" }
        return "cached \(FileDisplay.date(cachedAt))"
    }

    private func cliProfileLine(label: String) -> some View {
        HStack(spacing: 4) {
            Text(label).fixedSize()
            Text(workspace.profile)
                .foregroundStyle(Theme.Colors.goldBright)
                .lineLimit(1)
                .truncationMode(.middle)
            scopeChip(for: workspace.profile)
                .disabled(workspace.demoMode)
        }
    }

    /// Says what the Limited / Full Admin chip beside the profile name means, so the badge
    /// does not stand unexplained.
    @ViewBuilder
    private var scopeCaption: some View {
        let _ = scopeRefreshTrigger
        let scope: APIScope = workspace.demoMode
            ? .limited : ProfileService.scope(for: workspace.profile)
        Text(Self.scopeExplanation(scope))
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary(contrast))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `ProfileService.scope(for:)` is read only by this screen: nothing in the app checks it
    /// before running an operation, and it never reaches jamf-cli, so it cannot widen or
    /// narrow the API client's rights. The text says so rather than promising a gate.
    static func scopeExplanation(_ scope: APIScope) -> String {
        "\(scope.displayName) is a label kept on this Mac for this profile. It does not change "
            + "what the jamf-cli credentials can do, and nothing in the app is gated on it yet."
    }

    private var cliCacheLine: some View {
        HStack(spacing: 4) {
            Text("cache").fixedSize()
            Text(cliCacheDisplayPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(cliCacheDisplayPath)
        }
    }

    private var csvCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.Colors.tealBright)
                        .font(.system(size: 16))
                    SectionHeader(title: "CSV Inbox")
                    Spacer()
                    Pill(text: "\(csvFiles.count) FILES", tone: .muted)
                }
                // One line, shortened in the middle: a path has no spaces to wrap at, so it
                // broke wherever the card ran out of width.
                Mono(text: workspaceDisplayPath(subpath: "csv-inbox") + "/")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workspaceDisplayPath(subpath: "csv-inbox") + "/")

                if csvFiles.isEmpty {
                    emptyCSVState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(csvFiles.enumerated()), id: \.element.id) { idx, f in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(
                                        f.status == .pending
                                            ? Theme.Colors.gold
                                            : Theme.Text.tertiary(contrast)
                                    )
                                    .font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 1) {
                                    Mono(text: f.name, color: Theme.Text.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(f.name)
                                    Mono(
                                        text: "\(FileDisplay.date(f.mtime)) · \(f.size)",
                                        size: 10.5
                                    )
                                    .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Pill(text: f.status.rawValue, tone: tone(for: f.status))
                                Menu {
                                    if f.status != .archived {
                                        Button {
                                            archiveInboxFile(f)
                                        } label: {
                                            Label("Archive", systemImage: "archivebox")
                                        }
                                    }
                                    Button(role: .destructive) {
                                        pendingClearFile = f
                                        pendingClearProfile = workspace.profile
                                        showClearConfirm = true
                                    } label: {
                                        Label("Clear inbox file", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(Theme.Text.tertiary(contrast))
                                        .font(.system(size: 14))
                                }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                                .disabled(workspace.demoMode)
                                .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
                                .accessibilityLabel("Actions for \(f.name)")
                            }
                            .padding(.vertical, 8)
                            if idx < csvFiles.count - 1 {
                                Divider().background(Theme.Hairline.standard)
                            }
                        }
                    }
                }

                if !csvFiles.isEmpty {
                    Text(CSVInboxService.statusCaption)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    PNPButton(title: "Open in Finder", icon: "folder", size: .sm) {
                        guard !workspace.demoMode else { return }
                        let url = (ProfileService.workspaceURL(for: workspace.profile)
                                    ?? WorkspaceRootStore.defaultRoot)
                            .appendingPathComponent("csv-inbox", isDirectory: true)
                        SystemActions.openFolder(url)
                    }
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode
                          ? DemoData.liveOnlyHelp
                          : "Open the csv-inbox folder where you drop fresh CSV exports.")
                    // Reads the real inbox's newest CSV and writes config.yaml.
                    PNPButton(
                        title: "EA tracking guide",
                        icon: "tablecells.badge.ellipsis",
                        style: .ghost,
                        size: .sm
                    ) {
                        guard !workspace.demoMode else { return }
                        showingEAWalkthrough = true
                    }
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode
                          ? DemoData.liveOnlyHelp
                          : "Detect Extension Attribute columns in your newest CSV and adopt "
                              + "them into config.yaml.")
                }
                .padding(.top, 4)
                TipView(SourcesTips.eaTracking)
                    .frame(maxWidth: 460, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Capability matrix

    /// Connection health card. On-demand `jamf-cli doctor` health probe: profile
    /// resolution, credential state, and a live HEAD reachability check of the
    /// configured server. Runs only when the user clicks — it makes a network
    /// call, unlike the local `pro --help` capability probe.
    private var doctorCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "stethoscope")
                        .foregroundStyle(Theme.Colors.tealBright)
                        .font(.system(size: 16))
                    SectionHeader(title: "jamf-cli · connection health")
                    Spacer()
                    if doctorRunning {
                        Pill(text: "probing…", tone: .muted)
                    } else if case .report(let r) = doctorOutcome {
                        let v = Self.healthPill(r.health)
                        Pill(text: v.label, tone: v.tone, icon: v.icon)
                    }
                    // Demo mode: the sheet would register a real jamf-cli profile
                    // under the demo's name, and the check runs `jamf-cli doctor`.
                    Button("Update credentials\u{2026}") {
                        guard !workspace.demoMode else { return }
                        showingReauth = true
                    }
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode
                          ? DemoData.liveOnlyHelp
                          : "Re-register this profile's jamf-cli credentials (URL, client ID, "
                              + "and secret) without leaving the app.")
                    Button(doctorOutcome == nil ? "Check connection" : "Re-check") {
                        runDoctor()
                    }
                    .disabled(doctorRunning || workspace.demoMode)
                    .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
                }
                TipView(SourcesTips.connectionHealth)
                    .frame(maxWidth: 460, alignment: .leading)

                doctorBody
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var doctorBody: some View {
        switch doctorOutcome {
        case .none:
            Text("Run a live diagnosis of the active profile's credentials and "
                + "server reachability — useful when a collect returns 401 or no data.")
                .font(.caption)
                .foregroundStyle(Theme.Text.tertiary(contrast))
                .padding(.vertical, 6)
        case .notInstalled:
            doctorMessageRow(
                "jamf-cli is not installed — install it via Homebrew or from the jamf-cli "
                    + "GitHub releases page, then click Re-check above.",
                tone: .warn)
        case .failed(let reason):
            doctorMessageRow(reason, tone: .danger)
        case .report(let report):
            doctorReportRows(report)
        }
    }

    @ViewBuilder
    private func doctorMessageRow(_ text: String, tone: Pill.Tone) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .danger
                ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                .foregroundStyle(tone == .danger ? Theme.Colors.danger : Theme.Colors.gold)
            Text(text).font(.caption).foregroundStyle(Theme.Text.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func doctorReportRows(_ report: CLIDoctorReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            doctorRow("Profile", report.profile?.name ?? "—")
            doctorRow("Server", report.profile?.effectiveUrl ?? report.profile?.url ?? "—")
            doctorRow("Auth method", report.profile?.authMethod ?? "—")
            doctorRow("Credentials", Self.credentialSummary(report))
            doctorRow("Connectivity", Self.connectivitySummary(report.connectivity))

            if Self.healthNeedsCredentials(report.health) {
                HStack(spacing: 8) {
                    Image(systemName: "key.slash")
                        .foregroundStyle(Theme.Colors.gold)
                    Text("This profile's credentials need attention.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                    Spacer()
                    PNPButton(title: "Update credentials\u{2026}", icon: "key.horizontal", size: .sm) {
                        showingReauth = true
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    /// Health verdicts where re-registering credentials is the likely remedy.
    static func healthNeedsCredentials(_ health: CLIDoctorReport.Health) -> Bool {
        switch health {
        case .credentialsUnresolved, .unauthorized, .noProfile:
            return true
        case .healthy, .unreachable:
            return false
        }
    }

    /// The active profile's recorded server URL, for prefilling the reauth sheet.
    private var activeProfileServerURL: String {
        workspace.profiles.first(where: { $0.name == workspace.profile })?.url ?? ""
    }

    /// The active profile's recorded auth method, for selecting the reauth form.
    private var activeProfileAuthMethod: String {
        workspace.profiles.first(where: { $0.name == workspace.profile })?.authMethod ?? ""
    }

    @ViewBuilder
    private func doctorRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.caption).foregroundStyle(Theme.Text.tertiary(contrast))
                Spacer()
                Mono(text: value, color: Theme.Text.secondary)
            }
            .padding(.vertical, 6)
            Divider().background(Theme.Hairline.standard)
        }
    }

    /// Maps the health verdict to a UI label/tone/icon. Static + pure so it can
    /// be reasoned about independently of the view.
    static func healthPill(
        _ health: CLIDoctorReport.Health
    ) -> (label: String, tone: Pill.Tone, icon: String) {
        switch health {
        case .healthy:
            return ("Healthy", .teal, "checkmark.circle.fill")
        case .credentialsUnresolved:
            return ("Credentials unresolved", .warn, "key.slash")
        case .unauthorized:
            return ("Unauthorized", .danger, "lock.trianglebadge.exclamationmark")
        case .unreachable:
            return ("Unreachable", .danger, "wifi.slash")
        case .noProfile:
            return ("No profile", .danger, "questionmark.circle")
        }
    }

    static func credentialSummary(_ report: CLIDoctorReport) -> String {
        let creds = report.profile?.credentials ?? []
        guard !creds.isEmpty else { return "none resolved" }
        let resolved = creds.filter { $0.resolved == true }.count
        return "\(resolved)/\(creds.count) resolved"
    }

    static func connectivitySummary(_ c: CLIDoctorReport.Connectivity?) -> String {
        guard let c, let code = c.statusCode, code > 0 else { return "no response" }
        if let ms = c.latencyMs { return "HTTP \(code) · \(ms)ms" }
        return "HTTP \(code)"
    }

    private func runDoctor() {
        guard !workspace.demoMode else { return }
        doctorRunning = true
        let profile = workspace.profile
        let service = CLIDoctorService(executor: DefaultCLIExecutor(bridge: cliBridge))
        Task {
            let outcome = await service.run(profile: profile)
            // Ignore a result that arrived after the user switched profiles.
            guard profile == workspace.profile else { return }
            doctorOutcome = outcome
            doctorRunning = false
        }
    }

    private var capabilityCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").foregroundStyle(Theme.Colors.tealBright)
                        .font(.system(size: 16))
                    SectionHeader(title: "jamf-cli · command matrix")
                    Spacer()
                    if workspace.demoMode {
                        Pill(text: "demo", tone: .muted)
                    } else if capabilitySnapshot == nil {
                        Pill(text: "probing…", tone: .muted)
                    } else if let ver = capabilitySnapshot?.version {
                        Pill(text: "v\(ver)", tone: .muted)
                    } else if capabilitySnapshot?.availability.isEmpty == true {
                        Pill(text: "not installed", tone: .warn)
                    } else {
                        Pill(text: "version unknown", tone: .muted)
                    }
                }

                if let snap = capabilitySnapshot {
                    VStack(spacing: 0) {
                        let commands = CapabilityService.trackedCommands
                        ForEach(Array(commands.enumerated()), id: \.offset) { idx, cmd in
                            let status = snap.availability[cmd] ?? .blocked
                            HStack {
                                Mono(text: "pro \(cmd)", color: Theme.Text.secondary)
                                Spacer()
                                Pill(
                                    text: status == .available ? "available" : "blocked",
                                    tone: status == .available ? .teal : .warn
                                )
                            }
                            .padding(.vertical, 6)
                            if idx < commands.count - 1 {
                                Divider().background(Theme.Hairline.standard)
                            }
                        }
                    }
                } else {
                    Text("Checking installed commands…")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var familiesCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive").foregroundStyle(Theme.Text.tertiary(contrast))
                        .font(.system(size: 16))
                    SectionHeader(title: "Snapshot Archive Families")
                    Spacer()
                    PNPButton(title: "Open in Finder", icon: "folder", size: .sm) {
                        guard !workspace.demoMode else { return }
                        let url = (try? WorkspacePaths.historicalDir(for: workspace.profile))
                                    ?? (ProfileService.workspaceURL(for: workspace.profile)
                                        ?? WorkspaceRootStore.defaultRoot)
                                        .appendingPathComponent("snapshots", isDirectory: true)
                        SystemActions.openFolder(url)
                    }
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode
                          ? DemoData.liveOnlyHelp
                          : "Open the snapshots directory where dated CSV/JSON archives live.")
                }
                if families.isEmpty {
                    emptyFamiliesState
                } else {
                    Table(families) {
                        TableColumn("Family") { f in
                            Text(f.name)
                                .font(Theme.Fonts.mono(12, weight: .semibold))
                                .foregroundStyle(Theme.Colors.goldBright)
                                .lineLimit(1)
                        }
                        .width(min: 110, ideal: 150, max: 220)
                        TableColumn("Globs") { f in
                            Mono(text: f.glob).lineLimit(1).truncationMode(.middle)
                        }
                        .width(min: 120, ideal: 170, max: 260)
                        TableColumn("Snapshots") { f in Mono(text: "\(f.snapshotCount)") }
                            .width(min: 70, ideal: 80, max: 96)
                        TableColumn("Latest") { f in
                            Mono(text: f.latestDate.map(FileDisplay.date) ?? "—")
                        }
                        .width(min: 96, ideal: 110, max: 140)
                        TableColumn("Storage") { f in Mono(text: FileDisplay.size(f.totalBytes)) }
                            .width(min: 64, ideal: 76, max: 96)
                        // The one flexible column, so the row's width is always filled and
                        // never overruns into a horizontal scroll bar.
                        TableColumn("Used By") { f in
                            Text(f.usedBy.isEmpty ? "—" : f.usedBy)
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .width(min: 120)
                    }
                    // Sized to the actual rows — a tall fixed frame renders
                    // empty filler rows that read as missing data.
                    .frame(height: min(CGFloat(families.count) * 28 + 34, 200))
                    .scrollContentBackground(.hidden)
                    Text("Families appear as snapshot types are archived: summaries "
                        + "(daily trend data: a day's first collect writes it, and each later "
                        + "collect that fetches new data rebuilds it) plus dated computers, "
                        + "mobile, compliance, and patching archives created when CSV exports "
                        + "are snapshotted. A jamf-cli-only workspace typically shows only "
                        + "summaries.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyCSVState: some View {
        EmptyStateView(
            systemImage: "tablecells.badge.ellipsis",
            title: "No CSV files in the inbox.",
            message: "Drop Jamf Pro exports here before running a CSV-assisted report. "
                + "Add your Extension Attribute columns to the export to track them.",
            // The walkthrough reads the real inbox and writes config.yaml.
            primaryAction: workspace.demoMode ? nil : EmptyStateAction(
                label: "Set up EA tracking",
                icon: "tablecells.badge.ellipsis",
                action: { showingEAWalkthrough = true }
            )
        )
        .padding(.vertical, 10)
    }

    private var emptyFamiliesState: some View {
        EmptyStateView(
            systemImage: "archivebox",
            title: "No snapshot families yet",
            message: "Families appear after collection or CSV archival runs: "
                + "summaries (written by a collect that fetches data), plus dated computers, "
                + "mobile, compliance, and patching archives."
        )
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.vertical, 8)
    }

    private func reload() {
        guard !workspace.demoMode else {
            // The demo workspace, never this Mac's: no folder is read.
            csvFiles = DemoData.inboxFiles(for: workspace.profile)
            families = DemoData.snapshotFamilies(for: workspace.profile)
            connectedProducts = .none
            sourcesPlan = CollectSourcesPlan.build(.init(
                product: .jamfPro, profile: workspace.profile,
                protectProfile: DemoData.org.profile + "-protect"))
            cachedAt = Dictionary(uniqueKeysWithValues: (sourcesPlan?.sources ?? []).compactMap {
                source in DemoData.cacheDate(for: [source.kind], profile: workspace.profile)
                    .map { (source.kind, $0) }
            })
            resolutionError = nil
            return
        }
        reloadConnectedProducts()
        reloadSourcesPlan()
        csvFiles = CSVInboxService().list(profile: workspace.profile)
        families = SnapshotArchiveService().families(profile: workspace.profile)

        do {
            _ = try WorkspacePaths.dataDir(for: workspace.profile)
            _ = try WorkspacePaths.historicalDir(for: workspace.profile)
            _ = try WorkspacePaths.outputDir(for: workspace.profile)
            resolutionError = nil
        } catch {
            let rootPath = WorkspaceRootStore.displayPath(profile: workspace.profile)
            resolutionError = "Couldn't resolve this profile's workspace folders: "
                + "\(error.localizedDescription). Check the profile name and that "
                + "\(rootPath) exists and is writable."
        }
    }

    private func reloadConnectedProducts() {
        connectedProducts = workspace.demoMode
            ? .none : ConnectedProducts.read(profile: workspace.profile)
        guard let named = connectedProducts.protectProfile else {
            cliProfileNames = nil
            return
        }
        // `workspace.profiles` leaves out a profile that only serves as Protect's login, so
        // jamf-cli's own list is the answer. Read off the main actor: it runs `config list`.
        let profile = workspace.profile
        Task {
            let names = await Task.detached {
                ProfileService.discoverJamfCLIProfiles(scheduleCounts: [:]).map(\.name)
            }.value
            guard profile == workspace.profile,
                  connectedProducts.protectProfile == named else { return }
            cliProfileNames = names
        }
    }

    /// Builds the plan and reads each kind's newest snapshot off the main actor: resolving the
    /// auth method runs `jamf-cli config list` (cached per profile), and the snapshot folders
    /// may sit on a synced share.
    private func reloadSourcesPlan() {
        let profile = workspace.profile
        let version = workspace.jamfCLIVersion
        let skipExpensive = UserDefaults.standard.bool(forKey: "skipExpensiveCollections")
        Task {
            let (plan, dates) = await Task.detached(priority: .userInitiated) {
                let config = ProfileService.workspaceURL(for: profile).flatMap {
                    try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
                }
                let detected = ProfileProductType.detect(from: config, profile: profile)
                let auth = detected.type == .jamfPro
                    ? ProfileAuthMethod.resolve(profile: profile) : nil
                let plan = CollectSourcesPlan.build(.init(
                    product: detected.type, profile: profile,
                    protectProfile: ConnectedProducts.read(profile: profile).protectProfile,
                    staleDays: config?.thresholds?.resolvedStaleDays ?? 30,
                    installedVersion: version, skipExpensive: skipExpensive,
                    authMethod: auth?.authMethod, tenantLevel: auth?.isTenantLevel == true,
                    collectSkip: ReportEngine.collectSkipKinds(config?.jamfCli?.collectSkip)))
                return (plan, Self.newestSnapshots(
                    kinds: plan.sources.map(\.kind), profile: profile))
            }.value
            guard profile == workspace.profile, !workspace.demoMode else { return }
            sourcesPlan = plan
            cachedAt = dates
        }
    }

    private func clearPendingFile() {
        guard !workspace.demoMode else { return }
        guard let file = pendingClearFile,
              let profile = pendingClearProfile else {
            return
        }

        do {
            try CSVInboxService().clear(file, profile: profile)
            pendingClearFile = nil
            pendingClearProfile = nil
            if profile == workspace.profile {
                reload()
            }
        } catch {
            clearError = "Couldn't remove the inbox file: \(error.localizedDescription). "
                + "It may be open in another app or read-only."
            showClearError = true
        }
    }

    private func archiveInboxFile(_ file: InboxFile) {
        guard !workspace.demoMode else { return }
        let profile = workspace.profile
        do {
            try CSVInboxService().archive(file, profile: profile)
            reload()
        } catch {
            clearError = "Couldn't archive the inbox file: \(error.localizedDescription)"
            showClearError = true
        }
    }

    /// Watch the profile's csv-inbox for dropped exports. Demo mode watches
    /// nothing: its inbox is fixed.
    private func startInboxWatcher() {
        guard !workspace.demoMode else {
            inboxWatcher.stop()
            return
        }
        inboxWatcher.start(profile: workspace.profile) {
            reload()
        }
    }

    private func reloadCapabilities() {
        guard !workspace.demoMode else {
            // The probe runs this Mac's jamf-cli, which demo mode never does.
            capabilityService = nil
            capabilitySnapshot = DemoData.jamfCLICapabilities
            return
        }
        capabilitySnapshot = nil
        let executor = DefaultCLIExecutor(bridge: cliBridge)
        let service = CapabilityService(executor: executor)
        capabilityService = service
        Task {
            capabilitySnapshot = await service.snapshot()
        }
    }

    /// Interactive scope chip. Limited↔Full Admin via Menu; elevation to
    /// Full Admin requires explicit confirmation since it gates destructive
    /// operations on the live tenant.
    @ViewBuilder
    private func scopeChip(for profile: String) -> some View {
        let _ = scopeRefreshTrigger
        // The scope is an app-wide preference keyed by profile name; a demo
        // profile shows the default and never sets one.
        let scope: APIScope = workspace.demoMode ? .limited : ProfileService.scope(for: profile)
        Menu {
            Button {
                if scope != .limited, !workspace.demoMode {
                    ProfileService.setScope(.limited, for: profile)
                    scopeRefreshTrigger &+= 1
                }
            } label: {
                Label(
                    APIScope.limited.displayName,
                    systemImage: scope == .limited ? "checkmark" : ""
                )
            }
            Button {
                if scope != .fullAdmin, !workspace.demoMode {
                    pendingScopeProfile = profile
                    showElevateScopeConfirm = true
                }
            } label: {
                Label(
                    APIScope.fullAdmin.displayName,
                    systemImage: scope == .fullAdmin ? "checkmark" : ""
                )
            }
        } label: {
            Pill(
                text: scope.displayName,
                tone: scope == .fullAdmin ? .warn : .muted,
                icon: "chevron.down"
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(scopeHelp(scope))
    }

    private func scopeHelp(_ scope: APIScope) -> String {
        if workspace.demoMode { return DemoData.liveOnlyHelp }
        return Self.scopeExplanation(scope) + " Click to change."
    }

    private func tone(for status: InboxFileStatus) -> Pill.Tone {
        switch status {
        case .pending: .gold
        case .consumed: .teal
        case .archived: .muted
        }
    }

    /// Older builds wrote these kinds under other folder names; their snapshots still count.
    private nonisolated static let legacyCacheNames: [String: [String]] = [
        "computers": ["computers-list", "computers_list"],
        "ea-results": ["ea_results"], "patch-status": ["patch_status"],
        "app-status": ["app_status"], "update-status": ["update_status"],
        "protect-overview": ["protect_overview"],
    ]

    /// The newest snapshot date of each kind under `profile`'s data folder, read through the
    /// workspace path guard. A kind with no snapshot is absent.
    nonisolated static func newestSnapshots(kinds: [String], profile: String) -> [String: Date] {
        guard let root = WorkspacePathGuard.root(for: profile) else { return [:] }
        let configured = (try? WorkspacePaths.dataDir(for: profile))
            ?? root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        guard let dataDir = WorkspacePathGuard.validate(configured, under: root) else { return [:] }
        var dates: [String: Date] = [:]
        for kind in kinds {
            let names = [kind] + (legacyCacheNames[kind] ?? [])
            if let newest = names.flatMap({
                cacheDates(for: $0, dataDir: dataDir, root: root)
            }).max() {
                dates[kind] = newest
            }
        }
        return dates
    }

    /// The demo's own workspace path in demo mode, not this Mac's root, which
    /// may have been moved to a team folder.
    private func workspaceDisplayPath(subpath: String) -> String {
        workspace.demoMode
            ? DemoData.workspaceDisplayPath(profile: workspace.profile, subpath: subpath)
            : WorkspaceRootStore.displayPath(profile: workspace.profile, subpath: subpath)
    }

    private var cliCacheDisplayPath: String {
        if workspace.demoMode { return workspaceDisplayPath(subpath: "jamf-cli-data") + "/" }
        guard let root = WorkspacePathGuard.root(for: workspace.profile),
              let dataDir = try? WorkspacePaths.dataDir(for: workspace.profile) else {
            return WorkspaceRootStore.displayPath(profile: workspace.profile,
                                                  subpath: "jamf-cli-data") + "/"
        }
        let rootPath = root.path
        let dataPath = dataDir.path
        if dataPath.hasPrefix(rootPath + "/") {
            let suffix = String(dataPath.dropFirst(rootPath.count + 1))
            return WorkspaceRootStore.displayPath(profile: workspace.profile, subpath: suffix) + "/"
        }
        return dataPath + "/"
    }

    // MARK: - Additional products card

    private var additionalProductsCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.app.fill").foregroundStyle(Theme.Colors.goldBright)
                        .font(.system(size: 16))
                    SectionHeader(title: "Additional Products")
                }
                Text("Connect Jamf Protect to extend report coverage for the active workspace.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)

                // Sets up a real jamf-cli connection and writes config.yaml.
                ProtectProductControl(
                    workspace: workspace.profile,
                    state: ProtectConnection.state(
                        configured: connectedProducts.protectProfile,
                        cliProfiles: cliProfileNames),
                    demoMode: workspace.demoMode,
                    onConnect: { showingProtectConnect = true },
                    onDisconnected: reloadConnectedProducts)

                Text("Jamf School uses its own workspace: choose Add Jamf School workspace in "
                    + "the sidebar's workspace menu.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// JSON snapshots, and the jamf-cli dashboard's page, the one kind saved as HTML.
    private nonisolated static func cacheDates(
        for cacheName: String, dataDir: URL, root: URL
    ) -> [Date] {
        let directory = dataDir.appendingPathComponent(cacheName, isDirectory: true)
        var candidates: [URL] = []
        if let validatedDirectory = WorkspacePathGuard.validate(directory, under: root),
           let files = try? FileManager.default.contentsOfDirectory(
            at: validatedDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
           ) {
            candidates.append(contentsOf: files)
        }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(
                contentsOf: files.filter {
                    $0.lastPathComponent.hasPrefix("\(cacheName)_")
                        && $0.pathExtension.lowercased() == "json"
                }
            )
        }

        return candidates.compactMap { candidate in
            guard ["json", "html"].contains(candidate.pathExtension.lowercased()),
                  !candidate.lastPathComponent.contains(".partial"),
                  let validated = WorkspacePathGuard.validate(candidate, under: root),
                  let values = try? validated.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true else {
                return nil
            }
            return values.contentModificationDate
        }
    }
}
