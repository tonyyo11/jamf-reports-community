import Foundation
import CryptoKit

/// Reads and verifies SHA-256 manifests that stamp cached jamf-cli JSON
/// snapshots, so the engine can detect tampering between collect and
/// generate (threat-model T-2, Google Gemini security-review 2026-05-12).
///
/// A Swift snapshot-manifest WRITER (``record(snapshotFile:data:)``, 2.6
/// accuracy track) stamps each snapshot's sibling `manifest.json` as the
/// engine saves it, gated on `jamf_cli.require_manifest`. Before this,
/// `verify` returned `.absent` for every app-collected snapshot (the only
/// writer was the now-removed Python collector) and `.mismatch` was
/// unreachable, so the strict-mode gate had nothing to satisfy. The writer
/// mirrors ``verify``'s filename/location contract exactly so a
/// write→verify round-trip yields `.verified`.
///
/// `verify` returns the `VerificationResult` so callers can surface UI
/// state like "Unverified snapshot" (PR-10, threat-model T-11). Callers
/// may ignore the return value via `@discardableResult`. A tampered file
/// and a missing manifest look identical at this layer, so strict aborting
/// lives behind the `jamf_cli.require_manifest` config gate, not here.
enum SnapshotManifest {

    /// On-disk filename of a snapshot manifest.
    static let fileName = "manifest.json"

    /// Outcome of `verify`. Inspect to surface UI state; ignore to keep
    /// the engine's existing no-abort behavior.
    enum VerificationResult: Equatable, Sendable {
        /// `manifest.json` exists, lists the snapshot, hashes match.
        case verified
        /// `manifest.json` does not exist — legacy snapshots from
        /// pre-PR-7 collectors, or an attacker who deleted the manifest.
        case absent
        /// `manifest.json` exists but is unparseable — bit-rot, partial
        /// write, or attacker corruption of the manifest itself.
        case corrupt
        /// Manifest parses, but does not list this snapshot's filename —
        /// partial collect (Python crashed before completing the rewrite).
        case omitted
        /// Manifest lists the file, but the SHA-256 does not match —
        /// the most-likely-tampered case.
        case mismatch
    }

