import Foundation

/// A snapshot that is there but could not be read. Kept apart from "no earlier file", so a
/// change count reads "Could not be read" instead of disappearing as if nothing was compared.
struct SnapshotReadFailure: Error, Sendable, Equatable {
    let reason: ComputerChanges.UnreadableReason

    init(_ reason: ComputerChanges.UnreadableReason) { self.reason = reason }

    /// Over the read limit is `tooLarge`; a refused link, any other read error or a decode
    /// failure is `undecodable`.
    init(_ error: Error) {
        reason = (error as? BoundedFile.Failure) == .tooLarge ? .tooLarge : .undecodable
    }

    var text: String { reason == .tooLarge ? "over the read limit" : "it did not decode" }
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
            return .failure(SnapshotReadFailure(error))
        }
    }
}
