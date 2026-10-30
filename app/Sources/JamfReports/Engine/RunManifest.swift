import CryptoKit
import Foundation

/// The per-run manifest: every file a generate run wrote (the workbook, its companion HTML, each
/// file of its CSV folder, and the HTML, PDF and CSV formats a Generate run also chose) with its
/// size and SHA-256, as `<stem>.manifest.json` named after the workbook (else the run's first
/// file). `jamf-reports verify` recomputes it, and the optional RFC 3161 reply (`<stem>.tsr`)
/// dates the manifest's own SHA-256.
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
                "\(ConfigSchema.displayText(name)) is not in the run's report folder"
            }
        }
    }

    /// The manifest of the run whose first file (the workbook, when there is one) is `primary`.
    static func manifestURL(for primary: URL) -> URL {
        primary.deletingLastPathComponent().appendingPathComponent(
            primary.deletingPathExtension().lastPathComponent + manifestSuffix)
    }

    static func timestampURL(for primary: URL) -> URL {
        primary.deletingPathExtension().appendingPathExtension(timestampExtension)
    }

    /// Finder's folder metadata is the one entry a folder of report files may hold that the
    /// run did not write; `build` leaves it out and `verify` does not call it extra.
    static func isIgnored(_ name: String) -> Bool { name == ".DS_Store" }

    /// Each entry of `directory` but `isIgnored` ones, by the one listing rule for a folder a
    /// peer can write (`snapshotFolderEntries`: nil when it is a link or unreadable).
    static func entries(of directory: URL) -> [URL]? {
        FileManager.snapshotFolderEntries(
            in: directory, includingPropertiesForKeys: nil, options: [])?
            .filter { !isIgnored($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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

    /// The top-level entries the manifest at `url` lists that rotation may move with `workbook`:
    /// only what this app's formats write (an `.html`, `.pdf` or `.csv` file, a `_csv` folder),
    /// no hidden name, never another workbook, the manifest or its `.tsr`, and only a regular file
    /// or a real `_csv` folder (`lstat`, a link refused). Empty when the manifest is absent or
    /// unreadable (read bounded, links refused). The manifest is peer-writable, so this is the
    /// whole of what it can make rotation touch.
    static func listedFiles(manifestAt url: URL, besideWorkbook workbook: URL) -> [URL] {
        guard let data = try? BoundedFile.read(url, limit: maxManifestBytes, followSymlinks: false),
              let manifest = try? JSONDecoder().decode(RunManifest.self, from: data)
        else { return [] }
        let folder = url.deletingLastPathComponent()
        var names: [String] = []
        for artifact in manifest.artifacts where isRelativeName(artifact.name) {
            let top = String(artifact.name.split(separator: "/")[0])
            guard !names.contains(top), top != workbook.lastPathComponent,
                  let isFolder = rotatableKind(top) else { continue }
            var info = stat()
            guard lstat(folder.appendingPathComponent(top).path, &info) == 0,
                  (info.st_mode & S_IFMT) == (isFolder ? S_IFDIR : S_IFREG) else { continue }
            names.append(top)
        }
        return names.map { folder.appendingPathComponent($0) }
    }

    /// Whether `name` is a report format rotation may move: true for a `_csv` folder, false for
    /// an `.html`, `.pdf` or `.csv` file, nil for anything else.
    private static func rotatableKind(_ name: String) -> Bool? {
        guard !name.hasPrefix(".") else { return nil }
        if name.hasSuffix(ReportEngine.csvFolderSuffix) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["html", "pdf", "csv"].contains(ext) ? false : nil
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
        return RunManifest(
            generatedAt: ISO8601Time.string(now), generator: "JamfReports \(version)",
            artifacts: entries)
    }

    private static func folderEntries(_ directory: URL, in folder: URL) throws -> [Artifact] {
        let name = directory.lastPathComponent
        guard let files = entries(of: directory) else { throw Failure.unreadable(name) }
        guard files.count <= maxFolderEntries else { throw Failure.tooManyFiles(name) }
        return try files.map { try entry("\(name)/\($0.lastPathComponent)", in: folder) }
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
        let staged = AtomicInstall.stagedURL(for: final)
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
    /// verify. An authority whose chain this Mac does not trust (FreeTSA) is reported, not failed,
    /// unless `expectedSigner` (a SHA-256 of the signer certificate, `--signer-sha256`) is given:
    /// then a missing timestamp, or one signed by any other certificate, fails.
    static func verify(manifestAt url: URL, expectedSigner: String? = nil) -> Verification {
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
            fail("FAIL  \(shown(url.lastPathComponent)) is not a jamf-reports run manifest")
            return result
        }
        let digest = SHA256.hash(data: data).hexString
        result.lines.append("Manifest \(shown(url.lastPathComponent))  sha256 \(digest)")
        result.lines.append(
            "Written \(shown(manifest.generatedAt)) by \(shown(manifest.generator))")
        let folder = url.deletingLastPathComponent()
        var matched = 0
        for artifact in manifest.artifacts {
            let name = shown(artifact.name)
            guard isRelativeName(artifact.name) else {
                fail("FAIL     \(name): not a name inside the manifest's folder")
                continue
            }
            let file = folder.appendingPathComponent(artifact.name)
            guard let print = BoundedFile.fingerprint(file, inside: folder) else {
                var info = stat()
                let gone = lstat(file.path, &info) != 0 && errno == ENOENT
                fail("\(gone ? "MISSING" : "UNREADABLE") \(name)")
                continue
            }
            if print.sha256 == artifact.sha256.lowercased(), print.size == artifact.size {
                matched += 1
                result.lines.append("OK       \(name)")
            } else {
                fail("CHANGED  \(name)")
            }
        }
        for extra in extras(of: manifest, in: folder) { fail("EXTRA    \(shown(extra))") }
        result.lines.append("\(matched) of \(manifest.artifacts.count) artifacts match.")
        verifyTimestamp(
            at: timestampURL(forManifest: url), manifestSHA256: digest,
            expectedSigner: expectedSigner, into: &result)
        return result
    }

    /// Most entries `extras` looks at, and how deep, in the folders a manifest lists.
    static let maxExtraEntriesRead = 500
    private static let maxExtraDepth = 8

    /// What sits in the manifest's folders (a CSV folder) that the manifest does not list: each
    /// file, and an empty subfolder as `<name>/`. Links are not followed; a link counts as an
    /// entry. The manifest's own top-level folder is not checked, since other runs share it.
    static func extras(of manifest: RunManifest, in folder: URL) -> [String] {
        let listed = Set(manifest.artifacts.map(\.name))
        let folders = Set(manifest.artifacts.compactMap { artifact -> String? in
            let parts = artifact.name.split(separator: "/")
            return isRelativeName(artifact.name) && parts.count > 1 ? String(parts[0]) : nil
        })
        var budget = maxExtraEntriesRead
        var found: [String] = []
        for name in folders.sorted() {
            found += unlisted(in: folder.appendingPathComponent(name), named: name,
                              listed: listed, depth: 1, budget: &budget)
        }
        return found
    }

    private static func unlisted(
        in directory: URL, named prefix: String, listed: Set<String>, depth: Int,
        budget: inout Int
    ) -> [String] {
        guard let children = entries(of: directory) else { return [] }
        var found: [String] = []
        for child in children {
            budget -= 1
            guard budget >= 0 else { return found + ["(more entries not checked)"] }
            let name = "\(prefix)/\(child.lastPathComponent)"
            var info = stat()
            let isFolder = lstat(child.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            if isFolder, depth < maxExtraDepth {
                let inner = unlisted(in: child, named: name, listed: listed, depth: depth + 1,
                                     budget: &budget)
                let holdsListed = listed.contains { $0.hasPrefix(name + "/") }
                found += inner.isEmpty && !holdsListed ? [name + "/"] : inner
            } else if !listed.contains(name) {
                found.append(isFolder ? name + "/" : name)
            }
        }
        return found
    }

    /// A field a manifest or token carries, which anyone could have written, as one line. The
    /// CLI's tty escape (`CLIRun.terminalSafe`) runs too: this keeps each field on its own line
    /// for any reader of `lines` (a pipe, a test), that keeps the terminal itself safe.
    private static func shown(_ text: String) -> String {
        let display = ConfigSchema.fullDisplayText(text)
        return display.text + (display.truncated ? " (truncated)" : "")
    }

    private static func verifyTimestamp(
        at url: URL, manifestSHA256: String, expectedSigner: String?,
        into result: inout Verification
    ) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            result.lines.append(
                "Timestamp: none (no \(shown(url.lastPathComponent)) beside the manifest)")
            if expectedSigner != nil {
                result.lines.append("FAIL  --signer-sha256 was given, but the run has no timestamp")
                result.passed = false
            } else {
                result.lines.append(untimestampedNote)
            }
            return
        }
        let inspection: TimestampToken.Inspection
        do {
            let reply = try BoundedFile.read(url, limit: maxReplyBytes, followSymlinks: false)
            inspection = try TimestampToken.inspect(reply: reply)
        } catch {
            result.lines.append("FAIL  timestamp \(shown(url.lastPathComponent)): "
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
        let signer = inspection.signer.map { " by \"\(shown($0))\"" } ?? ""
        result.lines.append("Timestamp: manifest signed \(ISO8601Time.string(inspection.signedAt))"
            + signer)
        if let fingerprint = inspection.signerSHA256 {
            result.lines.append("Timestamp signer certificate SHA-256: \(fingerprint) (compare "
                + "it with the fingerprint the authority publishes)")
        }
        result.lines.append(inspection.chainTrusted
            ? "Timestamp chain: trusted by this Mac"
            : "Timestamp chain: not trusted by this Mac (a self-signed or private authority; "
                + "the time above is what that authority signed)")
        guard let expectedSigner else {
            if !inspection.chainTrusted { result.lines.append(untrustedChainNote) }
            return
        }
        guard let actual = inspection.signerSHA256 else {
            result.lines.append("FAIL  the timestamp carries no signer certificate to compare "
                + "with --signer-sha256")
            result.passed = false
            return
        }
        if actual == expectedSigner {
            result.lines.append("OK    timestamp signer is the expected certificate "
                + "(--signer-sha256)")
        } else {
            result.lines.append("FAIL  timestamp signer is not the expected certificate: "
                + "expected \(expectedSigner), signed by \(actual)")
            result.passed = false
        }
    }

    /// A certificate SHA-256 as people copy it (`openssl x509 -fingerprint -sha256` prints
    /// `AB:CD:...`): colons and spaces dropped, lowercased. Nil unless 64 hex digits remain.
    static func normalizedSignerSHA256(_ text: String) -> String? {
        let hex = text.lowercased().filter { $0 != ":" && !$0.isWhitespace }
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// Anyone who can write the folder can write a manifest that matches the files beside it.
    static let untimestampedNote = "Note: with no timestamp, a match shows only that the files "
        + "equal this manifest; it holds only if you trust where the manifest came from."
    /// A self-signed token can name itself anything; its fingerprint is what can be checked.
    static let untrustedChainNote = "Note: the chain is not trusted, so the timestamp holds only "
        + "if the signer fingerprint above is the one the authority publishes and you trust "
        + "where the manifest came from."

    /// A name below the manifest's folder: no absolute path, no `.`/`..` or empty component.
    static func isRelativeName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.hasPrefix("/") && !parts.isEmpty
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
