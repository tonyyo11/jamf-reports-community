import Foundation
import CryptoKit

/// Reads SHA-256 manifests written by the Python collector alongside every
/// cached jamf-cli JSON snapshot. Lets the Swift engine detect tampering
/// between collect (Python) and generate (Swift), per threat-model T-2
/// (Google Gemini security-review 2026-05-12).
///
/// On hash mismatch this logs an `AppLogger.engine` warning and returns —
/// it does NOT abort. Rationale: a tampered file and a partial-collect
/// (Python crashed before manifest rewrite) look identical at this layer.
/// Strict aborting lives behind the Python `--strict-manifest` flag and is
/// not surfaced through the Swift engine.
///
/// Manifest absence is treated as "no check" (legacy snapshots written by
/// pre-PR-7 collectors do not carry a manifest).
enum SnapshotManifest {

    /// On-disk filename, kept in lockstep with the Python constant.
    static let fileName = "manifest.json"

    /// Verify ``data`` matches the manifest entry for ``snapshot``'s sibling
    /// `manifest.json`. No-op when the manifest is absent or omits this file.
    static func verify(snapshot: URL, data: Data) {
        let manifestURL = snapshot.deletingLastPathComponent()
            .appendingPathComponent(fileName)
        guard let manifestData = try? Data(contentsOf: manifestURL) else { return }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              let expected = manifest.files[snapshot.lastPathComponent] else {
            return
        }
        let actual = sha256Hex(data)
        if actual.lowercased() != expected.lowercased() {
            AppLogger.engine.warning(
                "SnapshotManifest: SHA-256 mismatch for \(snapshot.lastPathComponent, privacy: .public) — expected \(String(expected.prefix(12)), privacy: .public)…, got \(String(actual.prefix(12)), privacy: .public)…"
            )
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
