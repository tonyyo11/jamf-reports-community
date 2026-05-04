import Darwin
import Dispatch
import Foundation

enum InboxFileStatus: String, Sendable {
    case pending
    case consumed
    case archived
}

struct InboxFile: Identifiable, Sendable {
    var id: String { "\(status.rawValue)/\(relativePath)" }
    let name: String
    let relativePath: String
    let size: String
    let mtime: Date
    let status: InboxFileStatus
}

struct CSVInboxService {
    enum ClearError: Error, LocalizedError, Equatable {
        case invalidProfile
        case invalidPath
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile:
                return "The selected workspace profile is not valid."
            case .invalidPath:
                return "The selected CSV is not inside the workspace inbox."
            case .missingFile(let name):
                return "\(name) no longer exists in the CSV inbox."
            }
        }
    }

    private let fileManager = FileManager.default

    func list(profile: String) -> [InboxFile] {
        guard let root = WorkspacePathGuard.root(for: profile) else { return [] }
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        guard let validatedInbox = WorkspacePathGuard.validate(inbox, under: root) else {
            return []
        }

        var results: [InboxFile] = []
        results.append(
            contentsOf: files(
                in: validatedInbox,
                status: nil,
                root: root,
                relativePrefix: nil
            )
        )

        let archive = validatedInbox.appendingPathComponent("archive", isDirectory: true)
        if let validatedArchive = WorkspacePathGuard.validate(archive, under: root) {
            results.append(
                contentsOf: files(
                    in: validatedArchive,
                    status: InboxFileStatus.archived,
                    root: root,
                    relativePrefix: "archive"
                )
            )
        }

        return results.sorted { $0.mtime > $1.mtime }
    }

    func clear(_ file: InboxFile, profile: String) throws {
        guard let root = WorkspacePathGuard.root(for: profile) else {
            throw ClearError.invalidProfile
        }
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        guard let validatedInbox = WorkspacePathGuard.validate(inbox, under: root),
              let url = url(for: file, inbox: validatedInbox, root: root) else {
            throw ClearError.invalidPath
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw ClearError.missingFile(file.name)
        }

        try fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: url.appendingPathExtension("consumed"))
    }

    private func files(
        in directory: URL,
        status forcedStatus: InboxFileStatus?,
        root: URL,
        relativePrefix: String?
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
                  WorkspacePathGuard.validate(candidate, under: root) != nil,
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
                name: candidate.lastPathComponent,
                relativePath: relativePath(for: candidate, prefix: relativePrefix),
                size: FileDisplay.size(Int64(size)),
                mtime: mtime,
                status: status
            )
        }
    }

    private func relativePath(for url: URL, prefix: String?) -> String {
        guard let prefix else { return url.lastPathComponent }
        return "\(prefix)/\(url.lastPathComponent)"
    }

    private func url(for file: InboxFile, inbox: URL, root: URL) -> URL? {
        let components = file.relativePath.split(separator: "/").map(String.init)
        guard components.count == 1 || components == ["archive", file.name],
              components.allSatisfy(isSafePathComponent),
              file.name == components.last,
              URL(fileURLWithPath: file.name).pathExtension.lowercased() == "csv" else {
            return nil
        }

        let directory = components.count == 2
            ? inbox.appendingPathComponent("archive", isDirectory: true)
            : inbox
        guard WorkspacePathGuard.validate(directory, under: root) != nil else { return nil }
        return directory.appendingPathComponent(file.name, isDirectory: false)
    }

    private func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\0")
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

    @MainActor
    final class DirectoryWatcher {
        // nonisolated(unsafe): accessed from deinit cleanup; all other access flows
        // through main-actor methods (start/stop/scheduleReload).
        private nonisolated(unsafe) var source: (any DispatchSourceFileSystemObject)?
        // nonisolated(unsafe): accessed from deinit cleanup; all other access flows
        // through main-actor methods (start/stop/scheduleReload).
        private nonisolated(unsafe) var debounce: DispatchWorkItem?
        private var watchedPath: String?

        deinit {
            source?.cancel()
            debounce?.cancel()
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
                DispatchQueue.main.async {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }
}
