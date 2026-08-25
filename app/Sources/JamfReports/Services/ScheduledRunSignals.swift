import Foundation

// MARK: - Webhook fact assembly (detail-mode reduction + egress redaction)
//
// These three fact builders are top-level (not namespaced) so both the
// scheduled-run senders below and `WebhookNotifierTests` can call them
// directly. Moving them changes no behavior — the payloads are byte-identical
// to the pre-extraction main.swift versions.

/// Facts for a success/partial digest. `full` mode is byte-identical to the
/// pre-2.6 payload (Profile/Run/Status, plus "Sheets failed" and "Report" when
/// present). `minimal` keeps ONLY Profile/Run/Status — the report filename
/// embeds the profile + timestamp and the sheet-failure count is dropped so the
/// minimal digest is a doorbell, not a data channel.
func successFacts(
    detail: NotifyConfig.Detail,
    profile: String,
    mode: Schedule.RunMode,
    artifact: String?,
    sheetFailures: Int
) -> [WebhookNotifier.Fact] {
    let statusValue = sheetFailures > 0 ? "Partial" : "Success"
    var facts: [WebhookNotifier.Fact] = [
        .init(label: "Profile", value: profile),
        .init(label: "Run", value: mode.displayTitle),
        .init(label: "Status", value: statusValue),
    ]
    guard detail == .full else { return facts }
    if sheetFailures > 0 {
        facts.append(.init(label: "Sheets failed", value: "\(sheetFailures)"))
    }
    if let artifact { facts.append(.init(label: "Report", value: artifact)) }
    return facts
}

/// Facts for a failure digest. `full` mode scrubs the error text through the
/// strictest egress pipeline (credential patterns + full-PII incl. hostnames)
/// before it enters a fact. `minimal` drops the error fact entirely, leaving
/// Profile/Run/Status: Failed with no free text.
func failureFacts(
    detail: NotifyConfig.Detail,
    profile: String,
    mode: Schedule.RunMode,
    errorDescription: String
) -> [WebhookNotifier.Fact] {
    var facts: [WebhookNotifier.Fact] = [
        .init(label: "Profile", value: profile),
        .init(label: "Run", value: mode.displayTitle),
        .init(label: "Status", value: "Failed"),
    ]
    guard detail == .full else { return facts }
    let scrubbed = DiagnosticRedactor().redactText(LogRedactor.redact(errorDescription))
    facts.append(.init(label: "Error", value: scrubbed))
    return facts
}

/// Facts for a metric-alert digest. `full` mode lists each tripped rule
/// (metric label → message). `minimal` collapses to a single count fact with no
/// metric names, values, thresholds, or dates.
func alertFacts(
    detail: NotifyConfig.Detail,
    profile: String,
    hits: [MetricAlertHit]
) -> [WebhookNotifier.Fact] {
    guard detail == .full else {
        let word = hits.count == 1 ? "rule" : "rules"
        return [
            .init(label: "Profile", value: profile),
            .init(label: "Alerts", value: "\(hits.count) \(word) tripped"),
        ]
    }
    var facts: [WebhookNotifier.Fact] = [.init(label: "Profile", value: profile)]
    facts.append(contentsOf: hits.map { .init(label: $0.metricLabel, value: $0.message) })
    return facts
}

// MARK: - Scheduled-run trust signals (webhook digests + metric alerts)

/// Reusable trust machinery shared by the headless `--scheduled-run` path
/// (`App/main.swift`) and the included `jamf-reports` CLI (`CLI/ReportCommands`).
///
/// Extracted verbatim from main.swift so a self-scheduled CLI `collect`/
/// `generate` surfaces the same signals a scheduled run does. Every member is
/// best-effort: a webhook or summary-load failure logs a warning and never
/// throws into (or changes the exit code of) the run.
///
/// Scheduled-run-only context — the fleet dead-man overdue digest and its
/// per-profile notify resolution — deliberately stays in main.swift; it has no
/// meaning for a single CLI invocation.
enum ScheduledRunSignals {

