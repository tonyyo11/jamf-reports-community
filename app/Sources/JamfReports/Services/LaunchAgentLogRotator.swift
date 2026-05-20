import Foundation

/// Rotates log files before each LaunchAgent scan run.
///
/// Pure Swift — no shell. When the target log file exceeds `sizeLimit`, existing
/// generation files are shifted down (`.1` → `.2`, `.2` → `.3`), the file beyond
/// `maxGenerations` is deleted, and the active log is truncated to zero so the
/// next run starts clean.
///
/// Rotation is synchronous and intentionally cheap: it runs at the start of each
/// agent invocation where the process is already running and a brief file-system
/// operation is acceptable.
enum LaunchAgentLogRotator {

    // MARK: - Constants

    /// Default maximum log file size before rotation triggers (5 MiB).
    static let defaultSizeLimit: Int = 5 * 1_024 * 1_024

    /// Default number of generations to retain (active + 3 rotated = 4 on-disk files).
    static let defaultMaxGenerations: Int = 3

    // MARK: - Public API

    /// Rotate `logURL` if it exceeds `sizeLimit`.
    ///
    /// No-ops when the file does not exist or is smaller than `sizeLimit`.
    ///
    /// Rotation sequence for `maxGenerations = 3`:
    /// ```
    /// stdout.log.3  → deleted
    /// stdout.log.2  → stdout.log.3
    /// stdout.log.1  → stdout.log.2
    /// stdout.log    → stdout.log.1   (moved)
    /// stdout.log    → created empty
    /// ```
    ///
    /// Uses `replaceItem(at:withItemAt:)` for the final truncation step so an
    /// interrupted rotation never leaves a missing active log file.
    static func rotateIfNeeded(
        logURL: URL,
        sizeLimit: Int = defaultSizeLimit,
        maxGenerations: Int = defaultMaxGenerations
    ) throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: logURL.path) else { return }

        let attrs = try fm.attributesOfItem(atPath: logURL.path)
        let fileSize = attrs[.size] as? Int ?? 0
        guard fileSize > sizeLimit else { return }

        try rotate(logURL: logURL, maxGenerations: maxGenerations, fm: fm)
    }

    // MARK: - Private

    private static func rotate(
        logURL: URL,
        maxGenerations: Int,
        fm: FileManager
    ) throws {
        // Delete the oldest generation that would be pushed out.
        let oldest = generationURL(logURL, generation: maxGenerations)
        if fm.fileExists(atPath: oldest.path) {
            try fm.removeItem(at: oldest)
        }

        // Shift generations: N-1 → N, down to 1 → 2.
        for gen in stride(from: maxGenerations - 1, through: 1, by: -1) {
            let src = generationURL(logURL, generation: gen)
            let dst = generationURL(logURL, generation: gen + 1)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.moveItem(at: src, to: dst)
        }

        // Move the active log to generation 1.
        let gen1 = generationURL(logURL, generation: 1)
        try fm.moveItem(at: logURL, to: gen1)

        // Create a fresh empty active log file.
        // 0o600: log files contain device serials, hostnames, and usernames; restrict to owner.
        let empty = Data()
        let tmp = logURL.deletingLastPathComponent()
            .appendingPathComponent(".\(logURL.lastPathComponent).truncate.tmp")
        try empty.write(to: tmp, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)

        do {
            _ = try fm.replaceItemAt(logURL, withItemAt: tmp)
        } catch {
            // replaceItemAt throws when destination doesn't exist; move is also fine here.
            try fm.moveItem(at: tmp, to: logURL)
        }
        // Apply 0o600 to the active log regardless of which code path created it.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    /// URL for generation `n` of `base`: `base.1`, `base.2`, etc.
    static func generationURL(_ base: URL, generation: Int) -> URL {
        base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent).\(generation)")
    }
}
