import CryptoKit
import Foundation

/// The per-run manifest: every artifact a generate run wrote beside its workbook (the workbook,
/// its companion HTML, each file of its CSV folder) with its size and SHA-256, as
/// `<stem>.manifest.json` beside the workbook. `jamf-reports verify` recomputes it, and the
/// optional RFC 3161 reply (`<stem>.tsr`) dates the manifest's own SHA-256.
struct RunManifest: Codable, Equatable, Sendable {
    static let formatName = "jamf-reports-run-manifest"
    static let manifestSuffix = ".manifest.json"
    static let timestampExtension = "tsr"
    /// A CSV folder holds one file per tab; more than this is not one this app wrote.
    static let maxFolderEntries = 500
    /// A manifest of `maxFolderEntries` names is well under this.
    static let maxManifestBytes = BoundedFile.documentLimit
    /// An RFC 3161 reply with its certificates is a few KB.
    static let maxReplyBytes = 1_048_576

    struct Artifact: Codable, Equatable, Sendable {
        /// Relative to the manifest's folder, `/` between a CSV folder and its file.
        let name: String
        let size: Int
        let sha256: String
    }

    var format = RunManifest.formatName
    var version = 1
    let generatedAt: String
    let generator: String
    let artifacts: [Artifact]

    enum CodingKeys: String, CodingKey {
        case format, version, generator, artifacts
        case generatedAt = "generated_at"
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case tooManyFiles(String)
        case notBeside(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "\(ConfigSchema.displayText(name)) could not be read (a link, not a regular "
                    + "file, or gone)"
            case .tooManyFiles(let name):
                "\(ConfigSchema.displayText(name)) holds more than \(RunManifest.maxFolderEntries) "
                    + "entries"
            case .notBeside(let name):
                "\(ConfigSchema.displayText(name)) is not in the workbook's folder"
            }
        }
    }

    static func manifestURL(besideWorkbook workbook: URL) -> URL {
        workbook.deletingLastPathComponent().appendingPathComponent(
            workbook.deletingPathExtension().lastPathComponent + manifestSuffix)
    }

    static func timestampURL(besideWorkbook workbook: URL) -> URL {
        workbook.deletingPathExtension().appendingPathExtension(timestampExtension)
    }

    /// The `.tsr` that belongs to `manifest`: the same stem.
    static func timestampURL(forManifest manifest: URL) -> URL {
        let name = manifest.lastPathComponent
        let stem = name.hasSuffix(manifestSuffix)
            ? String(name.dropLast(manifestSuffix.count)) : manifest.deletingPathExtension()
                .lastPathComponent
        return manifest.deletingLastPathComponent()
            .appendingPathComponent(stem).appendingPathExtension(timestampExtension)
    }

    // MARK: - Writing

    /// The manifest of `artifacts`, each a file or folder directly in `folder`. Every file is
    /// hashed through `BoundedFile.fingerprint` with `folder` as the root, so a link anywhere
    /// below it is refused and the manifest is not written.
    static func build(artifacts: [URL], in folder: URL, now: Date) throws -> RunManifest {
        var entries: [Artifact] = []
        for artifact in artifacts {
            let name = artifact.lastPathComponent
            guard artifact.deletingLastPathComponent().standardizedFileURL.path
                    == folder.standardizedFileURL.path else { throw Failure.notBeside(name) }
            var info = stat()
            guard lstat(artifact.path, &info) == 0 else { throw Failure.unreadable(name) }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                entries += try folderEntries(artifact, in: folder)
            } else {
                entries.append(try entry(name, in: folder))
            }
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
        return RunManifest(
            generatedAt: stamp.string(from: now), generator: "JamfReports \(version)",
            artifacts: entries)
    }

    private static func folderEntries(_ directory: URL, in folder: URL) throws -> [Artifact] {
        let name = directory.lastPathComponent
        guard let files = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path).filter({ !$0.hasPrefix(".") }).sorted()
        else { throw Failure.unreadable(name) }
        guard files.count <= maxFolderEntries else { throw Failure.tooManyFiles(name) }
        return try files.map { try entry("\(name)/\($0)", in: folder) }
    }

    private static func entry(_ name: String, in folder: URL) throws -> Artifact {
        guard let print = BoundedFile.fingerprint(
            folder.appendingPathComponent(name), inside: folder)
        else { throw Failure.unreadable(name) }
        return Artifact(name: name, size: print.size, sha256: print.sha256)
    }

    /// Pretty, sorted JSON with a final newline, so the bytes hashed are stable.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    /// Writes `data` to a hidden staging file beside `final` (created exclusively, 0600) and puts
    /// it at `final` through `AtomicInstall`, so a link planted at the name is replaced, never
    /// written through.
    static func install(_ data: Data, at final: URL) throws {
        let staged = final.deletingLastPathComponent()
            .appendingPathComponent(".\(final.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                              0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            try AtomicInstall.install(staged, at: final)
        } catch {
            AtomicInstall.discard(staged)
            throw error
        }
    }

    // MARK: - Verifying

    /// What `jamf-reports verify` prints, and whether everything matched.
    struct Verification: Sendable {
        var lines: [String] = []
        var passed = true
    }

    /// Recomputes every artifact's hash against the manifest at `url`, then reads the `.tsr`
    /// beside it (if any): its imprint must be the manifest's own SHA-256 and its signature must
    /// verify. An authority whose chain this Mac does not trust (FreeTSA) is reported, not failed.
    static func verify(manifestAt url: URL) -> Verification {
        var result = Verification()
        func fail(_ line: String) {
            result.lines.append(line)
            result.passed = false
        }
        let data: Data
        do {
            data = try BoundedFile.read(url, limit: maxManifestBytes, followSymlinks: false)
        } catch {
            fail("FAIL  manifest not read: \(error.localizedDescription)")
            return result
        }
        guard let manifest = try? JSONDecoder().decode(RunManifest.self, from: data),
              manifest.format == formatName, manifest.version == 1 else {
            fail("FAIL  \(url.lastPathComponent) is not a jamf-reports run manifest")
            return result
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        result.lines.append("Manifest \(url.lastPathComponent)  sha256 \(digest)")
        result.lines.append("Written \(manifest.generatedAt) by \(manifest.generator)")
        let folder = url.deletingLastPathComponent()
        var matched = 0
        for artifact in manifest.artifacts {
            guard isRelativeName(artifact.name) else {
                fail("FAIL     \(artifact.name): not a name inside the manifest's folder")
                continue
            }
            let file = folder.appendingPathComponent(artifact.name)
            guard let print = BoundedFile.fingerprint(file, inside: folder) else {
                var info = stat()
                let gone = lstat(file.path, &info) != 0 && errno == ENOENT
                fail("\(gone ? "MISSING" : "UNREADABLE") \(artifact.name)")
                continue
            }
            if print.sha256 == artifact.sha256.lowercased(), print.size == artifact.size {
                matched += 1
                result.lines.append("OK       \(artifact.name)")
            } else {
                fail("CHANGED  \(artifact.name)")
            }
        }
        result.lines.append("\(matched) of \(manifest.artifacts.count) artifacts match.")
        verifyTimestamp(at: timestampURL(forManifest: url), manifestSHA256: digest, into: &result)
        return result
    }

    private static func verifyTimestamp(
        at url: URL, manifestSHA256: String, into result: inout Verification
    ) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            result.lines.append("Timestamp: none (no \(url.lastPathComponent) beside the manifest)")
            return
        }
        let inspection: TimestampToken.Inspection
        do {
            let reply = try BoundedFile.read(url, limit: maxReplyBytes, followSymlinks: false)
            inspection = try TimestampToken.inspect(reply: reply)
        } catch {
            result.lines.append("FAIL  timestamp \(url.lastPathComponent): "
                + error.localizedDescription)
            result.passed = false
            return
        }
        guard inspection.imprint == manifestSHA256 else {
            result.lines.append("FAIL  timestamp is for another file: it signs "
                + "\(inspection.imprint), the manifest is \(manifestSHA256)")
            result.passed = false
            return
        }
        guard inspection.signatureValid else {
            result.lines.append("FAIL  timestamp signature does not verify")
            result.passed = false
            return
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let signer = inspection.signer.map { " by \"\($0)\"" } ?? ""
        result.lines.append("Timestamp: manifest signed \(stamp.string(from: inspection.signedAt))"
            + signer)
        result.lines.append(inspection.chainTrusted
            ? "Timestamp chain: trusted by this Mac"
            : "Timestamp chain: not trusted by this Mac (a self-signed or private authority; "
                + "the time above is what that authority signed)")
    }

    /// A name below the manifest's folder: no absolute path, no `.`/`..` or empty component.
    static func isRelativeName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.hasPrefix("/") && !parts.isEmpty
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