    /// Verify ``data`` matches the manifest entry for ``snapshot``'s sibling
    /// `manifest.json`. Returns the verification outcome but does NOT abort —
    /// strict-mode aborting lives in `ReportEngine.preflightStrictManifestCheck`.
    @discardableResult
    static func verify(snapshot: URL, data: Data) -> VerificationResult {
        let manifestURL = snapshot.deletingLastPathComponent()
            .appendingPathComponent(fileName)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            return .absent
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            AppLogger.report.warning(
                "SnapshotManifest: manifest.json present but unparseable for \(snapshot.lastPathComponent, privacy: .public)"
            )
            return .corrupt
        }
        guard let expected = manifest.files[snapshot.lastPathComponent] else {
            return .omitted
        }
        let actual = sha256Hex(data)
        if actual.lowercased() != expected.lowercased() {
            AppLogger.report.warning(
                "SnapshotManifest: SHA-256 mismatch for \(snapshot.lastPathComponent, privacy: .public) — expected \(String(expected.prefix(12)), privacy: .public)…, got \(String(actual.prefix(12)), privacy: .public)…"
            )
            return .mismatch
        }
        return .verified
    }

    // MARK: - Writer (2.6 accuracy track)

    /// Stamp ``snapshotFile``'s sibling `manifest.json` with the SHA-256 of
    /// ``data``, read-modify-writing any existing manifest so sibling
    /// snapshots keep their entries. Called from `ReportEngine.saveSnapshot`
    /// only when `jamf_cli.require_manifest` is set — otherwise the strict-mode
    /// gate (``verify`` ⇒ `.mismatch`/`.corrupt`) can never fire on
    /// app-collected data.
    ///
    /// Mirrors ``verify``'s contract exactly: the manifest is a sibling of the
    /// snapshot, keyed by ``snapshotFile``'s `lastPathComponent`, valued with
    /// the lowercase hex digest. A pre-existing but UNPARSEABLE manifest is
    /// tolerated — it is logged and replaced with a fresh one rather than
    /// aborting the collect (a corrupt manifest must not block data capture).
    /// The write is atomic (temp file + `replaceItem`) with `0o600` perms.
    ///
    /// **Concurrency note:** this read-modify-write has no cross-process lock.
    /// If the GUI and a LaunchAgent collect the SAME kind at the same moment,
    /// one writer's entry can be lost to the other's read-before-write. This
    /// fails SAFE: the lost entry makes that snapshot's next `verify` return
    /// `.omitted` (unverifiable), never a false `.verified` for tampered data.
    /// Same-kind concurrent collects are already rare — the once-per-day
    /// collect guard means this race needs two independent trigger paths
    /// (GUI + schedule) landing in the same narrow window.
    static func record(snapshotFile: URL, data: Data) throws {
        let dir = snapshotFile.deletingLastPathComponent()
        let manifestURL = dir.appendingPathComponent(fileName)

        var files: [String: String] = [:]
        if let existingData = try? Data(contentsOf: manifestURL) {
            if let existing = try? JSONDecoder().decode(Manifest.self, from: existingData) {
                files = existing.files
            } else {
                AppLogger.collect.warning(
                    "SnapshotManifest: existing manifest.json unparseable in \(dir.lastPathComponent, privacy: .public) — starting fresh"
                )
            }
        }
        files[snapshotFile.lastPathComponent] = sha256Hex(data)

        let manifest = Manifest(
            version: currentSchemaVersion,
            algorithm: "SHA256",
            files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(manifest)
        try writeAtomically(payload, to: manifestURL)
    }

    /// Atomic manifest write: stage to a sibling temp file with `0o600`, then
    /// `replaceItem` into place (falling back to `.atomic` write when there is
    /// no existing file to replace). Keeps a half-written manifest from ever
    /// being observed by `verify`.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [.atomic])
        try? fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tmp.path
        )
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try? fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Workspace scan (PR-10, T-11)

    /// Aggregate counts produced by ``scanWorkspace(dataDir:)`` and
    /// ``scanFlatDir(_:)``. Each snapshot directory contributes the
    /// result of verifying its files.
    struct WorkspaceVerificationSummary: Equatable, Sendable {
        var verified: Int = 0
        var absent: Int = 0
        var corrupt: Int = 0
        var omitted: Int = 0
        var mismatch: Int = 0

        /// Snapshots that did not cleanly verify. AuditView surfaces an
        /// "Unverified snapshot" card when this is > 0.
        var unverified: Int { absent + corrupt + omitted + mismatch }

        /// Combine two summary regions (e.g. `jamf-cli-data/` + `summaries/`).
        static func + (lhs: Self, rhs: Self) -> Self {
            Self(
                verified: lhs.verified + rhs.verified,
                absent: lhs.absent + rhs.absent,
                corrupt: lhs.corrupt + rhs.corrupt,
                omitted: lhs.omitted + rhs.omitted,
                mismatch: lhs.mismatch + rhs.mismatch
            )
        }
    }

    /// Walks `<dataDir>/<type>/`, verifies the newest JSON in each, and
    /// reports aggregate counts. Returns a zeroed summary when ``dataDir``
    /// does not exist or has no snapshot subdirectories.
    ///
    /// Bounded by the directory walk — no recursion below `<type>/` — so
    /// safe to call from a SwiftUI `.task` modifier on view appear.
    static func scanWorkspace(dataDir: URL) -> WorkspaceVerificationSummary {
        var summary = WorkspaceVerificationSummary()
        let fm = FileManager.default
        guard let typeDirs = try? fm.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return summary }

        for typeDir in typeDirs {
            let isDir = (try? typeDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let newest = newestSnapshot(in: typeDir, fm: fm) else { continue }
            guard let data = try? Data(contentsOf: newest) else { continue }
            switch verify(snapshot: newest, data: data) {
            case .verified: summary.verified += 1
            case .absent:   summary.absent += 1
            case .corrupt:  summary.corrupt += 1
            case .omitted:  summary.omitted += 1
            case .mismatch: summary.mismatch += 1
            }
        }
        return summary
    }

    /// Verify EVERY `.json` file directly inside `dir` (no recursion, no
    /// "newest-only" filtering). Used for `snapshots/computers/summaries/`
    /// where each per-LaunchAgent summary is independently meaningful.
    /// Returns a zeroed summary when `dir` does not exist.
    ///
    /// PR-11 / threat-model T-12 / security-reviewer 2nd pass S-01: closes
    /// the AuditView coverage gap where `scanWorkspace(dataDir:)` only
    /// walked `jamf-cli-data/` and missed tampered per-log summaries.
    static func scanFlatDir(_ dir: URL) -> WorkspaceVerificationSummary {
        var summary = WorkspaceVerificationSummary()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return summary }
        let candidates = entries.filter {
            $0.pathExtension.lowercased() == "json"
            && !$0.lastPathComponent.hasSuffix(fileName)
        }
        for snapshot in candidates {
            guard let data = try? Data(contentsOf: snapshot) else { continue }
            switch verify(snapshot: snapshot, data: data) {
            case .verified: summary.verified += 1
            case .absent:   summary.absent += 1
            case .corrupt:  summary.corrupt += 1
            case .omitted:  summary.omitted += 1
            case .mismatch: summary.mismatch += 1
            }
        }
        return summary
    }

    /// PR-22 T-14: verify EVERY `.last` file directly inside `dir` against
    /// its sibling `manifest.json`. Used by AuditView to detect tampering
    /// of cadence state files — an attacker who rewrites `<report>.last`
    /// with a future timestamp would otherwise quietly defer fetches.
    ///
    /// Returns a zeroed summary when `dir` does not exist (a pre-PR-22
    /// workspace with no state files is not a failure). Mirrors
    /// `scanFlatDir`'s structure but filters on `.last` instead of `.json`.
    static func scanStateDir(_ dir: URL) -> WorkspaceVerificationSummary {
        var summary = WorkspaceVerificationSummary()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return summary }
        let candidates = entries.filter { $0.pathExtension.lowercased() == "last" }
        for snapshot in candidates {
            guard let data = try? Data(contentsOf: snapshot) else { continue }
            switch verify(snapshot: snapshot, data: data) {
            case .verified: summary.verified += 1
            case .absent:   summary.absent += 1
            case .corrupt:  summary.corrupt += 1
            case .omitted:  summary.omitted += 1
            case .mismatch: summary.mismatch += 1
            }
        }
        return summary
    }

    private static func newestSnapshot(in typeDir: URL, fm: FileManager) -> URL? {
        guard let entries = try? fm.contentsOfDirectory(
            at: typeDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        // PR-10 / security-reviewer SHOULD-FIX: exclude not just `manifest.json`
        // but anything ending in `manifest.json` (e.g. attacker-planted
        // `xmanifest.json` that would otherwise be picked as a candidate
        // and produce a misleading verification result).
        let candidates = entries.filter {
            $0.pathExtension.lowercased() == "json"
            && !$0.lastPathComponent.hasSuffix(fileName)
        }
        // Order by FILENAME timestamp, matching loadLatestSnapshotData — mtime
        // lies on synced storage, so it could verify a file generate won't read.
        return candidates.max { lhs, rhs in
            MSCPChartDataBuilder.dateFromSnapshotFilename(lhs)
                < MSCPChartDataBuilder.dateFromSnapshotFilename(rhs)
        }
    }

    // MARK: - Manifest payload

    /// Schema version. PR-22 T-14 bumps this from the implicit v1 (Python
    /// PR-7 + threat-model T-2) to v2 to indicate state-aware manifests
    /// (Swift-written, may include `<report>.last` entries). Old manifests
    /// without a `version` field decode as v1.
    static let currentSchemaVersion = 2

    private struct Manifest: Codable {
        /// Optional to preserve compat with v1 manifests written by the
        /// Python collector pre-PR-22. Treat absent ⇒ 1. The writer always
        /// emits ``currentSchemaVersion``.
        let version: Int?
        let algorithm: String
        let files: [String: String]
    }

    // MARK: - SHA-256

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
