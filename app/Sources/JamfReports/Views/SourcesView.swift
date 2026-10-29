import AppKit
import SwiftUI
import TipKit

struct SourcesView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var families: [SnapshotFamily] = []
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
    @State private var environment = EnvironmentProfiles.none
    @State private var cliProfileNames: [String]?
    @State private var showingEAWalkthrough = false
    @State private var showingReauth = false
    @State private var sourcesPlan: CollectSourcesPlan?
    /// Newest snapshot per kind, read off the main actor when the plan is built.
    @State private var cachedAt: [String: Date] = [:]
    @State private var expandedProducts: Set<CollectSourcesPlan.Product> = []
    /// A School workspace's own profile from `config list`, for the Platform API row.
    @State private var schoolResolved: ProfileAuthMethod.Resolved?
    @State private var schoolPlatformCheck: SchoolPlatformCheck.Verdict?
    @State private var reauthOpensPlatform = false

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
                // Jamf School has no Extension Attributes to adopt.
                if !isSchoolWorkspace { eaCard }
            }
            doctorCard
            if isSchoolWorkspace { schoolPlatformCard }
            ConnectionCard()
            // The matrix lists `pro` commands, which a School workspace never runs.
            if !isSchoolWorkspace { capabilityCard }
            familiesCard
            additionalProductsCard
        }
        .sheet(isPresented: $showingProtectConnect, onDismiss: reloadEnvironment) {
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
                isSchool: isSchoolWorkspace,
                schoolPlatform: isSchoolWorkspace ? schoolPlatformRow : nil,
                opensSchoolPlatform: reauthOpensPlatform,
                onSchoolPlatformCheck: { schoolPlatformCheck = $0 },
                onSaved: {
                    workspace.credentialsChanged()
                    runDoctor()
                    reloadSourcesPlan()
                }
            )
        }
        .onAppear {
            reload()
            reloadCapabilities()
        }
        .onChange(of: workspace.profile) { _, _ in
            schoolResolved = nil
            schoolPlatformCheck = nil
            doctorOutcome = nil
            doctorRunning = false
            reload()
            reloadCapabilities()
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
                .font(Theme.Fonts.serifTitle())
                .foregroundStyle(Theme.Text.primary)
                .accessibilityAddTraits(.isHeader)
            Text("Live API · cached snapshots · historical archives")
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
                if product == .platformAPI, isSchoolWorkspace {
                    Text("Experimental: Jamf School blueprints through the Platform API")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
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

    private var eaCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "tablecells.badge.ellipsis")
                        .foregroundStyle(Theme.Colors.tealBright)
                        .font(.system(size: 16))
                    SectionHeader(title: "Extension Attributes")
                }
                Text("Pick the Extension Attributes and security agents collected from Jamf "
                    + "Pro to track in config.yaml. A CSV export can be imported once instead.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                PNPButton(title: "Adopt EAs", icon: "tablecells.badge.ellipsis", size: .sm) {
                    guard !workspace.demoMode else { return }
                    showingEAWalkthrough = true
                }
                .disabled(workspace.demoMode)
                .help(workspace.demoMode
                      ? DemoData.liveOnlyHelp
                      : "Pick collected Extension Attributes (or import a CSV once) to "
                          + "track in config.yaml.")
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
                        reauthOpensPlatform = false
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

            if report.health == .environmentReference {
                doctorMessageRow(Self.environmentReferenceNote, tone: .warn)
            }
            if Self.healthNeedsCredentials(report.health) {
                HStack(spacing: 8) {
                    Image(systemName: "key.slash")
                        .foregroundStyle(Theme.Colors.gold)
                    Text("This profile's credentials need attention.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                    Spacer()
                    PNPButton(title: "Update credentials\u{2026}", icon: "key.horizontal", size: .sm) {
                        reauthOpensPlatform = false
                        showingReauth = true
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    static let environmentReferenceNote =
        "Credential is an environment-variable reference; the app starts jamf-cli with a "
        + "cleaned environment, so it cannot sign in from here. Use a keychain or file "
        + "reference (jamf-cli config add-profile)."

    /// Health verdicts where re-registering credentials is the likely remedy.
    static func healthNeedsCredentials(_ health: CLIDoctorReport.Health) -> Bool {
        switch health {
        case .credentialsUnresolved, .unauthorized, .noProfile, .environmentReference:
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
        workspace.activeCLIProfile?.auth?.rawValue ?? ""
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
        case .environmentReference:
            return ("Environment credential", .warn, "key.slash")
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
                          : "Open the snapshots directory where dated archives live.")
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
                    Text(isSchoolWorkspace
                        ? "Families appear as snapshot types are archived: summaries "
                        + "(daily trend data: a day's first collect writes it, and each later "
                        + "collect that fetches new data rebuilds it) plus dated Jamf School "
                        + "device, group, and user archives."
                        : "Families appear as snapshot types are archived: summaries "
                        + "(daily trend data: a day's first collect writes it, and each later "
                        + "collect that fetches new data rebuilds it) plus dated computers, "
                        + "mobile, compliance, and patching archives. A jamf-cli-only workspace "
                        + "typically shows only summaries.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyFamiliesState: some View {
        EmptyStateView(
            systemImage: "archivebox",
            title: "No snapshot families yet",
            message: "Families appear after collection runs: "
                + "summaries (written by a collect that fetches data), plus dated computers, "
                + "mobile, compliance, and patching archives."
        )
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.vertical, 8)
    }

    private func reload() {
        guard !workspace.demoMode else {
            // The demo workspace, never this Mac's: no folder is read.
            families = DemoData.snapshotFamilies(for: workspace.profile)
            environment = .none
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
        reloadEnvironment()
        reloadSourcesPlan()
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

    private func reloadEnvironment() {
        environment = workspace.demoMode
            ? .none : EnvironmentProfiles.read(workspace: workspace.profile)
        workspace.refreshProtectConnection()
        guard let named = environment.protect else {
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
                  environment.protect == named else { return }
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
            let (plan, dates, school) = await Task.detached(priority: .userInitiated) {
                let config = ProfileService.workspaceURL(for: profile).flatMap {
                    try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
                }
                let detected = ProfileProductType.detect(from: config, profile: profile)
                let auth = ProfileAuthMethod.resolve(profile: profile)
                let protectProfile = EnvironmentProfiles.resolve(
                    config: config, workspace: profile).protect
                let plan = CollectSourcesPlan.build(.init(
                    product: detected.type, profile: profile,
                    protectProfile: protectProfile,
                    protectRefusal: protectProfile.flatMap { name in
                        ProfileAuthMethod.resolve(profile: name)?.protectRefusal(profile: name)
                    },
                    staleDays: config?.thresholds?.resolvedStaleDays ?? 30,
                    installedVersion: version, skipExpensive: skipExpensive,
                    authMethod: auth?.authMethod, tenantLevel: auth?.isTenantLevel == true,
                    hasTenantID: auth?.hasTenantID == true,
                    collectSkip: ReportEngine.collectSkipKinds(config?.jamfCli?.collectSkip)))
                let school = detected.type == .jamfSchool
                    ? ProfileAuthMethod.resolve(profile: profile) : nil
                return (plan, Self.newestSnapshots(
                    kinds: plan.sources.map(\.kind), profile: profile), school)
            }.value
            guard profile == workspace.profile, !workspace.demoMode else { return }
            sourcesPlan = plan
            cachedAt = dates
            schoolResolved = school
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

    // MARK: - Jamf School Platform API

    private var schoolPlatformRow: SchoolPlatformRow {
        .state(resolved: schoolResolved, lastCheck: schoolPlatformCheck)
    }

    /// Opens Update credentials on the School form: `school setup` rebuilds the whole profile,
    /// so the Platform API fields are added there with the Network ID and API key.
    private var schoolPlatformCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(schoolPlatformRow.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(schoolPlatformRow == .rejected
                                         ? Theme.Colors.warn : Theme.Colors.fg)
                    Spacer()
                    PNPButton(title: schoolPlatformRow.actionTitle, icon: "key.horizontal",
                              size: .sm) {
                        guard !workspace.demoMode else { return }
                        reauthOpensPlatform = true
                        showingReauth = true
                    }
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
                }
                Text(SchoolPlatformCheck.experimentalNote)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                if let check = schoolPlatformCheck { SchoolPlatformFields.banner(check) }
            }
        }
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
                if isSchoolWorkspace {
                    Text(Self.schoolProtectNote)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Sets up a real jamf-cli connection and writes config.yaml.
                ProtectProductControl(
                    workspace: workspace.profile,
                    state: ProtectConnection.state(
                        configured: environment.protect,
                        cliProfiles: cliProfileNames),
                    demoMode: workspace.demoMode,
                    onConnect: { showingProtectConnect = true },
                    onDisconnected: reloadEnvironment)

                if !isSchoolWorkspace {
                    Text("Jamf School uses its own workspace: add one with Settings › Add "
                        + "connection.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Jamf Protect on a Jamf School workspace (2.11): collected and reported as on Jamf Pro,
    /// but not backed up, since a School workspace has no backups.
    nonisolated static let schoolProtectNote =
        "Experimental: Jamf Protect with Jamf School. Protect is collected and reported; "
            + "it is not backed up, as a Jamf School workspace has no backups."

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
