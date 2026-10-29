import Foundation
import os

/// Puts a staged file or folder at its final name in one step, never following a link at that
/// name: `renamex_np` swaps the two entries (or, with nothing there, links the staged one in
/// exclusively), and the entry swapped out is removed after an `lstat`, so a link planted at the
/// final name is dropped, not written through. `FileManager.replaceItemAt` does neither check.
enum AtomicInstall {

    /// `staged` and `final` must be on one volume (stage in the final folder's own folder).
    /// On a volume without swap support (some network shares) the old entry is renamed aside,
    /// the staged one renamed in, and the old one removed, which leaves a short gap with no
    /// entry at the final name but still never follows a link.
    static func install(_ staged: URL, at final: URL) throws {
        var lastError: Int32 = EEXIST
        for _ in 0..<2 {
            let exists = isEntry(final)
            let flags = UInt32(exists ? RENAME_SWAP : RENAME_EXCL)
            if renamex_np(staged.path, final.path, flags) == 0 {
                if exists { discard(staged) }
                return
            }
            lastError = errno
            switch lastError {
            case EEXIST, ENOENT: continue  // something appeared or went in between: look again
            case ENOTSUP, EINVAL: return try installByRename(staged, at: final)
            default: throw POSIXError(POSIXErrorCode(rawValue: lastError) ?? .EIO)
            }
        }
        throw POSIXError(POSIXErrorCode(rawValue: lastError) ?? .EIO)
    }

    /// Folders `write` has already swept in this process: a crash leftover is from an earlier
    /// run, so one sweep per folder is enough and a busy writer does not list it every time.
    private static let sweptFolders = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Writes `data` to `final` through a hidden sibling opened exclusively (`O_EXCL|O_NOFOLLOW`),
    /// then `install`s it, so a link planted at `final` is replaced and a crash leaves the old
    /// file or the new one. `mode` is the file's permission bits; nil keeps those of a regular
    /// file already at `final` (as `replaceItemAt` did), else the process default.
    static func write(
        _ data: Data, to final: URL, mode: mode_t? = nil, now: Date = Date()
    ) throws {
        let folder = final.deletingLastPathComponent()
        if sweptFolders.withLock({ $0.insert(folder.path).inserted }) {
            removeStaleStaging(in: folder, now: now, scope: .workspace)
        }
        var existing = stat()
        let held = lstat(final.path, &existing) == 0 && (existing.st_mode & S_IFMT) == S_IFREG
            ? existing.st_mode & 0o777 : nil
        let exact = mode ?? held
        let staged = stagedURL(for: final)
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, exact ?? 0o666)
        guard fd >= 0 else { throw posixError() }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            if let exact, fchmod(fd, exact) != 0 { throw posixError() }
            try handle.write(contentsOf: data)
            try handle.close()
            try install(staged, at: final)
        } catch {
            discard(staged)
            throw error
        }
    }

    private static func installByRename(_ staged: URL, at final: URL) throws {
        guard isEntry(final) else {
            guard rename(staged.path, final.path) == 0 else { throw posixError() }
            return
        }
        let aside = stagedURL(for: final, isDirectory: false)
        guard rename(final.path, aside.path) == 0 else { throw posixError() }
        // A rename keeps the old mtime, which a sweep would read as stale at once.
        lutimes(aside.path, nil)
        guard rename(staged.path, final.path) == 0 else {
            let failure = posixError()
            _ = rename(aside.path, final.path)
            throw failure
        }
        discard(aside)
    }

    /// True when something, a dangling link included, is at `url`.
    private static func isEntry(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// How long a staging entry a crashed run left behind is kept before the next run removes it.
    static let staleStagingAge: TimeInterval = 24 * 3600

    /// Most entries of a folder `removeStaleStaging` looks at; a folder with more is swept only
    /// as far as that.
    static let maxStagingEntriesRead = 500

    /// The one staging name: a hidden sibling `.<name>.tmp-<uuid>`. Every stager (`write`, the
    /// rename-aside fallback, `Workbook.write`, the CSV folder) builds its name here and
    /// `removeStaleStaging` reads it back, so the two cannot drift.
    static func stagedURL(for final: URL, isDirectory: Bool = false) -> URL {
        final.deletingLastPathComponent().appendingPathComponent(
            ".\(final.lastPathComponent)\(stagingMarker)\(UUID().uuidString)",
            isDirectory: isDirectory)
    }

    private static let stagingMarker = ".tmp-"

    /// Which staged shapes a sweep removes. `reports`: the folder a person chose for reports,
    /// so only what the report writers stage (a `.xlsx`, run manifest or `.tsr` file, a `_csv`
    /// folder). `workspace`: a
    /// folder the app confines and owns, so any staged regular file (`.json`, `.last`, config);
    /// a staged folder is a `_csv` one in both scopes.
    enum StagingScope: Sendable {
        case reports, workspace

        fileprivate func stages(original: Substring, isDirectory: Bool) -> Bool {
            if isDirectory { return original.hasSuffix(ReportEngine.csvFolderSuffix) }
            return self == .workspace || original.hasSuffix(".xlsx")
                || original.hasSuffix(RunManifest.manifestSuffix)
                || original.hasSuffix("." + RunManifest.timestampExtension)
        }
    }

    /// Removes the staging entries a crash, or the tick's give-up exit, left in `parent`, older
    /// than `staleStagingAge`: hidden `.<name>.tmp-<uuid>` entries (the UUID must parse) of the
    /// shapes `scope` lists, each `lstat`-checked; a link is never touched. Another tool's
    /// `.tmp-` files in a folder a person chose are left alone.
    static func removeStaleStaging(
        in parent: URL, now: Date, scope: StagingScope = .reports
    ) {
        guard let entries = FileManager.default.enumerator(
            at: parent, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        else { return }
        var read = 0
        for case let url as URL in entries {
            read += 1
            if read > maxStagingEntriesRead { return }
            let name = url.lastPathComponent
            guard name.hasPrefix("."),
                  let marker = name.range(of: stagingMarker, options: .backwards),
                  UUID(uuidString: String(name[marker.upperBound...])) != nil else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR,
                  scope.stages(original: name[..<marker.lowerBound], isDirectory: kind == S_IFDIR)
            else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) > staleStagingAge { discard(url) }
        }
    }

    /// Removes what `url` names: a real folder with its contents, anything else (a link
    /// included) as the one entry. Never follows a link.
    static func discard(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            try? FileManager.default.removeItem(at: url)
        } else {
            unlink(url.path)
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
