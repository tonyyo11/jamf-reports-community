import SwiftUI

/// Merges a Platform API workspace into the current one (P7, R1): pick the source, see what the
/// plan does, merge. The sheet cannot close while the model checks or runs.
struct WorkspaceMergeSheet: View {
    let candidates: [String]
    /// Runs the interrupted merge as soon as the sheet opens (the card's Resume).
    var resumes = false
    /// Called once the merge finished, so the store and the card reload.
    var onFinished: () -> Void
    @State private var model: WorkspaceMergeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        model: WorkspaceMergeModel, candidates: [String], resumes: Bool = false,
        onFinished: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        self.candidates = candidates
        self.resumes = resumes
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Merge another workspace into this one"))
                    .font(Theme.Fonts.serif(22, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .accessibilityAddTraits(.isHeader)
                Text(L("Moves a Platform API workspace's history into \(ConfigSchema.displayText(model.target)) and makes its profile this workspace's Platform API profile."))
                    .font(.callout).foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))
            Divider().background(Theme.Colors.hairlineStrong)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().background(Theme.Colors.hairlineStrong)
            footer.padding(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(Theme.Colors.winBG)
        .interactiveDismissDisabled(model.isBusy)
        .task { if resumes { await model.resume() } }
        .onChange(of: model.phase) { _, phase in
            if case .finished = phase { onFinished() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .choose, .refused:
            chooser
            if case .refused(let text) = model.phase { banner(text, .danger) }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Checking that both workspaces reach the same Jamf Pro…")).font(.callout)
            }
        case .ready(let plan):
            readyBody(plan)
        case .running(let done, let total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text(L("Step \(done) of \(total). Keep this window open."))
                    .font(.callout).foregroundStyle(Theme.Text.secondary)
            }
        case .finished(let folder):
            banner(L("The merge finished."), .info)
            Text(L("The source folder moved to \(Self.full(folder)) and was not deleted."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            banner(text, .danger)
            Text(L("Nothing is lost. Close this sheet and choose Resume on the Environment card to continue."))
                .font(.callout).foregroundStyle(Theme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Workspace to merge")).font(.subheadline.weight(.semibold))
            ForEach(candidates, id: \.self) { name in
                HStack {
                    Text(ConfigSchema.displayText(name)).font(.callout)
                    Spacer(minLength: 0)
                    PNPButton(title: L("Choose"), style: .ghost, size: .sm) {
                        Task { await model.choose(source: name) }
                    }
                }
            }
        }
    }

    private func readyBody(_ plan: WorkspaceMergePlan) -> some View {
        let counts = plan.counts()
        return VStack(alignment: .leading, spacing: 10) {
            Text(L("What the merge does")).font(.subheadline.weight(.semibold))
            ForEach(WorkspaceMergePlan.Area.allCases, id: \.self) { area in
                if let line = counts[area] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(area)).font(.callout.weight(.semibold))
                        Text(Self.phrases(line).joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !plan.differingConfigKeys.isEmpty {
                Text(L("These settings differ, and this workspace's values stay: \(plan.differingConfigKeys.map(Self.full).joined(separator: ", "))"))
                    .font(.caption).foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(plan.outsideSourceFolder, id: \.self) { folder in
                Text(L("\(Self.full(folder)) is read from, not moved."))
                    .font(.caption).foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("The source folder moves to \(Self.full(plan.mergedFolder)) and is never deleted."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch model.phase {
            case .ready:
                PNPButton(title: L("Cancel"), style: .ghost) { dismiss() }
                PNPButton(title: L("Merge"), icon: "arrow.triangle.merge", style: .gold) {
                    Task { await model.merge() }
                }
            case .finished(let folder):
                PNPButton(title: L("Reveal in Finder"), icon: "folder", style: .ghost) {
                    _ = SystemActions.reveal(URL(fileURLWithPath: folder, isDirectory: true))
                }
                PNPButton(title: L("Done"), style: .gold) { dismiss() }
            case .checking, .running:
                EmptyView()
            default:
                PNPButton(title: L("Close"), style: .ghost) { dismiss() }
            }
        }
    }

    private func banner(_ text: String, _ tone: InlineBannerTone) -> some View {
        InlineBanner(
            icon: tone == .danger ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            tone: tone
        ) { Text(text) }
    }

    // MARK: Plan wording

    /// File text without displayText's 60-character cut, which would hide the end of a path.
    private static func full(_ text: String) -> String { ConfigSchema.fullDisplayText(text).text }

    static func title(_ area: WorkspaceMergePlan.Area) -> String {
        switch area {
        case .snapshots: L("Snapshots")
        case .state: L("Collect state")
        case .summaries: L("Daily summaries")
        case .chartHistory: L("Chart history")
        case .sofa: L("macOS update feed")
        case .runHistory: L("Run history")
        case .backups: L("Backups")
        case .reports: L("Reports")
        case .config: L("Settings and schedules")
        }
    }

    /// One phrase per action the area has, in a fixed order.
    static func phrases(_ counts: [String: Int]) -> [String] {
        let order = ["copy", "copyFolder", "skipIdentical", "fillSummary", "replaceState",
                     "archiveSource", "archiveTarget"]
        return order.compactMap { name in
            guard let n = counts[name], n > 0 else { return nil }
            switch name {
            case "copy": return L("\(n) to copy")
            case "copyFolder": return n == 1 ? L("\(n) folder to copy") : L("\(n) folders to copy")
            case "skipIdentical": return L("\(n) already the same")
            case "fillSummary":
                return n == 1 ? L("\(n) summary filled in") : L("\(n) summaries filled in")
            case "replaceState": return L("\(n) replaced by the newer record")
            case "archiveSource":
                return n == 1 ? L("\(n) differing file kept in the archive")
                    : L("\(n) differing files kept in the archive")
            default:
                return n == 1 ? L("\(n) file of this workspace moved to the archive")
                    : L("\(n) files of this workspace moved to the archive")
            }
        }
    }
}

#if DEBUG
@MainActor private func previewModel(_ phase: WorkspaceMergeModel.Phase) -> WorkspaceMergeModel {
    let model = WorkspaceMergeModel(target: "Acme", pending: nil, deps: .init(
        hostVerdict: { _, _ in .same },
        makePlan: { _, _ in throw CancellationError() },
        run: { _, _ in }))
    model.phase = phase
    return model
}

private let previewPlan = WorkspaceMergePlan(
    source: "Acme-Platform", target: "Acme", stamp: "20261105-120000",
    mergedFolder: "/Users/example/Jamf-Reports/_merged/Acme-Platform-20261105-120000",
    steps: [
        .init(area: .snapshots, action: .copy, source: "a", target: "b", archive: nil),
        .init(area: .snapshots, action: .copy, source: "a", target: "b", archive: nil),
        .init(area: .snapshots, action: .skipIdentical, source: "a", target: "b", archive: nil),
        .init(area: .summaries, action: .fillSummary(sourceArchive: "x"), source: "a",
              target: "b", archive: nil),
        .init(area: .runHistory, action: .copy, source: "a", target: "b", archive: nil),
        .init(area: .config, action: .archiveSource, source: "a", target: "b", archive: "c"),
    ],
    differingConfigKeys: ["output", "thresholds"],
    outsideSourceFolder: ["/Volumes/Share/jamf-cli-data"])

#Preview("Merge sheet, ready") {
    WorkspaceMergeSheet(
        model: previewModel(.ready(previewPlan)), candidates: ["Acme-Platform"], onFinished: {})
        .frame(width: PageScaffold<EmptyView>.minSupportedWidth, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("Merge sheet, refused") {
    WorkspaceMergeSheet(
        model: previewModel(.refused(
            "Acme-Platform reaches other.example.com, not this workspace's Jamf Pro (acme.example.com). Nothing was changed.")),
        candidates: ["Acme-Platform", "Beta-Platform"], onFinished: {})
        .frame(width: PageScaffold<EmptyView>.minSupportedWidth, height: 440)
        .preferredColorScheme(.dark)
}
#endif