    /// Post the opt-in scheduled-run webhook digest. No-op unless `config.notify`
    /// is enabled with a usable https URL. Best-effort — never affects the run.
    ///
    /// `sheetFailures` > 0 sets Status to "Partial" and appends a "Sheets failed"
    /// fact so degraded runs are not misreported as successes. `recorder`
    /// receives a `[warn]` line when the post fails, making the failure visible
    /// in Run History rather than only in `~/Library/Logs`.
    static func notifyScheduledRun(
        config: ReportConfig?,
        profile: String,
        mode: Schedule.RunMode,
        artifact: String?,
        sheetFailures: Int = 0,
        recorder: ScheduledRunRecorder?
    ) async {
        guard let notify = config?.notify, notify.isUsable else { return }
        let facts = successFacts(
            detail: notify.resolvedDetail, profile: profile, mode: mode,
            artifact: artifact, sheetFailures: sheetFailures
        )
        let sent = await WebhookNotifier.send(
            config: notify, title: "Jamf Report — \(profile)", facts: facts
        )
        if !sent {
            let message = "[warn] webhook notification failed for '\(profile)'"
            fputs(message + "\n", stderr)
            recorder?.record(message)
        }
    }

    /// Post a failure webhook digest for a run that threw before generating a
    /// report. The error text is the only free-text egress channel — a network
    /// `errorDescription` can embed the Jamf server hostname — so in `full` mode
    /// it is scrubbed through the strictest pipeline (`LogRedactor` credential
    /// patterns + `DiagnosticRedactor` full-PII pass) before it enters a fact.
    /// `minimal` mode drops the error fact entirely. Best-effort — never throws.
    static func notifyScheduledRunFailure(
        config: ReportConfig?,
        profile: String,
        mode: Schedule.RunMode,
        errorDescription: String,
        recorder: ScheduledRunRecorder?
    ) async {
        guard let notify = config?.notify, notify.isUsable else { return }
        let facts = failureFacts(
            detail: notify.resolvedDetail, profile: profile, mode: mode,
            errorDescription: errorDescription
        )
        let sent = await WebhookNotifier.sendFailed(
            config: notify, title: "Jamf Report — \(profile)", facts: facts
        )
        if !sent {
            let message = "[warn] failure webhook notification failed for '\(profile)'"
            fputs(message + "\n", stderr)
            recorder?.record(message)
        }
    }

    /// Evaluate metric-threshold alert rules against the fresh summary a collect
    /// just wrote and post ONE attention card if any rule trips (2.6 "trust trio"
    /// #1). Gated on `alerts.isEnabled` AND a usable `notify:` webhook — alerts
    /// reuse the notify webhook and add no URL of their own. Only call after a
    /// run that COLLECTED (snapshot-only, full, csv-assisted); jamf-cli-only
    /// Record any config problem serious enough to make the data unreliable.
    ///
    /// A scheduled run happily collects against broken column mappings or a
    /// baseline pointing at an EA nobody collects — it exits 0 and Run History
    /// shows a clean run, so the config rots invisibly for weeks. This puts the
    /// Config Doctor's failures where automation can see them: in the run log
    /// (and therefore Run History), and as a line in the webhook digest.
    ///
    /// Only `.fail` rows surface. Warnings are for a human reading the Config
    /// screen; putting them here would make every run look broken and train
    /// the operator to ignore the signal.
    ///
    /// Best-effort, and deliberately after the data is written: a doctor that
    /// throws must never cost a collect that already succeeded.
    @discardableResult
    static func recordConfigHealth(
        profile: String,
        recorder: ScheduledRunRecorder?,
        report: DoctorReport? = nil
    ) -> Int {
        let report = report ?? ConfigDoctorService.run(profile: profile)
        let failures = report.rows.filter { $0.severity == .fail }
        guard !failures.isEmpty else { return 0 }

        let headline = "[warn] \(failures.count) config check(s) failing — data may be "
            + "unreliable until fixed"
        AppLogger.collect.warning("\(headline, privacy: .public)")
        print(headline)
        recorder?.record(headline)
        for row in failures {
            let line = "[warn] \(row.title): \(row.detail)"
            print(line)
            recorder?.record(line)
            if let hint = row.hint {
                let fix = "        fix: \(hint)"
                print(fix)
                recorder?.record(fix)
            }
        }
        return failures.count
    }

