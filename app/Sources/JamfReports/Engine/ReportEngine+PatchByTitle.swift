import Foundation

/// `patch-status` collected one title at a time, for a server that cannot answer the patch
/// report. `pro report patch-status` asks Jamf Pro for every patch title configuration in one
/// paged list; on a large server that list never answers, at any page size (a 5,900-Mac fleet,
/// 2.12.0-rc1). The Classic title list and the per-title summary are separate, small requests
/// that return the same ids and the same counts, so the snapshot keeps its shape.
extension ReportEngine {

    /// How long the app goes straight to titles after the report timed out, before it gives the
    /// report another try.
    static let patchByTitlePeriod: TimeInterval = 7 * 86_400
    static let patchByTitleConcurrency = 4

    static func patchTitleListArguments(profile: String) -> [String] {
        ["-p", profile, "pro", "classic-patch-titles", "list", "--output", "json"]
    }

    static func patchSummaryArguments(profile: String, titleId: String) -> [String] {
        ["-p", profile, "pro", "patch-software-title-configurations", "patch-summary", titleId,
         "--output", "json"]
    }

    /// One `patch-status` row from a `patch-summary` object; nil when the counts are missing.
    /// The share is rounded as the report rounds it (2 of 3 is "67%"); no devices is "N/A".
    static func patchStatusRow(id: String, summary: [String: Any]) -> [String: Any]? {
        guard let upToDate = summary["upToDate"] as? Int, let outOfDate = summary["outOfDate"] as? Int,
              (0...SummaryJSONParser.maxSummaryNumber).contains(upToDate),
              (0...SummaryJSONParser.maxSummaryNumber).contains(outOfDate) else { return nil }
        let total = upToDate + outOfDate
        let share = total > 0
            ? "\(Int((Double(upToDate) * 100 / Double(total)).rounded()))%" : "N/A"
        return [
            "title": summary["title"] as? String ?? "", "id": id,
            "on_latest": upToDate, "on_other": outOfDate, "total": total,
            "latest": summary["latestVersion"] as? String ?? "", "compliance_pct": share,
        ]
    }

