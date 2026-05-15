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
        case corruptedSnapshot(path: URL)

        var errorDescription: String? {
            switch self {
            case .noCache(let e):
                return "\(e.localizedDescription) | cache fallback: no cached snapshot found."
            case .cacheExpired(let path, let hours):
                return "Cached snapshot is too old (limit: \(hours)h): \(path.lastPathComponent)"
            case .corruptedSnapshot(let path):
                return "Cached snapshot is corrupted (not valid JSON): \(path.lastPathComponent)"
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
            do {
                try saveSnapshot(data)
            } catch {
                AppLogger.engine.warning("Cache write failed: \(error.localizedDescription)")
            }
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
        // S-01: candidate list is sorted newest-first; iterate so a
        // truncated newest file falls through to the next valid one
        // rather than crashing the caller. Returning the first
        // syntactically-valid candidate is safer than failing outright
        // when older valid data is available on disk.
        let candidates = cachedJSONCandidatesNewestFirst(cacheNames: cacheNames, dataDir: dataDir)
        guard !candidates.isEmpty else {
            let base: Error = underlyingError
                ?? CLIFallbackError.noCache(underlying: ReportEngineError.noCachedData(dataDir))
            throw CLIFallbackError.noCache(underlying: base)
        }

        var lastCorruptedURL: URL?
        for cachedURL in candidates {
            if maxCacheAgeHours > 0 {
                let mtime = (try? cachedURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate ?? Date.distantPast
                let ageSeconds = Date().timeIntervalSince(mtime)
                let limitSeconds = Double(maxCacheAgeHours) * 3600
                if ageSeconds > limitSeconds {
                    // First out-of-window file means the whole list is
                    // older (since we iterate newest-first) — fail with
                    // cacheExpired against the newest candidate.
                    throw CLIFallbackError.cacheExpired(path: cachedURL, limitHours: maxCacheAgeHours)
                }
            }

            guard let data = try? Data(contentsOf: cachedURL) else { continue }
            // Reject malformed JSON — a truncated snapshot must not
            // reach the decoder. JSONSerialization is the cheapest
            // structural check that catches every case the decoder
            // would.
            guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                AppLogger.engine.warning(
                    "Cached snapshot rejected as corrupted: \(cachedURL.lastPathComponent, privacy: .public)"
                )
                lastCorruptedURL = cachedURL
                continue
            }
            print("  [cache] \(cachedURL.path)")
            return (data, .cachedFallback)
        }

        if let corrupted = lastCorruptedURL {
            throw CLIFallbackError.corruptedSnapshot(path: corrupted)
        }
        let base: Error = underlyingError
            ?? CLIFallbackError.noCache(underlying: ReportEngineError.noCachedData(dataDir))
        throw CLIFallbackError.noCache(underlying: base)
    }

    /// Return every cached `.json` candidate matching either layout,
    /// sorted newest-first by modification time. Used by `loadFromCache`
    /// so a truncated newest file can fall through to the next valid
    /// candidate. Excludes `.partial` files.
    static func cachedJSONCandidatesNewestFirst(cacheNames: [String], dataDir: URL) -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []

        for name in cacheNames {
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

        return candidates.sorted(by: { lhs, rhs in
            let lMod = (try? lhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            let rMod = (try? rhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? .distantPast
            return lMod > rMod
        })
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