    /// generates from cache and produces no fresh summary.
    ///
    /// Best-effort: a summary-load or send failure logs a warning and never
    /// throws into the run, mirroring `notifyScheduledRun`.
    static func notifyMetricAlerts(
        config: ReportConfig?,
        profile: String,
        workspace: URL,
        recorder: ScheduledRunRecorder?
    ) async {
        guard let config, let alerts = config.alerts, alerts.isEnabled else { return }
        let rules = alerts.resolvedRules
        // Surface rules dropped by resolvedRules (unknown metric/operator,
        // invalid threshold) BEFORE the webhook guard — one config problem must
        // not mask the other.
        reportDroppedAlertRules(
            configured: alerts.rules ?? [], resolved: rules, recorder: recorder
        )
        // Alerts on but no usable webhook = total silence. Warn loudly (Console +
        // Run History) so a misconfigured URL isn't discovered only by absence.
        guard let notify = config.notify, notify.isUsable else {
            let message = "[warn] alerts enabled but no usable notify webhook — alerts cannot be delivered"
            AppLogger.webhook.warning("\(message, privacy: .public)")
            recorder?.record(message)
            return
        }
        guard !rules.isEmpty else { return }
        guard let summariesDir = try? WorkspacePaths.summariesDir(for: profile) else { return }
        let summaries = SummaryJSONParser.parseDirectory(summariesDir)
        guard let current = summaries.last else { return }
        // Only evaluate a summary this run actually wrote today. A day that
        // produced no fresh summary (e.g. totalDevices == 0) leaves an older
        // newest-summary that would be carded as if it were today's — skip it.
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        guard current.date == today else {
            AppLogger.event(.webhook, .notice,
                "metric alerts skipped — newest summary \(current.date) is not today (\(today))")
            return
        }
        let hits = evaluateHits(rules: rules, current: current, history: summaries)
        guard !hits.isEmpty else { return }
        // Dedup per-day per-rule: a second same-day run (managed freshness + scan)
        // doesn't re-card, but a rule that trips for the first time later today does.
        let ledger = MetricAlertLedger(workspace: workspace)
        let newKeys = Set(ledger.pendingKeys(
            day: today, keys: hits.map(MetricAlertEvaluator.dedupKey(for:))
        ))
        let newHits = hits.filter { newKeys.contains(MetricAlertEvaluator.dedupKey(for: $0)) }
        guard !newHits.isEmpty else { return }
        let facts = alertFacts(detail: notify.resolvedDetail, profile: profile, hits: newHits)
        let sent = await WebhookNotifier.sendAlert(
            config: notify, title: "Jamf Reports alert — \(profile)", facts: facts
        )
        guard sent else {
            let message = "[warn] metric-alert webhook failed for '\(profile)'"
            fputs(message + "\n", stderr)
            recorder?.record(message)
            return
        }
        // Claim the day only after a confirmed send, so a transient webhook
        // failure retries on the next run instead of silencing the rule.
        ledger.record(day: today, keys: Array(newKeys))
    }

    /// Pure hit computation: group the resolved rules by lookback, pick a strict
    /// prior per group, and evaluate. Sorted by dedup key so the card's fact
    /// order is stable (Dictionary grouping order is nondeterministic).
    /// `history` is the full ascending-sorted summary list including `current`.
    static func evaluateHits(
        rules: [AlertRule],
        current: DailySummary,
        history: [DailySummary]
    ) -> [MetricAlertHit] {
        let candidates = Array(history.dropLast())  // everything older than `current`
        var hits: [MetricAlertHit] = []
        for (lookback, group) in Dictionary(grouping: rules, by: { $0.resolvedLookbackDays }) {
            // Only drops_more_than consumes a prior, so drive the metric-aware
            // selection off the drop rules' metrics; below/above ignore it.
            let dropMetrics = Set(
                group.filter { $0.resolvedComparison == .dropsMoreThan }
                    .compactMap { $0.resolvedMetric }
            )
            let prior = strictPrior(
                candidates: candidates, current: current,
                metrics: dropMetrics, lookbackDays: lookback
            )
            hits.append(contentsOf:
                MetricAlertEvaluator.evaluate(rules: group, current: current, prior: prior))
        }
        hits.sort { MetricAlertEvaluator.dedupKey(for: $0) < MetricAlertEvaluator.dedupKey(for: $1) }
        return hits
    }

