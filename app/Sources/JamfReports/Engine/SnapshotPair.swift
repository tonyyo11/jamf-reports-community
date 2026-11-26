import Foundation

/// A snapshot that is there but could not be read. Kept apart from "no earlier file", so a
/// change count reads "Could not be read" instead of disappearing as if nothing was compared.
struct SnapshotReadFailure: Error, Sendable, Equatable {
    let reason: ComputerChanges.UnreadableReason
    /// The file that could not be read, for the log line that names the input.
    var file: String?

    init(_ reason: ComputerChanges.UnreadableReason, file: URL? = nil) {
        self.reason = reason
        self.file = file.map { ConfigSchema.displayText($0.lastPathComponent) }
    }

    /// Over the read limit is `tooLarge`; a refused link or any other read error is
    /// `readError`. A decode failure is built as `.undecodable` by the caller that decodes.
    init(_ error: Error, file: URL? = nil) {
        self.init((error as? BoundedFile.Failure) == .tooLarge ? .tooLarge : .readError, file: file)
    }

    /// The one change-count warning: which file, why, and which part goes unmeasured.
    func logLine(part: String) -> String {
        "[warn] change counts: \(file ?? "a snapshot") could not be read (\(text)); "
            + "\(part) changes not measured"
    }

    var text: String { Self.text(reason) }

    static func text(_ reason: ComputerChanges.UnreadableReason) -> String {
        switch reason {
        case .tooLarge: "over the read limit"
        case .undecodable: "it did not decode"
        case .readError: "it could not be opened"
        }
    }
}

/// The one pairing of a snapshot with the newest one from an earlier local day, shared by the
/// Mac, benchmark and patch comparisons. A same-day rerun is never the baseline.
enum SnapshotPair {
    static func earlierDay(of kind: String, in dataDir: URL, before date: Date)
        -> (url: URL, date: Date)? {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        return TrendStore.datedSnapshots(of: kind, in: dataDir)
            .last { calendar.startOfDay(for: $0.date) < day }
    }

    /// The `kind` file stamped exactly `stamp` and its earlier-day baseline; nil when either
    /// is missing.
    static func landed(_ kind: String, in dataDir: URL, stamp: Date)
        -> (current: URL, baseline: URL)? {
        guard let current = TrendStore.datedSnapshots(of: kind, in: dataDir)
                .last(where: { $0.date == stamp }),
              let baseline = earlierDay(of: kind, in: dataDir, before: stamp)
        else { return nil }
        return (current.url, baseline.url)
    }

    /// The file's bytes, read with links refused and inside `dataDir`.
    static func read(_ url: URL, limit: Int, dataDir: URL) -> Result<Data, SnapshotReadFailure> {
        do {
            return .success(try BoundedFile.read(
                url, limit: limit, followSymlinks: false, inside: dataDir))
        } catch {
            return .failure(SnapshotReadFailure(error, file: url))
        }
    }
}
