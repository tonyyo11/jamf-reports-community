import Foundation

/// `pro report compliance-rules` and `compliance-devices` need a benchmark title (cobra
/// `ExactArgs(1)`); called bare they exit 2 on every Platform API profile. Collect lists the
/// tenant's benchmarks once per run, runs both reports per title, and saves one snapshot per
/// kind whose rows carry a `benchmark` field.
extension ReportEngine {

    static let benchmarkReportKinds: Set<String> = ["compliance-rules", "compliance-devices"]

    typealias BenchmarkPiece = (title: String, data: Data)

    struct BenchmarkSelection: Equatable, Sendable {
        let titles: [String]
        /// Listed in `platform.compliance_benchmarks` but not on the tenant.
        let missing: [String]
        /// Held by more than one benchmark ID; jamf-cli refuses these by name.
        let ambiguous: [String]
        /// Starts with "-"; jamf-cli would parse it as a flag, not a title.
        var unsafe: [String] = []
        /// Every title the tenant lists, in listing order, for the hint when none of the
        /// configured titles can be collected.
        var listed: [String] = []
    }

    /// The once-per-run benchmark listing, shared by both compliance kinds.
    enum BenchmarkDiscovery: Sendable {
        case selected(BenchmarkSelection)
        case failed(exitCode: Int32, data: Data)
        case launchFailed
    }

    static func benchmarkListArguments(profile: String) -> [String] {
        ["-p", profile, "pro", "compliance-benchmarks", "list", "--output", "json"]
    }

    /// Titles from `compliance-benchmarks list`, narrowed to `configured` when it is set.
    /// nil when the output is neither a JSON array nor `{"benchmarks": [...]}`.
    static func benchmarkSelection(
        fromListOutput data: Data, configured: [String]
    ) -> BenchmarkSelection? {
        guard let items = benchmarkListItems(data) else { return nil }
        var idsByTitle: [String: Set<String>] = [:]
        var listed: [String] = []
        for (index, item) in items.enumerated() {
            guard let title = item["title"] as? String, !title.isEmpty else { continue }
            if idsByTitle[title] == nil { listed.append(title) }
            idsByTitle[title, default: []].insert(item["id"] as? String ?? "row-\(index)")
        }
        let ambiguous = listed.filter { (idsByTitle[$0]?.count ?? 0) > 1 }
        let unsafe = listed.filter { !CLIBridge.isSafeDeviceIdentifier($0) }
        let usable = listed.filter { !ambiguous.contains($0) && !unsafe.contains($0) }
        guard !configured.isEmpty else {
            return BenchmarkSelection(
                titles: usable, missing: [], ambiguous: ambiguous, unsafe: unsafe,
                listed: listed)
        }
        return BenchmarkSelection(
            titles: configured.filter { usable.contains($0) },
            missing: configured.filter { idsByTitle[$0] == nil },
            ambiguous: ambiguous.filter { configured.contains($0) },
            unsafe: unsafe.filter { configured.contains($0) },
            listed: listed
        )
    }

    /// Inserts `title` as the report's positional argument, ahead of its flags.
    static func benchmarkReportArguments(_ base: [String], title: String) -> [String] {
        var arguments = base
        let flags = base.firstIndex { $0.hasPrefix("--") } ?? base.endIndex
        arguments.insert(title, at: flags)
        return arguments
    }

    /// Per-title report outputs as one JSON array, each row tagged with its benchmark.
    /// Blank output is an empty report. nil when any output is not a JSON array.
    static func mergedBenchmarkPayload(_ pieces: [BenchmarkPiece]) -> Data? {
        var rows: [[String: Any]] = []
        for piece in pieces where !isBlank(piece.data) {
            guard let payload = jsonPayload(from: piece.data),
                  let items = try? JSONSerialization.jsonObject(with: payload) as? [[String: Any]]
            else { return nil }
            for var row in items {
                row["benchmark"] = piece.title
                rows.append(row)
            }
        }
        return try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    }

