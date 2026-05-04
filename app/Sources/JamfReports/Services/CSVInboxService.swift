import Darwin
import Dispatch
import Foundation

enum InboxFileStatus: String, Sendable {
    case pending
    case consumed
    case archived
}

struct InboxFile: Identifiable, Sendable {
    var id: String { "\(status.rawValue)/\(name)" }
    let name: String
    let size: String
    let mtime: Date
    let status: InboxFileStatus
}

struct CSVInboxService {
    private let fileManager = FileManager.default

    func list(profile: String) -> [InboxFile] {
        guard let root = WorkspacePathGuard.root(for: profile) else { return [] }
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        guard let validatedInbox = WorkspacePathGuard.validate(inbox, under: root) else {
            return []
        }

        var results: [InboxFile] = []
        results.append(contentsOf: files(in: validatedInbox, status: nil, root: root))

        let archive = validatedInbox.appendingPathComponent("archive", isDirectory: true)
        if let validatedArchive = WorkspacePathGuard.validate(archive, under: root) {
            results.append(
                contentsOf: files(
                    in: validatedArchive,
                    status: InboxFileStatus.archived,
                    root: root
                )
            )
        }

        return results.sorted { $0.mtime > $1.mtime }
    }

    private func files(
        in directory: URL,
        status forcedStatus: InboxFileStatus?,
        root: URL
    ) -> [InboxFile] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { candidate in
            guard candidate.pathExtension.lowercased() == "csv",
                  let validated = WorkspacePathGuard.validate(candidate, under: root),
                  let values = try? candidate.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ]
                  ),
                  values.isRegularFile == true || values.isSymbolicLink == true,
                  let size = values.fileSize,
                  let mtime = values.contentModificationDate else {
                return nil
            }

            let status = forcedStatus ?? inferredStatus(for: candidate, values: values)
            return InboxFile(
                name: validated.lastPathComponent,
                size: FileDisplay.size(Int64(size)),
                mtime: mtime,
                status: status
            )
        }
    }

    private func inferredStatus(for url: URL, values: URLResourceValues) -> InboxFileStatus {
        if values.isSymbolicLink == true { return .consumed }
        if hasConsumedSentinel(for: url) { return .consumed }
        return .pending
    }

    private func hasConsumedSentinel(for url: URL) -> Bool {
        let direct = url.appendingPathExtension("consumed")
        let dotfile = url.deletingLastPathComponent().appendingPathComponent(".consumed")
        return fileManager.fileExists(atPath: direct.path)
            || fileManager.fileExists(atPath: dotfile.path)
    }

    final class DirectoryWatcher: @unchecked Sendable {
        private var source: DispatchSourceFileSystemObject?
        private var debounce: DispatchWorkItem?
        private var watchedPath: String?

        deinit {
            stop()
        }

        func start(profile: String, onChange: @escaping @MainActor () -> Void) {
            guard let root = WorkspacePathGuard.root(for: profile) else {
                stop()
                return
            }
            let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
            guard let validatedInbox = WorkspacePathGuard.validate(inbox, under: root) else {
                stop()
                return
            }

            if watchedPath == validatedInbox.path { return }
            stop()
            watchedPath = validatedInbox.path

            let descriptor = Darwin.open(validatedInbox.path, O_EVTONLY)
            guard descriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.scheduleReload(onChange: onChange)
                }
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            self.source = source
            source.resume()
        }

        func stop() {
            debounce?.cancel()
            debounce = nil
            source?.cancel()
            source = nil
            watchedPath = nil
        }

        private func scheduleReload(onChange: @escaping @MainActor () -> Void) {
            debounce?.cancel()
            let work = DispatchWorkItem {
                Task { @MainActor in
                    onChange()
                }
            }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }
}
