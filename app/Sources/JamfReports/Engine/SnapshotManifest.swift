import Foundation
import CryptoKit

/// Reads SHA-256 manifests written by the Python collector alongside every
/// cached jamf-cli JSON snapshot. Lets the Swift engine detect tampering
/// between collect (Python) and generate (Swift), per threat-model T-2
/// (Google Gemini security-review 2026-05-12).
///
/// `verify` returns the `VerificationResult` so callers can surface UI
/// state like "Unverified snapshot" (PR-10, threat-model T-11). Callers
/// may ignore the return value via `@discardableResult`. The engine side
/// preserves no-abort behavior — a tampered file and a partial-collect
/// (Python crashed before manifest rewrite) look identical at this layer,
/// so strict aborting lives behind the Python `--strict-manifest` flag /
/// `jamf_cli.require_manifest` config gate, not in the Swift engine.
enum SnapshotManifest {

    /// On-disk filename, kept in lockstep with the Python constant.
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
    /// strict-mode aborting lives in the Python collector.
    @discardableResult
    static func verify(snapshot: URL, data: Data) -> VerificationResult {
        let manifestURL = snapshot.deletingLastPathComponent()
            .appendingPathComponent(fileName)
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            return .absent
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            AppLogger.engine.warning(
                "SnapshotManifest: manifest.json present but unparseable for \(snapshot.lastPathComponent, privacy: .public)"
            )
            return .corrupt
        }
        guard let expected = manifest.files[snapshot.lastPathComponent] else {
            return .omitted
        }
        let actual = sha256Hex(data)
        if actual.lowercased() != expected.lowercased() {
            AppLogger.engine.warning(
                "SnapshotManifest: SHA-256 mismatch for \(snapshot.lastPathComponent, privacy: .public) — expected \(String(expected.prefix(12)), privacy: .public)…, got \(String(actual.prefix(12)), privacy: .public)…"
            )
            return .mismatch
        }
        return .verified
    }

    // MARK: - Workspace scan (PR-10, T-11)

    /// Aggregate counts produced by ``scanWorkspace(dataDir:)``. Each
    /// snapshot directory under `jamf-cli-data/` contributes the result
    /// of verifying its newest snapshot.
    struct WorkspaceVerificationSummary: Equatable, Sendable {
        var verified: Int = 0
        var absent: Int = 0
        var corrupt: Int = 0
        var omitted: Int = 0
        var mismatch: Int = 0

        /// Snapshots that did not cleanly verify. AuditView surfaces an
        /// "Unverified snapshot" card when this is > 0.
        var unverified: Int { absent + corrupt + omitted + mismatch }
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

    private static func newestSnapshot(in typeDir: URL, fm: FileManager) -> URL? {
        guard let entries = try? fm.contentsOfDirectory(
            at: typeDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
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
        return candidates.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return l < r
        }
    }

    // MARK: - Manifest payload

    private struct Manifest: Decodable {
        let algorithm: String
        let files: [String: String]
    }

    // MARK: - SHA-256

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
