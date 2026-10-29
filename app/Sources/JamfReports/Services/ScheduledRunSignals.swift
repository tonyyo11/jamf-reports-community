import CryptoKit
import Foundation

// MARK: - Webhook fact assembly (detail-mode reduction + egress redaction)
//
// These three fact builders are top-level (not namespaced) so both the
// scheduled-run senders below and `WebhookNotifierTests` can call them
// directly. Moving them changes no behavior — the payloads are byte-identical
// to the pre-extraction HeadlessRun.swift versions.

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
/// strictest egress pipeline (credential patterns + full-PII incl. hostnames, and
/// the profile's tenant and environment IDs) before it enters a fact. `minimal`
/// drops the error fact entirely, leaving Profile/Run/Status: Failed with no free text.
func failureFacts(
    detail: NotifyConfig.Detail,
    profile: String,
    mode: Schedule.RunMode,
    errorDescription: String,
    scopeIDs: (String) -> [String] = { DiagnosticBundleService.scopeIDs(profile: $0) }
) -> [WebhookNotifier.Fact] {
    var facts: [WebhookNotifier.Fact] = [
        .init(label: "Profile", value: profile),
        .init(label: "Run", value: mode.displayTitle),
        .init(label: "Status", value: "Failed"),
    ]
    guard detail == .full else { return facts }
    let scrubbed = LogRedactor.redactedForSharing(
        errorDescription, profile: profile, scopeIDs: scopeIDs)
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

/// Facts for the daily heartbeat card. `full` adds the newest daily summary's date, so the
/// receiver can see data is current as well as the Mac alive; `minimal` is Profile and Status
/// only. Never a device count or name.
func heartbeatFacts(
    detail: NotifyConfig.Detail, profile: String, newestSummaryDay: String?
) -> [WebhookNotifier.Fact] {
    var facts: [WebhookNotifier.Fact] = [
        .init(label: "Profile", value: profile),
        .init(label: "Status", value: "Background item ran"),
    ]
    if detail == .full {
        facts.append(.init(label: "Newest summary", value: newestSummaryDay ?? "none"))
    }
    return facts
}

/// What a headless run prints to stdout for `line`, or nil when the line stays in the run
/// log only (info lines unless `verbose`). Redacted like the log, since a scheduler may
/// capture stdout somewhere less protected.
func scheduledRunEcho(_ line: CLIBridge.LogLine, verbose: Bool) -> String? {
    guard verbose || line.level != .info else { return nil }
    return LogRedactor.redact(line.text)
}

// MARK: - Scheduled-run trust signals (webhook digests + metric alerts)

/// Reusable trust machinery shared by the headless `--scheduled-run` path
/// (`App/HeadlessRun.swift`) and the included `jamf-reports` CLI (`CLI/ReportCommands`).
///
/// Extracted verbatim from HeadlessRun.swift so a self-scheduled CLI `collect`/
/// `generate` surfaces the same signals a scheduled run does. Every member is
/// best-effort: a webhook or summary-load failure logs a warning and never
/// throws into (or changes the exit code of) the run.
///
/// Scheduled-run-only context — the fleet dead-man overdue digest and its
/// per-profile notify resolution — deliberately stays in HeadlessRun.swift; it has no
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
        guard let notify = SharedConfigPin.effectiveNotify(config?.notify, profile: profile),
              notify.isUsable else { return }
        let facts = successFacts(
            detail: notify.resolvedDetail, profile: profile, mode: mode,
            artifact: artifact, sheetFailures: sheetFailures
        )
        let failure = WebhookNotifier.DeliveryFailure()
        let sent = await WebhookNotifier.send(
            config: notify, title: "Scheduled run finished — \(profile)", facts: facts,
            tone: sheetFailures > 0 ? .warning : .good,
            organization: WebhookNotifier.organization(from: config), failure: failure
        )
        if !sent {
            let message = "[warn] webhook notification failed for '\(profile)': "
                + (failure.reason ?? "unknown")
            fputs(message + "\n", stderr)
            recorder?.record(message)
        }
        noteWebhook(sent ? .sent : .failed, failure: failure)
    }

    /// Post a failure webhook digest for a run that failed before or while generating a
    /// report. The error text is the only free-text egress channel — a network
    /// `errorDescription` can embed the Jamf server hostname — so in `full` mode
    /// it is scrubbed through the strictest pipeline (`LogRedactor` credential
    /// patterns + `DiagnosticRedactor` full-PII pass) before it enters a fact.
    /// `minimal` mode drops the error fact entirely. Best-effort — never throws.
    /// `fallbackNotify` is the `notify:` block read alone, for a run with no decoded config.
    ///
    /// With hourly retries a persistent failure would post every hour, so a `scheduleKey`
    /// (schedule label + profile) allows one card per local day for the same failure
    /// (`failureFingerprint`); a different failure posts, and a failed send stamps nothing so
    /// the next pass retries. The stamp lives in `stateRoot` (this Mac's Application Support),
    /// never in the workspace, which a refused run must leave untouched.
    static func notifyScheduledRunFailure(
        config: ReportConfig?,
        profile: String,
        mode: Schedule.RunMode,
        errorDescription: String,
        recorder: ScheduledRunRecorder?,
        fallbackNotify: NotifyConfig? = nil,
        scheduleKey: String,
        stateRoot: URL = AppSupport.directory()
            .appendingPathComponent("failure-cards", isDirectory: true),
        now: Date = Date()
    ) async {
        guard let notify = SharedConfigPin.effectiveNotify(
                config?.notify ?? fallbackNotify, profile: profile),
              notify.isUsable else { return }
        let facts = failureFacts(
            detail: notify.resolvedDetail, profile: profile, mode: mode,
            errorDescription: errorDescription
        )
        let folder = stateRoot.appendingPathComponent(
            ProfileName.labelComponent(scheduleKey), isDirectory: true)
        let day = SummaryJSONParser.dateFormatter.string(from: now)
        let failure = WebhookNotifier.DeliveryFailure()
        let outcome = await DayMarker(name: "failure-card").sendOnce(
            day: "\(day)-\(failureFingerprint(errorDescription))", in: [folder], now: now,
            onLine: { fputs($0 + "\n", stderr) }
        ) {
            await WebhookNotifier.sendFailed(
                config: notify, title: "Scheduled run failed — \(profile)", facts: facts,
                organization: WebhookNotifier.organization(from: config), failure: failure)
        }
        if outcome == .failed {
            let message = "[warn] failure webhook notification failed for '\(profile)': "
                + (failure.reason ?? "unknown")
            fputs(message + "\n", stderr)
            recorder?.record(message)
            AppLogger.webhook.error("\(message, privacy: .public)")
        }
        noteWebhook(outcome, failure: failure)
    }

    /// Eight hex characters naming a failure: digit runs (durations, counts, ports) are
    /// flattened so the same failure with a different number is still the same failure.
    /// shortcut: one stamp per schedule holds the latest failure only, so A, B, A posts A twice.
    static func failureFingerprint(_ reason: String) -> String {
        let flattened = LogRedactor.redact(reason)
            .replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        return SHA256.hash(data: Data(flattened.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Post the opt-in daily heartbeat card for each profile in `profiles` whose `notify:` is
    /// usable with `heartbeat: true`, once per local day, after the tick's due schedules ran.
    /// The receiver alerts on its absence, so a Mac or background item that stops is noticed.
    /// The stamp lives in `stateRoot` (this Mac's Application Support), never in the workspace,
    /// and is written only after a confirmed send. Tick-only: no GUI path calls this.
    /// Best-effort — never throws.
    static func notifyHeartbeats(
        profiles: [String],
        excluding excluded: Set<String> = [],
        stateRoot: URL = AppSupport.directory()
            .appendingPathComponent("heartbeats", isDirectory: true),
        now: Date = Date()
    ) async {
        let day = SummaryJSONParser.dateFormatter.string(from: now)
        let targets = notifyTargets(in: profiles.filter { !excluded.contains($0) }) { _ in false }
        let marker = DayMarker(name: "heartbeat")
        for target in targets where target.notify.sendsHeartbeat {
            guard let id = WorkspaceID(target.profile) else { continue }
            let folder = stateRoot.appendingPathComponent(id.pathComponent, isDirectory: true)
            // Every wake gets here; skip before building anything once today's card is out.
            guard !marker.isStamped(day, in: folder) else { continue }
            let facts = heartbeatFacts(
                detail: target.notify.resolvedDetail, profile: target.profile,
                newestSummaryDay: SummaryJSONParser.newestSummaryDay(profile: target.profile))
            let failure = WebhookNotifier.DeliveryFailure()
            let outcome = await AttentionLog.recording(profile: target.profile) {
                let outcome = await marker.sendOnce(
                    day: day, in: [folder], now: now, onLine: { fputs($0 + "\n", stderr) }
                ) {
                    await WebhookNotifier.send(
                        config: target.notify,
                        title: "Daily heartbeat — \(target.profile)",
                        facts: facts,
                        organization: WebhookNotifier.organization(profile: target.profile),
                        failure: failure)
                }
                noteWebhook(outcome, failure: failure)
                return outcome
            }
            if outcome == .failed {
                let message = "[warn] heartbeat notification failed for '\(target.profile)': "
                    + (failure.reason ?? "unknown")
                fputs(message + "\n", stderr)
                AppLogger.webhook.error("\(message, privacy: .public)")
            }
        }
    }

    /// A confirmed send closes `webhookRejected`; a failed one opens it, naming the HTTP status
    /// or the network error, never the URL.
    static func noteWebhook(
        _ outcome: DayMarker.SendOutcome, failure: WebhookNotifier.DeliveryFailure
    ) {
        switch outcome {
        case .sent: AttentionLog.clear(.webhookRejected)
        case .failed:
            AttentionLog.raise(
                .webhookRejected, "webhook rejected (\(failure.reason ?? "unknown"))")
        case .skipped: break
        }
    }

    /// Record any config problem serious enough to make the data unreliable.
    ///
    /// A scheduled run happily collects against broken column mappings or a
    /// baseline pointing at an EA nobody collects — it exits 0 and Run History
    /// shows a clean run, so the config rots invisibly for weeks. This puts the
    /// Config Doctor's failures where automation can see them: the run log, and
    /// therefore Run History. It does NOT reach the webhook digest — nothing
    /// here posts, and the digest's facts are assembled by the callers above
    /// without consulting the doctor.
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

    /// Evaluate metric-threshold alert rules against the fresh summary a collect
    /// just wrote and post ONE attention card if any rule trips (2.6 "trust trio"
    /// #1). Gated on `alerts.isEnabled` AND a usable `notify:` webhook — alerts
    /// reuse the notify webhook and add no URL of their own. Only call after a
    /// run that COLLECTED (snapshot-only, full); jamf-cli-only
    /// generates from cache and produces no fresh summary.
    ///
    /// Best-effort: a summary-load or send failure logs a warning and never
    /// throws into the run, mirroring `notifyScheduledRun`.
    static func notifyMetricAlerts(
        config: ReportConfig?,
        profile: String,
        workspace: URL,
        recorder: ScheduledRunRecorder?,
        now: Date = Date()
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
        guard let configured = config.notify, configured.isUsable else {
            let message = "[warn] alerts enabled but no usable notify webhook — alerts cannot be delivered"
            AppLogger.webhook.warning("\(message, privacy: .public)")
            recorder?.record(message)
            return
        }
        guard !rules.isEmpty,
              let notify = SharedConfigPin.effectiveNotify(configured, profile: profile)
        else { return }
        let summaries = TrendStore.readSummaries(profile: profile)
        guard let current = summaries.last else { return }
        // Only evaluate a summary this run actually wrote today. A day that
        // produced no fresh summary (e.g. no source landed) leaves an older
        // newest-summary that would be carded as if it were today's — skip it.
        let today = SummaryJSONParser.dateFormatter.string(from: now)
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
        let failure = WebhookNotifier.DeliveryFailure()
        let sent = await WebhookNotifier.sendAlert(
            config: notify, title: "Metric alert — \(profile)", facts: facts,
            organization: WebhookNotifier.organization(from: config),
            failure: failure
        )
        noteWebhook(sent ? .sent : .failed, failure: failure)
        guard sent else {
            let message = "[warn] metric-alert webhook failed for '\(profile)': "
                + (failure.reason ?? "unknown")
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
/// scheduled path's (HeadlessRun.swift), so `RunHistoryService.isPartialRun`'s
/// `contains("[partial]")` scan recognizes a partially-failed CLI `generate`
/// the same way it does a scheduled one.
func partialRunMarker(sheetFailures: Int) -> String {
    "[partial] \(sheetFailures) \(sheetFailureMarkerSuffix)"
}

/// Shared with `CollectHonestyWatcher`, which must not read a report's sheet failures as
/// data that did not land.
let sheetFailureMarkerSuffix = "sheet failure(s) — see lines above"

/// Ends the `[partial]` line a device scan logs when its snapshot landed with a few devices
/// missing, inside the failure budget. `CollectHonestyWatcher` skips it: the kind did land,
/// and a same-day retry cannot rescan, since the scan's cadence floor makes it not due.
let deviceScanGapsMarkerSuffix = "devices did not respond"

/// Ends the `[partial]` line a device scan logs for a kind it did not write, stopped or over
/// its failure budget. `CollectHonestyWatcher` reads the kind from that line.
let deviceScanNotWrittenMarkerSuffix = "— not written"

/// Watches a run's log lines for the two engine markers that mean a run exiting
/// 0 did NOT do what "success" implies: it stood down for another machine
/// (nothing was collected at all), or it could not write the day's summary
/// (Trends did not move).
///
/// This exists because `CollectRouter.run` returns `Void`: `ReportEngine.collect`'s
/// `CollectDisposition` stops at the router, which uses it only to decide whether
/// Protect follows, so the facts have to travel out on the log stream the caller
/// is already reading. A locked box
/// rather than a captured `var` because `onLine` is `@Sendable` and the engine
/// calls it from its process-reader queues.
final class CollectHonestyWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var standDown = false
    /// The stand-down was for a peer's recent collect, not its live claim.
    private var freshnessStandDown = false
    private var summaryFailed = false
    private var partial = false
    /// Sources the `[partial]` lines named as not landed.
    private var unlanded: Set<String> = []
    /// A `[partial]` line that names no source, so no failure record can explain it.
    private var unexplainedPartial = false
    /// A `[partial]` line for a failure a retry repeats and no failure record can explain.
    private var permanentPartial = false

    init() {}

    /// Feed one log line. Cheap enough to call on every line of a collect.
    func observe(_ line: String) {
        if line.hasPrefix(ReportEngine.standDownMarker) {
            // A peer's live claim may end before the same-day retry; "collected recently" won't.
            let liveClaim = line.hasSuffix(ReportEngine.liveClaimStandDownSuffix)
            lock.withLock {
                standDown = true
                if liveClaim { partial = true; unexplainedPartial = true } else {
                    freshnessStandDown = true
                }
            }
            return
        }
        guard line.hasPrefix("[partial]"),
              !line.hasSuffix(sheetFailureMarkerSuffix),
              !line.hasSuffix(deviceScanGapsMarkerSuffix) else { return }
        let summary = line.hasPrefix(ReportEngine.summaryNotWrittenMarker)
        let kinds = Self.unlandedKinds(in: line)
        let protectThrew = line.hasPrefix(ReportEngine.protectCollectFailedMarker)
        // Follows from the sources line before it, which names them.
        let noSourceLanded = line.hasPrefix(
            "\(ReportEngine.summaryNotWrittenMarker) \(ReportEngine.noSourceLandedReason)")
        lock.withLock {
            partial = true
            if summary { summaryFailed = true }
            if let kinds { unlanded.formUnion(kinds) } else if protectThrew {
                permanentPartial = true
            } else if !noSourceLanded {
                unexplainedPartial = true
            }
        }
    }

    /// The kinds a `[partial]` line says did not land: the collect's sources line, or a device
    /// scan kind that was not written (`deviceScanNotWrittenMarkerSuffix`). Nil for any other
    /// line.
    static func unlandedKinds(in line: String) -> [String]? {
        if let marker = line.range(of: ReportEngine.unlandedSourcesMarker) {
            let list = line[marker.upperBound...].components(separatedBy: " — ")[0]
            return list.components(separatedBy: ", ").filter { !$0.isEmpty }
        }
        let prefix = "[partial] "
        guard line.hasPrefix(prefix), line.hasSuffix(" \(deviceScanNotWrittenMarkerSuffix)"),
              let colon = line.firstIndex(of: ":") else { return nil }
        return [String(line[line.index(line.startIndex, offsetBy: prefix.count)..<colon])]
    }

    /// The run deferred to another machine — no snapshot, no summary, nothing
    /// to announce. Still a successful outcome, just not a productive one.
    var stoodDown: Bool { lock.withLock { standDown } }

    /// The summary write failed, so the trend chart did not advance.
    var summaryWriteFailed: Bool { lock.withLock { summaryFailed } }

    /// A source or the summary did not land, or the run stood down for a peer's live claim. A
    /// stand-down because a peer collected recently, a report's sheet failures and a device
    /// scan that landed with gaps are not missing data a retry would fetch, and never set it. Whether a same-day retry is worth it is `retryCouldHelp`.
    var incomplete: Bool { lock.withLock { partial } }

    /// `incomplete` for the background item's same-day retry: false when the `[partial]`
    /// lines only name sources whose last failure a retry would repeat. Run History still
    /// reads such a run as Partial from its log.
    func retryCouldHelp(lastFailureRepeats: (String) -> Bool) -> Bool {
        let (partial, unexplained, permanent, kinds) = lock.withLock {
            (self.partial, unexplainedPartial, permanentPartial, unlanded)
        }
        guard partial else { return false }
        if unexplained { return true }
        if kinds.isEmpty { return !permanent }
        return !kinds.allSatisfy(lastFailureRepeats)
    }

    /// The rule self-remediation uses (`WorkspaceStore.lastFailureRepeatsOnRetry`), read from
    /// `profile`'s state files, except that exit 3 still retries (#226 5a).
    ///
    /// A stand-down because a peer collected recently is also worth a retry while `profile` has
    /// no summary for today: if that peer is off, a later wake finds its data older than the
    /// window and collects.
    func retryCouldHelp(profile: String, now: Date = Date()) -> Bool {
        if lock.withLock({ freshnessStandDown }),
           !SummaryJSONParser.hasSummary(profile: profile, on: now) { return true }
        guard let stateDir = try? WorkspacePaths.stateDir(for: profile) else { return incomplete }
        let store = StateFileStore(directory: stateDir)
        return retryCouldHelp {
            WorkspaceStore.lastFailureRepeatsOnRetry($0, in: store, countingUnauthorized: false)
        }
    }

    /// `retryCouldHelp(profile:)` for a run that exited `exitCode` after starting at `start`. A
    /// run that failed outright (a dead collect prints no `[partial]` line) is also worth a retry
    /// unless every source that failed since `start` failed in a way a retry repeats; one that
    /// recorded no failure (no workspace, a config that does not decode) still retries.
    func retryCouldHelp(profile: String, exitCode: Int32, since start: Date) -> Bool {
        if retryCouldHelp(profile: profile) { return true }
        guard exitCode != 0, let stateDir = try? WorkspacePaths.stateDir(for: profile) else {
            return exitCode != 0
        }
        let store = StateFileStore(directory: stateDir)
        let floor = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.down))
        let failed = ((try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? [])
            .filter { $0.hasSuffix(".fail") }.map { String($0.dropLast(".fail".count)) }
            .filter { (store.failures(report: $0)?.last ?? .distantPast) >= floor }
        guard !failed.isEmpty else { return true }
        return !failed.allSatisfy {
            WorkspaceStore.lastFailureRepeatsOnRetry($0, in: store, countingUnauthorized: false)
        }
    }

    /// Whether the run may claim it refreshed the fleet's data. False for
    /// either marker: both mean today's summary is not this run's work.
    var producedFreshSnapshot: Bool { !stoodDown && !summaryWriteFailed }
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
    /// Watches the run's own log stream for the two markers that make a bare
    /// exit 0 a lie. `generate` never emits them, so it is simply always quiet.
    let honesty: CollectHonestyWatcher
    /// The run's start: the day its metric alerts judge the newest summary against, so a
    /// collect that crosses midnight is still alerted on the day it dated its summary.
    var startedAt: Date = Date()

    /// True only for `collect` — `generate` does not collect, so it never
    /// evaluates alerts (mirrors the scheduled jamf-cli-only rule).
    var evaluatesAlerts: Bool { Self.evaluatesAlerts(for: kind) }

    /// Whether this run may post the success digest and evaluate alerts.
    var announcesSuccess: Bool { Self.announcesSuccess(for: kind, honesty: honesty) }

    static func evaluatesAlerts(for kind: Kind) -> Bool { kind == .collect }

    /// The gate, per kind, mirroring what `HeadlessRun.swift` does for each mode.
    ///
    /// A `collect`'s entire product is the day's summary, so either marker
    /// suppresses the card: a stand-down collected nothing, and a failed summary
    /// write left Trends where it was (`HeadlessRun.swift:480`). A `generate` renders a
    /// real workbook whether or not the summary write that follows it succeeded
    /// — `ReportEngine.generate` emits the same marker — so only a stand-down
    /// suppresses it, matching the scheduled twin at `HeadlessRun.swift:547`/`:558`.
    static func announcesSuccess(for kind: Kind, honesty: CollectHonestyWatcher) -> Bool {
        kind == .collect ? honesty.producedFreshSnapshot : !honesty.stoodDown
    }

    /// The digest run-mode label a CLI kind reports.
    static func mode(for kind: Kind) -> Schedule.RunMode {
        kind == .collect ? .snapshotOnly : .jamfCLIOnly
    }

    /// A distinct, valid LaunchAgent-style label so CLI runs appear honestly in
    /// Run History (`<prefix>.<profile>.cli-collect` / `.cli-generate`) rather
    /// than being attributed to a scheduled agent.
    static func cliLabel(workspace: WorkspaceID, kind: Kind) -> String {
        let kindSlug = kind == .collect ? "collect" : "generate"
        return "\(LaunchAgentWriter.labelPrefix).\(workspace.labelComponent).cli-\(kindSlug)"
    }

    /// Best-effort setup for an included-CLI run. Resolves the workspace, loads
    /// the profile config (reused if the caller already has it), and opens a Run
    /// History recorder. Never throws — a missing workspace/config or an
    /// un-openable recorder degrades to a run that still executes, just without
    /// the trust signals.
    static func begin(profile: String, kind: Kind, config: ReportConfig? = nil) -> CLIRunSignals {
        let id = WorkspaceID(profile)
        let workspace = id.map { WorkspacePaths.workspaceURL(for: $0) }
        let resolvedConfig = config ?? workspace.flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
        let recorder = id.flatMap {
            ScheduledRunRecorder(
                workspace: WorkspacePaths.workspaceURL(for: $0),
                label: cliLabel(workspace: $0, kind: kind))
        }
        return CLIRunSignals(
            profile: profile, workspace: workspace, config: resolvedConfig,
            mode: mode(for: kind), kind: kind, recorder: recorder,
            honesty: CollectHonestyWatcher()
        )
    }

    /// Commit the run's Needs attention items into this run's status file, naming its log, as a
    /// scheduled run does; without a recorder they land in the app record. Call inside
    /// `AttentionLog.recording`.
    func bindAttention() {
        guard let recorder else { return }
        AttentionLog.current?.record(
            into: recorder.statusURL, runLog: recorder.logURL.lastPathComponent)
    }

    /// Wrap the CLI's own log-line router so every engine line is also recorded
    /// to Run History and watched for the honesty markers. The recorder and
    /// watcher sides are best-effort; `downstream` (the CLI's stdout/stderr
    /// routing) runs unchanged so stdout/exit behavior is preserved.
    func teeing(
        _ downstream: @escaping @Sendable (CLIBridge.LogLine) -> Void
    ) -> @Sendable (CLIBridge.LogLine) -> Void {
        let recorder = self.recorder
        let honesty = self.honesty
        return { line in
            honesty.observe(line.text)
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
        // A cron-driven run gets the same gate the scheduled path has: it exits
        // 0, but must not post a success card or alert on a summary it did not
        // write. Per-kind, because a generate still produced a real workbook —
        // see `announcesSuccess(for:honesty:)`. The `[partial]` line already
        // reached Run History through `teeing`, so the pill is correct either way.
        if announcesSuccess {
            await ScheduledRunSignals.notifyScheduledRun(
                config: config, profile: profile, mode: mode,
                artifact: artifact?.lastPathComponent, sheetFailures: sheetFailures,
                recorder: recorder
            )
            if evaluatesAlerts, let workspace {
                await ScheduledRunSignals.notifyMetricAlerts(
                    config: config, profile: profile, workspace: workspace, recorder: recorder,
                    now: startedAt
                )
            }
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
        // (operator's own workspace, matching HeadlessRun.swift's scheduled path);
        // only the webhook egress below is LogRedactor/DiagnosticRedactor-
        // scrubbed, inside notifyScheduledRunFailure.
        recorder?.record("[error] \(desc)")
        recorder?.finish(exitCode: 1)
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: config, profile: profile, mode: mode,
            errorDescription: desc, recorder: nil, scheduleKey: "cli.\(kind).\(profile)"
        )
    }
}
