import Foundation

// MARK: - CachedDataFallback

/// Implements the `use_cached_data` fallback decision tree from Python's
/// `JamfCLIBridge._run_and_save` (line 3635).
///
/// When a live jamf-cli call fails:
/// - If `useCachedData == false` — the error propagates immediately.
/// - If `useCachedData == true` — the newest cached snapshot is loaded instead.
///
/// When `maxCacheAgeHours > 0` and the cached file is older than the limit,
/// `CLIFallbackError.cacheExpired` is thrown rather than returning stale data.
///
/// `max_cache_age_hours = 0` (default) means no age limit.
enum CachedDataFallback {

    // MARK: - Errors

    enum CLIFallbackError: Error, LocalizedError {
        case noCache(underlying: Error)
        case cacheExpired(path: URL, limitHours: Int)

        var errorDescription: String? {
            switch self {
            case .noCache(let e):
                return "\(e.localizedDescription) | cache fallback: no cached snapshot found."
            case .cacheExpired(let path, let hours):
                return "Cached snapshot is too old (limit: \(hours)h): \(path.lastPathComponent)"
            }
        }
    }

    // MARK: - Source mode

    enum SourceMode: String, Sendable {
        case live
        case cached
        case cachedFallback = "cached-fallback"
    }

    // MARK: - Public API

    /// Attempt a live fetch; fall back to the newest cached snapshot on failure.
    ///
    /// - Parameters:
    ///   - useCachedData: Master fallback switch. When `false`, errors propagate immediately.
    ///   - maxCacheAgeHours: Age limit in hours. `0` means no limit.
    ///   - cacheNames: Snapshot directory/prefix names to search.
    ///   - dataDir: Root directory containing cached snapshots.
    ///   - liveFetch: Async closure that performs the live call and returns raw `Data`.
    ///   - saveSnapshot: Closure called on success to persist the new snapshot atomically.
    /// - Returns: Tuple of `(data, sourceMode)`.
    static func runWithFallback(
        useCachedData: Bool,
        maxCacheAgeHours: Int = 0,
        cacheNames: [String],
        dataDir: URL,
        liveFetch: () async throws -> Data,
        saveSnapshot: (Data) throws -> Void
    ) async throws -> (Data, SourceMode) {
        do {
            let data = try await liveFetch()
            try? saveSnapshot(data)
            return (data, .live)
        } catch {
            guard useCachedData else { throw error }
            return try loadFromCache(
                cacheNames: cacheNames,
                dataDir: dataDir,
                maxCacheAgeHours: maxCacheAgeHours,
                underlyingError: error
            )
        }
    }

    /// Load the newest cached snapshot directly (bypasses live attempt entirely).
    /// Used for `overview(cached_only: True)` equivalent.
    static func loadCachedOnly(
        cacheNames: [String],
        dataDir: URL,
        maxCacheAgeHours: Int = 0
    ) throws -> (Data, SourceMode) {
        return try loadFromCache(
            cacheNames: cacheNames,
            dataDir: dataDir,
            maxCacheAgeHours: maxCacheAgeHours,
            underlyingError: nil
        )
    }

    // MARK: - Internal helpers

    private static func loadFromCache(
        cacheNames: [String],
        dataDir: URL,
        maxCacheAgeHours: Int,
        underlyingError: Error?
    ) throws -> (Data, SourceMode) {
        guard let cachedURL = latestCachedJSON(cacheNames: cacheNames, dataDir: dataDir) else {
            let base: Error = underlyingError
                ?? CLIFallbackError.noCache(underlying: ReportEngineError.noCachedData(dataDir))
            throw CLIFallbackError.noCache(underlying: base)
        }

        if maxCacheAgeHours > 0 {
            let mtime = (try? cachedURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? Date.distantPast
            let ageSeconds = Date().timeIntervalSince(mtime)
            let limitSeconds = Double(maxCacheAgeHours) * 3600
            if ageSeconds > limitSeconds {
                throw CLIFallbackError.cacheExpired(path: cachedURL, limitHours: maxCacheAgeHours)
            }
        }

        let data = try Data(contentsOf: cachedURL)
        print("  [cache] \(cachedURL.path)")
        return (data, .cachedFallback)
    }

    /// Find the newest `.json` file under `<dataDir>/<name>/` or
    /// `<dataDir>/<name>_*.json`. Excludes `.partial` files.
    static func latestCachedJSON(cacheNames: [String], dataDir: URL) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        for name in cacheNames {
            // Subdirectory pattern: <dataDir>/<name>/*.json
            let subdir = dataDir.appendingPathComponent(name, isDirectory: true)
            if let files = try? fm.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                candidates.append(contentsOf: files.filter {
                    $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".partial")
                })
            }
            // Flat pattern: <dataDir>/<name>_*.json
            if let files = try? fm.contentsOfDirectory(
                at: dataDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                candidates.append(contentsOf: files.filter {
                    $0.pathExtension == "json"
                    && $0.lastPathComponent.hasPrefix(name + "_")
                    && !$0.lastPathComponent.hasSuffix(".partial")
                })
            }
        }

        return candidates.max(by: { lhs, rhs in
            let lMod = (try? lhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            let rMod = (try? rhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            return lMod < rMod
        })
    }
}