    private static func benchmarkListItems(_ data: Data) -> [[String: Any]]? {
        guard !isBlank(data) else { return [] }
        guard let payload = jsonPayload(from: data),
              let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        if let array = object as? [[String: Any]] { return array }
        return (object as? [String: Any])?["benchmarks"] as? [[String: Any]]
    }

    /// Whitespace only — what jamf-cli leaves on stdout for an empty report.
    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    /// One compliance kind's attempt: list benchmarks (once per run, cached in `discovery`),
    /// run the report per title, and save the merged rows.
    static func collectBenchmarkReport(
        kind: String,
        profile: String,
        arguments: [String],
        configuredTitles: [String],
        discovery: inout BenchmarkDiscovery?,
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
        onLine(.init(timestamp: Date(), level: .info,
                     text: "[info] collecting \(kind) for \(profile)"))
        let resolved: BenchmarkDiscovery
        if let cached = discovery {
            resolved = cached
        } else {
            resolved = await discoverBenchmarks(
                kind: kind, profile: profile, configuredTitles: configuredTitles,
                supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge, onLine: onLine)
            discovery = resolved
        }
        let titles: [String]
        switch resolved {
        case .launchFailed:
            stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
            return KindCollectResult(
                outcome: CollectOutcome(kind: kind, exitCode: launchFailureExitCode), saved: false)
        case .failed(let exitCode, let data):
            return try recordUnlandedAttempt(
                kind: kind, exitCode: exitCode, data: data, useCachedData: useCachedData,
                dataDir: dataDir, stateStore: stateStore, collectStart: collectStart,
                onLine: onLine)
        case .selected(let selection):
            // Titles were configured and none can be collected: a benchmark ID, a typo, the
            // Add button's placeholder or a renamed benchmark. Saving `[]` here recorded a
            // success and put an empty snapshot in front of the last good one.
            if selection.titles.isEmpty, !configuredTitles.isEmpty {
                return try recordUncollectableSelection(
                    kind: kind, selection: selection, configuredTitles: configuredTitles,
                    dataDir: dataDir, useCachedData: useCachedData, stateStore: stateStore,
                    collectStart: collectStart, onLine: onLine)
            }
            titles = selection.titles
        }

        var pieces: [BenchmarkPiece] = []
        // Exit 7 on any title makes the merged kind partial, not a clean success.
        var sawPartialFailure = false
        for title in titles {
            let captured = await invokeWithRetry(
                kind: kind, arguments: benchmarkReportArguments(arguments, title: title),
                supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge, onLine: onLine)
            guard let (exitCode, data) = captured else {
                stateStore?.record(.failed(exitCode: nil), report: kind, at: collectStart)
                return KindCollectResult(
                    outcome: CollectOutcome(kind: kind, exitCode: launchFailureExitCode),
                    saved: false)
            }
            guard exitCode == 0 || exitCode == CLIBridge.exitCodePartialFailure else {
                return try recordUnlandedAttempt(
                    kind: kind, exitCode: exitCode, data: data, useCachedData: useCachedData,
                    dataDir: dataDir, stateStore: stateStore, collectStart: collectStart,
                    onLine: onLine)
            }
            if exitCode == CLIBridge.exitCodePartialFailure { sawPartialFailure = true }
            pieces.append((title: title, data: data))
        }

        let mergedExitCode = sawPartialFailure ? CLIBridge.exitCodePartialFailure : 0
        let success = CollectOutcome(kind: kind, exitCode: mergedExitCode)
        guard let merged = mergedBenchmarkPayload(pieces) else {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] \(kind): output is not JSON (renamed/unsupported "
                    + "command on this jamf-cli?) — snapshot not saved"))
            stateStore?.record(.failed(exitCode: success.exitCode), report: kind, at: collectStart)
            return KindCollectResult(outcome: success, saved: false)
        }
        return try saveCollectedPayload(
            kind: kind, data: merged, outcome: success, isPartialFailure: sawPartialFailure,
            dataDir: dataDir, recordManifest: recordManifest, stateStore: stateStore,
            collectStart: collectStart, onLine: onLine
        )
    }

    /// Fails `kind` because none of the configured titles can be collected, as a failed jamf-cli
    /// attempt would (`recordUnlandedAttempt`): nothing is saved, so the last snapshot stays
    /// the newest, and the cause names the configured titles and what the tenant lists.
    static func recordUncollectableSelection(
        kind: String,
        selection: BenchmarkSelection,
        configuredTitles: [String],
        dataDir: URL,
        useCachedData: Bool,
        stateStore: StateFileStore?,
        collectStart: Date,
        onLine: @Sendable (CLIBridge.LogLine) -> Void
    ) throws -> KindCollectResult {
        let tenant = selection.listed.isEmpty
            ? "This tenant lists no benchmarks."
            : "This tenant lists: " + selection.listed.joined(separator: "; ") + "."
        let hint = "Titles must match exactly, case included. \(tenant) "
            + "Leave the list empty to collect every benchmark."
        let cause = FailureCause(
            kind: .noConfiguredBenchmark, names: configuredTitles,
            hint: String(decoding: hint.utf8.prefix(FailureCause.hintByteLimit), as: UTF8.self),
            exitCode: 0)
        stateStore?.record(.failed(exitCode: 0), report: kind, at: collectStart, cause: cause)
        guard useCachedData else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] \(kind): nothing to collect\(causeSuffix(cause)) "
                            + "— failing (use_cached_data=false)"))
            throw ReportEngineError.collectFailed(kind: kind, exitCode: 0)
        }
        let kindDir = dataDir.appendingPathComponent(kind, isDirectory: true)
        let cacheNote = FileManager.newestJSONFile(in: kindDir) != nil
            ? "skipped (using cached)"
            : "no cached snapshot available"
        onLine(.init(timestamp: Date(), level: .warn,
                     text: "[warn] \(kind): \(cacheNote)" + causeSuffix(cause)))
        return KindCollectResult(
            outcome: CollectOutcome(kind: kind, exitCode: 0, cause: cause.kind), saved: false)
    }

    static func discoverBenchmarks(
        kind: String,
        profile: String,
        configuredTitles: [String],
        supportsQuietFlags: Bool,
        bin: URL,
        bridge: CLIBridge,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> BenchmarkDiscovery {
        let captured = await invokeWithRetry(
            kind: kind, arguments: benchmarkListArguments(profile: profile),
            supportsQuietFlags: supportsQuietFlags, bin: bin, bridge: bridge, onLine: onLine)
        guard let (exitCode, data) = captured else { return .launchFailed }
        guard exitCode == 0,
              let selection = benchmarkSelection(fromListOutput: data, configured: configuredTitles)
        else { return .failed(exitCode: exitCode, data: data) }
        // `[info]`, not `[warn]`/`[skip]`: the setup screen tallies those prefixes per kind.
        func info(_ text: String) { onLine(.init(timestamp: Date(), level: .info, text: text)) }
        info("[info] compliance benchmarks to collect: \(selection.titles.count)")
        if !selection.missing.isEmpty {
            info("[info] compliance benchmarks not on this tenant, skipped: "
                + selection.missing.joined(separator: ", "))
        }
        if !selection.ambiguous.isEmpty {
            info("[info] compliance benchmarks sharing a title, skipped (jamf-cli selects by "
                + "title): " + selection.ambiguous.joined(separator: ", "))
        }
        if !selection.unsafe.isEmpty {
            info("[info] compliance benchmarks with a title starting with \"-\", skipped: "
                + selection.unsafe.joined(separator: ", "))
        }
        return .selected(selection)
    }
}