    /// The safe title ids of a `classic-patch-titles list` answer, in its order; nil when the
    /// answer is not that list.
    static func patchTitleIDs(from data: Data) -> [String]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap { row -> String? in
            let id = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init) ?? ""
            return CLIBridge.isSafeDeviceIdentifier(id) ? id : nil
        }
    }

    /// Collects `patch-status` title by title and saves it only when every title answered: a
    /// snapshot missing titles would change the fleet's patch figure without saying so. nil
    /// when the run was stopped part-way (`runStop`): nothing is recorded and nothing failed.
    /// `afterReportTimeout`: the report's own timeout is already on record, so a walk that
    /// fails too records nothing more and the timeout streak stands.
    static func collectPatchStatusByTitle(
        profile: String, bin: URL, bridge: CLIBridge, dataDir: URL, recordManifest: Bool,
        stateStore: StateFileStore?, collectStart: Date, limits: DeviceCallLimits,
        afterReportTimeout: Bool, onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async throws -> KindCollectResult? {
        let kind = "patch-status"
        func say(_ level: CLIBridge.LogLevel, _ text: String) {
            onLine(.init(timestamp: Date(), level: level, text: text))
        }
        func failed(_ exitCode: Int32, _ why: String) -> KindCollectResult {
            say(.warn, "[warn] \(kind) title by title: \(why) — not written")
            // After the report's timeout, a walk that failed some other way adds nothing. One
            // that timed out as well is a second timeout on the server's patch requests in
            // this run, so the hold starts now instead of after another run like it.
            if !afterReportTimeout || exitCode == CLIBridge.exitCodeTimedOut {
                stateStore?.record(.failed(exitCode: exitCode), report: kind, at: collectStart)
            }
            return KindCollectResult(
                outcome: CollectOutcome(kind: kind, exitCode: exitCode), saved: false)
        }
        let started = Date()
        let list = try? await bridge.runAndCapture(
            executable: bin, arguments: patchTitleListArguments(profile: profile),
            environment: CLIBridge.environmentForJamfCLI(), timeout: limits.timeout,
            onLine: { _ in })
        guard let (listExit, listData) = list, listExit == 0,
              let ids = patchTitleIDs(from: listData) else {
            let exit = list.map { FailureCause.exitCountingServerTimeout($0.0, stdout: $0.1) }
            return failed(exit ?? launchFailureExitCode, "the title list did not answer")
        }
        say(.info, "[info] \(kind): collecting \(ids.count) title(s) one at a time")
        let answers = await patchSummaries(
            ids: ids, profile: profile, bin: bin, bridge: bridge, limits: limits)
        let rows = ids.compactMap { answers.rows[$0] }
        guard rows.count == ids.count else {
            if answers.stoppedForRun { return nil }
            return failed(
                answers.stopExit ?? answers.lastFailure ?? 1,
                answers.stopExit.map { "stopped (\(exitText($0)))" }
                    ?? "\(ids.count - rows.count) of \(ids.count) titles did not answer")
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        try saveSnapshot(
            data: data, kind: kind, dataDir: dataDir, recordManifest: recordManifest,
            onLine: onLine)
        stateStore?.record(.landed, report: kind, at: collectStart)
        // Only a walk after the report timed out starts the period; a walk inside it must not
        // renew it, or the report and the failures scan are never tried again.
        if afterReportTimeout { stateStore?.recordPatchByTitle(at: collectStart) }
        let seconds = Int(Date().timeIntervalSince(started).rounded())
        stateStore?.recordDuration(report: kind, seconds: seconds)
        say(.ok, "[ok] \(kind): \(rows.count) title(s), collected one at a time in \(seconds)s")
        return KindCollectResult(outcome: CollectOutcome(kind: kind, exitCode: 0), saved: true)
    }

    /// Exits every later title of a per-title walk would repeat (3, 5, 6, 8), so the walk stops
    /// at the first one: the patch summaries above and the release-date walk.
    static let repeatingTitleExits: Set<Int32> = [
        CLIBridge.exitCodeUnauthorized, CLIBridge.exitCodePermissionDenied,
        CLIBridge.exitCodeRateLimited, CLIBridge.exitCodeRefusedByPolicy,
    ]

    private struct PatchSummaryAnswers {
        var rows: [String: [String: Any]] = [:]
        var lastFailure: Int32?
        /// The exit that ended the walk early: three timeouts in a row, or 3, 5, 6 or 8, which
        /// every later title would repeat.
        var stopExit: Int32?
        var stoppedForRun = false
    }

    /// The summaries of `ids`, at most `patchByTitleConcurrency` at a time. Stops starting
    /// titles after `limits.stopAfterTimeouts` timeouts in a row (the app's limit or jamf-cli's
    /// own), on an exit every title would repeat, or when the run is stopped.
    private static func patchSummaries(
        ids: [String], profile: String, bin: URL, bridge: CLIBridge, limits: DeviceCallLimits
    ) async -> PatchSummaryAnswers {
        var answers = PatchSummaryAnswers()
        var timeoutStreak = 0
        let stop = runStop
        let repeating = repeatingTitleExits
        await withTaskGroup(of: (String, Int32, Data).self) { group in
            var inFlight = 0
            func take(_ done: (String, Int32, Data)) {
                let (id, rawExit, data) = done
                let exit = FailureCause.exitCountingServerTimeout(rawExit, stdout: data)
                timeoutStreak = exit == CLIBridge.exitCodeTimedOut ? timeoutStreak + 1 : 0
                if exit == 0, let object = try? JSONSerialization.jsonObject(with: data),
                   let summary = (object as? [String: Any])
                    ?? (object as? [[String: Any]])?.first,
                   let row = patchStatusRow(id: id, summary: summary) {
                    answers.rows[id] = row
                    return
                }
                answers.lastFailure = exit == 0 ? 1 : exit
                if answers.stopExit == nil,
                   repeating.contains(exit) || timeoutStreak >= limits.stopAfterTimeouts {
                    answers.stopExit = exit
                }
            }
            for id in ids {
                if inFlight >= patchByTitleConcurrency, let done = await group.next() {
                    inFlight -= 1
                    take(done)
                }
                if answers.stopExit != nil { break }
                if stop?() != nil { answers.stoppedForRun = true; break }
                inFlight += 1
                group.addTask {
                    let result = try? await bridge.runAndCapture(
                        executable: bin,
                        arguments: patchSummaryArguments(profile: profile, titleId: id),
                        environment: CLIBridge.environmentForJamfCLI(), timeout: limits.timeout,
                        onLine: { _ in })
                    return (id, result?.0 ?? launchFailureExitCode, result?.1 ?? Data())
                }
            }
            for await done in group { take(done) }
        }
        return answers
    }
}
