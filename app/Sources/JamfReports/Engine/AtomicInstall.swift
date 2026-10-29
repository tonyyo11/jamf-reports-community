import Foundation

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

    private static func installByRename(_ staged: URL, at final: URL) throws {
        guard isEntry(final) else {
            guard rename(staged.path, final.path) == 0 else { throw posixError() }
            return
        }
        let aside = final.deletingLastPathComponent()
            .appendingPathComponent(".\(final.lastPathComponent).old-\(UUID().uuidString)")
        guard rename(final.path, aside.path) == 0 else { throw posixError() }
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

    /// Removes the staging entries a crash, or the tick's give-up exit, left in `parent`, older
    /// than `staleStagingAge`: hidden `.<name>.tmp-<uuid>` regular files (a workbook) and, when
    /// the name ends in `_csv`, real folders (a CSV folder). In a shared reports folder nothing
    /// else would move them. Each is `lstat`-checked; a link is never touched.
    static func removeStaleStaging(in parent: URL, now: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path)
        else { return }
        for name in names where name.hasPrefix(".") {
            guard let marker = name.range(of: ".tmp-", options: .backwards),
                  UUID(uuidString: String(name[marker.upperBound...])) != nil else { continue }
            let url = parent.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG: break
            case S_IFDIR where name[..<marker.lowerBound].hasSuffix(ReportEngine.csvFolderSuffix): break
            default: continue
            }
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
