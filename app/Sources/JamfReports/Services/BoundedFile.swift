import CryptoKit
import Foundation

/// A read of a file another Mac can write, bounded in size and type. The file is opened once
/// (non-blocking, so a FIFO planted at the name cannot hang the open), its type is checked on
/// that descriptor, and the bytes come from the same descriptor, so the check and the read
/// cannot be about two different files.
enum BoundedFile {

    enum Failure: LocalizedError, Equatable {
        /// A FIFO, device, socket or directory.
        case notRegular
        /// More than `limit` bytes; `read` stopped at `limit + 1`.
        case tooLarge
        /// `open` or `read` failed with this errno (ENOENT is a missing file).
        case unreadable(Int32)

        var errorDescription: String? {
            switch self {
            case .notRegular: "not a regular file"
            case .tooLarge: "larger than the read limit"
            case .unreadable(let code): "could not be read: \(String(cString: strerror(code)))"
            }
        }
    }

    /// At most `limit` bytes of the regular file at `url`. With `followSymlinks` false a link at
    /// the final path component is refused (`unreadable(ELOOP)`) instead of opened, and a file
    /// with more than one hard link is refused (`unreadable(EMLINK)`) and logged. With `root`,
    /// `url` must sit below it: a link anywhere below `root` is refused too when not following,
    /// and the opened file's real path must be inside `root`'s, else `unreadable(ELOOP)`.
    static func read(
        _ url: URL, limit: Int, followSymlinks: Bool = true, inside root: URL? = nil
    ) throws -> Data {
        let descriptor = try openRegular(url, followSymlinks: followSymlinks, inside: root)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw Failure.unreadable(EIO)
        }
        guard data.count <= limit else { throw Failure.tooLarge }
        return data
    }

    /// The last `limit` bytes of the regular file at `url` and whether the file was longer. Same
    /// open as `read` (non-blocking, type checked on the descriptor), for logs that may be large.
    static func readTail(
        _ url: URL, limit: Int, followSymlinks: Bool = false
    ) throws -> (data: Data, truncated: Bool) {
        let descriptor = try openRegular(url, followSymlinks: followSymlinks, inside: nil)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.unreadable(errno) }
        let size = UInt64(max(info.st_size, 0))
        let truncated = size > UInt64(limit)
        do {
            try handle.seek(toOffset: truncated ? size - UInt64(limit) : 0)
            return (try handle.read(upToCount: limit) ?? Data(), truncated)
        } catch {
            throw Failure.unreadable(EIO)
        }
    }

    /// An open descriptor on the regular file at `url`, the caller's to close. Non-blocking, so
    /// a FIFO cannot hang the open; the type is checked on the descriptor.
    private static func openRegular(
        _ url: URL, followSymlinks: Bool, inside root: URL?
    ) throws -> Int32 {
        let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
        let descriptor: Int32
        if let root {
            descriptor = try openBelow(root, url, flags: flags, followSymlinks: followSymlinks)
        } else {
            descriptor = open(url.path, flags | (followSymlinks ? 0 : O_NOFOLLOW))
            guard descriptor >= 0 else { throw Failure.unreadable(errno) }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.unreadable(code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw Failure.notRegular
        }
        // A second hard link is a way in that O_NOFOLLOW cannot see; logged, never silent.
        guard followSymlinks || info.st_nlink <= 1 else {
            close(descriptor)
            AppLogger.event(.collect, .error,
                "\(ConfigSchema.displayText(url.lastPathComponent)) not read: it has "
                    + "\(info.st_nlink) hard links")
            throw Failure.unreadable(EMLINK)
        }
        return descriptor
    }

    /// `url` opened relative to `root`. O_NOFOLLOW_ANY on an absolute path would also refuse
    /// `/var` -> `/private/var` and a linked workspace root, so `root` (trusted, its links
    /// followed) is opened first and the flag covers only the components below it.
    private static func openBelow(
        _ root: URL, _ url: URL, flags: Int32, followSymlinks: Bool
    ) throws -> Int32 {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts
        else { throw Failure.unreadable(ELOOP) }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw Failure.unreadable(errno) }
        defer { close(rootDescriptor) }
        let relative = parts.dropFirst(rootParts.count).joined(separator: "/")
        let descriptor = openat(
            rootDescriptor, relative, flags | (followSymlinks ? 0 : O_NOFOLLOW_ANY))
        guard descriptor >= 0 else { throw Failure.unreadable(errno) }
        // The kernel's paths for both, so a link followed or a folder moved out mid-walk is caught.
        guard let rootPath = realPath(of: rootDescriptor),
              let filePath = realPath(of: descriptor),
              filePath.count > rootPath.count,
              Array(filePath.prefix(rootPath.count)) == rootPath else {
            close(descriptor)
            throw Failure.unreadable(ELOOP)
        }
        return descriptor
    }

    /// The path components the kernel holds for `descriptor` (`F_GETPATH`).
    private static func realPath(of descriptor: Int32) -> [String]? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).pathComponents
    }

    /// Largest small JSON document worth reading from a folder a peer can write (a run's
    /// status file, a per-run summary): a few hundred bytes to a few KB when genuine.
    static let documentLimit = 1_048_576

    /// Largest cached `pro audit` or group-tools snapshot read for the Audit screen.
    static let snapshotLimit = 64 * 1024 * 1024

    /// Largest inventory snapshot: a large district's `mobile-devices-list`, `computers` or
    /// `ea-results` passes 64 MB.
    static let inventoryLimit = 256 * 1024 * 1024

    /// The kinds whose rows grow with the fleet; every reader of one shares `inventoryLimit`.
    private static let inventoryKinds = [
        "ea-results", "computers", "computers-list", "mobile-devices-list",
        "mobile-device-inventory-details",
    ]

    /// The read limit for a snapshot of `kind` (`_` and `-` are one spelling).
    static func limit(forKind kind: String) -> Int {
        inventoryKinds.contains(kind.replacingOccurrences(of: "_", with: "-"))
            ? inventoryLimit : snapshotLimit
    }

    /// The read limit for the snapshot file `url`, from its kind: the folder it sits in, else
    /// the flat `<kind>-<stamp>` file name.
    static func limit(for url: URL) -> Int {
        let folder = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent.replacingOccurrences(of: "_", with: "-")
        let isInventory = limit(forKind: folder) == inventoryLimit
            || inventoryKinds.contains { name.hasPrefix($0 + "-") }
        return isInventory ? inventoryLimit : snapshotLimit
    }

    /// A handle on the regular file at `url` for a reader that seeks or streams: opened
    /// non-blocking (a FIFO cannot hang the open), a link or a second hard link refused, the
    /// type checked on the descriptor. The handle closes when released.
    static func openChecked(_ url: URL) throws -> FileHandle {
        let descriptor = try openRegular(url, followSymlinks: false, inside: nil)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// SHA-256 of the regular file at `url`, hashed in 1 MB chunks through `openChecked`, so
    /// a workbook of any size is neither held in memory nor read twice. Exactly the size
    /// `fstat` gave at open is hashed, so a file a peer keeps growing cannot stretch the read.
    /// Nil when unreadable or shorter than that size.
    static func sha256Hex(_ url: URL) -> String? {
        fingerprint(url)?.sha256
    }

    /// `sha256Hex` with the size it hashed. With `root`, a link anywhere below it is refused, as
    /// `read(inside:)` does, so a run manifest lists only files that are in its folder.
    static func fingerprint(_ url: URL, inside root: URL? = nil) -> (sha256: String, size: Int)? {
        guard let descriptor = try? openRegular(url, followSymlinks: false, inside: root)
        else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let size = Int(max(info.st_size, 0))
        var remaining = size
        var hasher = SHA256()
        while remaining > 0 {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: min(remaining, 1_048_576)) } catch {
                return nil
            }
            // nil or empty before the size is reached: the file shrank under the read.
            guard let chunk, !chunk.isEmpty else { return nil }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    /// The one reader of a snapshot, summary, cache or log file the picker chose: `read` refusing a
    /// link or a second hard link, or nil. A missing file is nil with no line; a file over
    /// `limit`, not a regular file or otherwise unreadable is logged by name, so a file left
    /// unread is never silent. Callers read nil as "not read", never as an empty snapshot. The
    /// limit defaults to the file's kind (`limit(for:)`). `root` is the folder the caller holds
    /// (a data folder), as the caller holds it: `read(inside:)` follows its own links, then
    /// refuses a link at any component below it, so a kind folder that is a link is refused.
    static func readLogged(
        _ url: URL, limit: Int? = nil, inside root: URL? = nil,
        category: AppLogger.Category = .collect
    ) -> Data? {
        let limit = limit ?? Self.limit(for: url)
        do {
            return try read(url, limit: limit, followSymlinks: false, inside: root)
        } catch let failure as Failure {
            // EMLINK is logged by the open itself.
            if failure == .unreadable(ENOENT) || failure == .unreadable(EMLINK) { return nil }
            let name = ConfigSchema.displayText(url.lastPathComponent)
            let detail = failure == .tooLarge
                ? "over \(limit / 1_048_576) MB" : failure.localizedDescription
            AppLogger.event(category, .error, "\(name) not read: \(detail)")
            return nil
        } catch {
            return nil
        }
    }

    /// Largest cached single-device record.
    static let deviceDetailLimit = 16 * 1024 * 1024

    /// Largest workspace state file worth reading (day markers, the alert ledger, `state/`):
    /// each is a line or a small JSON document, so anything bigger is corrupt or planted.
    static let stateFileLimit = 64 * 1024

    /// A state file in a folder another Mac can write, or nil when it is absent, a link, not a
    /// regular file or over `limit`; callers read nil as "no record" (#207 M2).
    static func stateData(
        _ url: URL, limit: Int = stateFileLimit, inside root: URL? = nil
    ) -> Data? {
        try? read(url, limit: limit, followSymlinks: false, inside: root)
    }

    /// `stateData` as UTF-8 text.
    static func stateText(
        _ url: URL, limit: Int = stateFileLimit, inside root: URL? = nil
    ) -> String? {
        stateData(url, limit: limit, inside: root).flatMap { String(data: $0, encoding: .utf8) }
    }
}