    /// Strict prior for a `drops_more_than` group. The prior must be at least
    /// `lookbackDays` older than `current` (never younger — a 7-day rule must not
    /// fire on a 1-day wobble). Among the age-eligible candidates, prefer the
    /// newest that actually CARRIES one of the group's drop metrics, so the drop
    /// is measured against a summary that had the value; fall back to the plain
    /// newest age-eligible summary when none carries one (never fall forward).
    /// `candidates` is the ascending-sorted history excluding `current`.
    static func strictPrior(
        candidates: [DailySummary],
        current: DailySummary,
        metrics: Set<AlertMetric>,
        lookbackDays: Int
    ) -> DailySummary? {
        let cutoff = current.parsedDate.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let eligible = candidates.filter { $0.parsedDate <= cutoff }
        guard let newestEligible = eligible.last else { return nil }
        guard !metrics.isEmpty else { return newestEligible }
        return eligible.last { summary in
            metrics.contains { $0.value(in: summary) != nil }
        } ?? newestEligible
    }

    /// Log a warning + `[warn]` recorder line (so it lands in Run History, not
    /// only `~/Library/Logs`) for every configured alert rule that `resolvedRules`
    /// drops — a rule with an unknown metric/operator or an invalid threshold.
    /// Names the offending metric/when strings (config keys, not PII). No-op when
    /// none were dropped. `AlertRule` is `Equatable`, so "dropped" = configured
    /// minus resolved.
    private static func reportDroppedAlertRules(
        configured: [AlertRule],
        resolved: [AlertRule],
        recorder: ScheduledRunRecorder?
    ) {
        guard configured.count != resolved.count else { return }
        for rule in configured where !resolved.contains(rule) {
            let metricStr = rule.metric ?? "(none)"
            let whenStr = rule.when ?? "(none)"
            let message = "[warn] alert rule ignored — metric='\(metricStr)' when='\(whenStr)': "
                + "unknown metric/operator or invalid threshold"
            AppLogger.webhook.warning("\(message, privacy: .public)")
            recorder?.record(message)
        }
    }
}

/// The "[partial] N sheet failure(s)…" marker text kept byte-identical to the
/// scheduled path's (main.swift), so `RunHistoryService.isPartialRun`'s
/// `contains("[partial]")` scan recognizes a partially-failed CLI `generate`
/// the same way it does a scheduled one.
func partialRunMarker(sheetFailures: Int) -> String {
    "[partial] \(sheetFailures) sheet failure(s) — see lines above"
}

// MARK: - Included-CLI run signals

/// Bundles the best-effort trust signals — a Run History recorder, the webhook
/// digest, and (for collect) metric alerts — for an included `jamf-reports`
/// CLI `collect`/`generate` run, so a self-scheduled CLI job surfaces the same
/// machinery a scheduled run does.
///
/// Everything here is additive and best-effort: it writes to Run History files
/// and posts webhooks, but never changes the CLI's exit code or stdout/stderr.
/// A `collect` run maps to a `snapshot-only` digest (it produces a fresh summary
/// and evaluates alerts); a `generate` run maps to a `jamf-cli-only` digest (it
/// generates from cache and does NOT evaluate alerts — the same rule the
/// scheduled path applies to jamf-cli-only).
struct CLIRunSignals: Sendable {
    enum Kind: Sendable { case collect, generate }

    let profile: String
    let workspace: URL?
    let config: ReportConfig?
    let mode: Schedule.RunMode
    let kind: Kind
    let recorder: ScheduledRunRecorder?

