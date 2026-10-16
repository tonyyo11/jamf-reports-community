import Foundation

/// A read of a file another Mac can write, bounded in size and type. The file is opened once
/// (non-blocking, so a FIFO planted at the name cannot hang the open), its type is checked on
/// that descriptor, and the bytes come from the same descriptor, so the check and the read
/// cannot be about two different files.
enum BoundedFile {

    enum Failure: Error, Equatable {
        /// A FIFO, device, socket or directory.
        case notRegular
        /// More than `limit` bytes; `read` stopped at `limit + 1`.
        case tooLarge
        /// `open` or `read` failed with this errno (ENOENT is a missing file).
        case unreadable(Int32)
    }

    /// At most `limit` bytes of the regular file at `url`. With `followSymlinks` false a link at
    /// the final path component is refused (`unreadable(ELOOP)`) instead of opened.
    static func read(_ url: URL, limit: Int, followSymlinks: Bool = true) throws -> Data {
        let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followSymlinks ? 0 : O_NOFOLLOW)
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else { throw Failure.unreadable(errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.unreadable(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notRegular }
        let data: Data
        do {
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw Failure.unreadable(EIO)
        }
        guard data.count <= limit else { throw Failure.tooLarge }
        return data
    }

    /// Largest workspace state file worth reading (day markers, the alert ledger, `state/`):
    /// each is a line or a small JSON document, so anything bigger is corrupt or planted.
    static let stateFileLimit = 64 * 1024

    /// A state file in a folder another Mac can write, or nil when it is absent, a link, not a
    /// regular file or over `limit`; callers read nil as "no record" (#207 M2).
    static func stateData(_ url: URL, limit: Int = stateFileLimit) -> Data? {
        try? read(url, limit: limit, followSymlinks: false)
    }

    /// `stateData` as UTF-8 text.
    static func stateText(_ url: URL, limit: Int = stateFileLimit) -> String? {
        stateData(url, limit: limit).flatMap { String(data: $0, encoding: .utf8) }
    }
}
