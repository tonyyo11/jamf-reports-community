import Foundation

/// jamf-cli's `dashboard` (1.31.0+): one self-contained HTML page of fleet-wide
/// aggregates across Jamf Pro, the Jamf Platform API, Jamf Protect and Jamf
/// Security Cloud, with no device names, serials or usernames in it. `collect`
/// saves it as a dated `.html` snapshot, and the HTML report embeds the newest one,
/// so generating a report still never reaches the network.
///
/// The page goes to `--out-file`. `--output json` does not change the page: it makes
/// the error envelope jamf-cli prints on stdout JSON, which is what
/// `recordUnlandedAttempt` classifies and what names a partial run's missing sections.
extension ReportEngine {

    /// Snapshot kind and directory name. The only kind saved as `.html`.
    static let dashboardKind = "dashboard"

    /// The matrix row's argv plus the Protect profile, when Protect is on and has
    /// a profile of its own. jamf-cli refuses two profiles of one product (a Pro and
    /// a Platform profile count as one), so Protect is the only one ever added.
    /// Passed as `--include-profile=<name>` so a name can never read as a flag.
    static func dashboardArguments(
        base: [String], profile: String, protect: ProtectConfig?
    ) -> [String] {
        guard let protect, protect.isEnabled else { return base }
        let other = protect.resolvedProfile
        guard !other.isEmpty, other != profile, !other.hasPrefix("-") else { return base }
        return base + ["--include-profile=\(other)"]
    }

    /// Whether `data` starts like an HTML document, after whitespace and a byte-order
    /// mark. jamf-cli creates the `--out-file` before it signs in, so an early
    /// failure leaves it empty; that must not land as a snapshot.
    static func isHTMLDocument(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\u{FEFF}")))
            .lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    /// One dashboard run's result: nil `capture` when the process never launched.
    struct DashboardAttempt: Sendable {
        let capture: (exitCode: Int32, stdout: Data)?
        let page: Data
        let sawForbidden: Bool

        /// jamf-cli stopped before collecting anything: an unknown profile, missing
        /// credentials or a product clash exits 1 or 2 and leaves the page empty.
        var stoppedBeforeCollecting: Bool {
            guard let exitCode = capture?.exitCode else { return false }
            return page.isEmpty && (exitCode == 1 || exitCode == CLIBridge.exitCodeUsage)
        }
    }

    /// One dashboard collect: run it into a staging file, then save the page through
    /// `saveSnapshot` so the manifest, retention and the freshness counters treat it
    /// like any other kind. A failure is classified and counted by
    /// `recordUnlandedAttempt` from the envelope jamf-cli printed on stdout.
    ///
    /// When the Protect profile stops the run before it starts (see
    /// `DashboardAttempt.stoppedBeforeCollecting`), it runs once more without Protect,
    /// so a broken Protect setup costs the dashboard its Protect card, not the page.
    ///
    /// Exit 7 means some sections failed and the rest were written, with a banner in
    /// the page naming the missing ones. That lands, with a warning rather than a
    /// `[partial]` line: the page says what is missing, and a same-day retry would
    /// find the kind not due.
    static func collectDashboard(
        profile: String,
        arguments: [String],
        supportsQuietFlags: Bool,
        bin: URL,
        bridge: CLIBridge,
        dataDir: URL,
        recordManifest: Bool,
        useCachedData: Bool,
        stateStore: StateFileStore?,
        collectStart: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> KindCollectResult {
        let kind = dashboardKind
        onLine(.init(timestamp: Date(), level: .info,
                     text: "[info] collecting \(kind) for \(profile)"))
        var attempt = await runDashboard(
            arguments: arguments, supportsQuietFlags: supportsQuietFlags,
            bin: bin, bridge: bridge, onLine: onLine)
        if attempt.stoppedBeforeCollecting,
           let protectArgument = arguments.first(where: { $0.hasPrefix("--include-profile=") }) {
            let code = attempt.capture.map { String($0.exitCode) } ?? "?"
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] \(kind): jamf-cli stopped with the Protect profile "
                            + "included (exit \(code)); collecting without it"))
            attempt = await runDashboard(
                arguments: arguments.filter { $0 != protectArgument },
                supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge, onLine: onLine)
        }

        guard let (exitCode, stdout) = attempt.capture else {
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
            return KindCollectResult(
                outcome: CollectOutcome(kind: kind, exitCode: Self.launchFailureExitCode),
                saved: false
            )
        }
        let isPartialFailure = exitCode == CLIBridge.exitCodePartialFailure
        guard exitCode == 0 || isPartialFailure, isHTMLDocument(attempt.page) else {
            return try Self.recordUnlandedAttempt(
                kind: kind, exitCode: exitCode, data: stdout,
                sawForbidden: attempt.sawForbidden,
                useCachedData: useCachedData, dataDir: dataDir,
                stateStore: stateStore, collectStart: collectStart, onLine: onLine
            )
        }
        do {
            try saveSnapshot(
                data: attempt.page, kind: kind, dataDir: dataDir, fileExtension: "html",
                recordManifest: recordManifest, onLine: onLine
            )
        } catch {
            stateStore?.record(.failed(exitCode: exitCode), report: kind, at: collectStart)
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[fail] \(kind): snapshot could not be written — "
                            + error.localizedDescription))
            throw error
        }
        stateStore?.record(.landed, report: kind, at: collectStart)
        if isPartialFailure {
            let reason = Self.jamfCLIErrorMessage(in: stdout)
                ?? "some sections could not be collected"
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] \(kind): exit 7 — \(reason); the page names them"))
        } else {
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] \(kind): \(attempt.page.count) bytes"))
        }
        return KindCollectResult(
            outcome: CollectOutcome(kind: kind, exitCode: exitCode), saved: true)
    }

    /// Runs the dashboard into its own staging file (and `invokeWithRetry`'s one retry
    /// into the same file, emptied first), then reads the page back and removes it.
    private static func runDashboard(
        arguments: [String],
        supportsQuietFlags: Bool,
        bin: URL,
        bridge: CLIBridge,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> DashboardAttempt {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-dashboard-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: staging) }
        let stderrWatcher = StderrSignalWatcher()
        let capture = await Self.invokeWithRetry(
            kind: dashboardKind, arguments: arguments + ["--out-file", staging.path],
            supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge,
            onLine: stderrWatcher.forwarding(to: onLine),
            beforeRetry: {
                stderrWatcher.reset()
                try? FileManager.default.removeItem(at: staging)
            }
        )
        return DashboardAttempt(
            capture: capture.map { (exitCode: $0.0, stdout: $0.1) },
            page: (try? Data(contentsOf: staging)) ?? Data(),
            sawForbidden: stderrWatcher.sawForbidden
        )
    }
}