    /// True only for `collect` — `generate` does not collect, so it never
    /// evaluates alerts (mirrors the scheduled jamf-cli-only rule).
    var evaluatesAlerts: Bool { Self.evaluatesAlerts(for: kind) }

    static func evaluatesAlerts(for kind: Kind) -> Bool { kind == .collect }

    /// The digest run-mode label a CLI kind reports.
    static func mode(for kind: Kind) -> Schedule.RunMode {
        kind == .collect ? .snapshotOnly : .jamfCLIOnly
    }

    /// A distinct, valid LaunchAgent-style label so CLI runs appear honestly in
    /// Run History (`<prefix>.<profile>.cli-collect` / `.cli-generate`) rather
    /// than being attributed to a scheduled agent.
    static func cliLabel(profile: String, kind: Kind) -> String {
        "\(LaunchAgentWriter.labelPrefix).\(profile).cli-\(kind == .collect ? "collect" : "generate")"
    }

    /// Best-effort setup for an included-CLI run. Resolves the workspace, loads
    /// the profile config (reused if the caller already has it), and opens a Run
    /// History recorder. Never throws — a missing workspace/config or an
    /// un-openable recorder degrades to a run that still executes, just without
    /// the trust signals.
    static func begin(profile: String, kind: Kind, config: ReportConfig? = nil) -> CLIRunSignals {
        let workspace = ProfileService.workspaceURL(for: profile)
        let resolvedConfig = config ?? workspace.flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
        let recorder = workspace.flatMap {
            ScheduledRunRecorder(workspace: $0, label: cliLabel(profile: profile, kind: kind))
        }
        return CLIRunSignals(
            profile: profile, workspace: workspace, config: resolvedConfig,
            mode: mode(for: kind), kind: kind, recorder: recorder
        )
    }

    /// Wrap the CLI's own log-line router so every engine line is also recorded
    /// to Run History. The recorder side is best-effort; `downstream` (the CLI's
    /// stdout/stderr routing) runs unchanged so stdout/exit behavior is preserved.
    func teeing(
        _ downstream: @escaping @Sendable (CLIBridge.LogLine) -> Void
    ) -> @Sendable (CLIBridge.LogLine) -> Void {
        let recorder = self.recorder
        return { line in
            recorder?.record(line.text)
            downstream(line)
        }
    }

    /// Record the completion line, post the success digest, evaluate metric
    /// alerts (collect only), and close the run record at exit 0. Best-effort;
    /// never throws or changes the exit path.
    func finishSuccess(artifact: URL? = nil, sheetFailures: Int = 0) async {
        let verb = kind == .collect ? "collect" : "report"
        if let artifact {
            recorder?.record("[ok] \(verb) complete: \(artifact.lastPathComponent)")
        } else {
            recorder?.record("[ok] \(verb) complete for \(profile)")
        }
        await ScheduledRunSignals.notifyScheduledRun(
            config: config, profile: profile, mode: mode,
            artifact: artifact?.lastPathComponent, sheetFailures: sheetFailures,
            recorder: recorder
        )
        if evaluatesAlerts, let workspace {
            await ScheduledRunSignals.notifyMetricAlerts(
                config: config, profile: profile, workspace: workspace, recorder: recorder
            )
        }
        recorder?.finish(
            exitCode: 0, sheetFailures: sheetFailures, artifacts: artifact.map { [$0] } ?? []
        )
    }

    /// Record the error, close the run record at exit 1, and post the failure
    /// card. Best-effort; the failure card is posted after the recorder is
    /// finished (as the scheduled path does) so webhook latency never blocks the
    /// exit. Does not swallow the error — the caller still rethrows it.
    func finishFailure(_ error: Error) async {
        let desc = error.localizedDescription
        // Redaction boundary: the local Run History log gets the raw error
        // (operator's own workspace, matching main.swift's scheduled path);
        // only the webhook egress below is LogRedactor/DiagnosticRedactor-
        // scrubbed, inside notifyScheduledRunFailure.
        recorder?.record("[error] \(desc)")
        recorder?.finish(exitCode: 1)
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: config, profile: profile, mode: mode,
            errorDescription: desc, recorder: nil
        )
    }
}
