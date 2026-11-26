import Foundation

/// Which "Since last collect" count a Computers list was opened from (wave B2c).
enum ChangeKind: String, Sendable, CaseIterable, Codable {
    case joined, left, becameStale, noLongerStale, fileVaultOff, fileVaultStoppedReporting
    case osChanged, patchStarted, patchNoLongerListed

    var isPatch: Bool { self == .patchStarted || self == .patchNoLongerListed }

    var label: String {
        switch self {
        case .joined: L("Enrolled")
        case .left: L("Removed")
        case .becameStale: L("Went stale")
        case .noLongerStale: L("Checking in again")
        case .fileVaultOff: L("FileVault turned off")
        case .fileVaultStoppedReporting: L("FileVault stopped reporting")
        case .osChanged: L("macOS version changed")
        case .patchStarted: L("Started failing a patch policy")
        case .patchNoLongerListed: L("No longer listed as failed")
        }
    }

    func count(in part: ComputerChanges) -> Int? {
        switch self {
        case .joined: part.joined
        case .left: part.left
        case .becameStale: part.becameStale
        case .noLongerStale: part.noLongerStale
        case .fileVaultOff: part.fileVaultOff
        case .fileVaultStoppedReporting: part.fileVaultStoppedReporting
        case .osChanged: part.osChanged
        case .patchStarted, .patchNoLongerListed: nil
        }
    }

    func count(in part: PatchChanges) -> Int? {
        switch self {
        case .patchStarted: part.startedFailing
        case .patchNoLongerListed: part.stoppedFailing
        default: nil
        }
    }
}

/// The two snapshots behind one count, and the rule the count was taken under, so the
/// Computers screen can rebuild the same list. Travels as JSON in `.navigateToTab`'s
/// user info, which holds plain values only.
struct ChangeFilter: Sendable, Hashable, Codable {
    var kind: ChangeKind
    var currentStamp: String
    var baselineStamp: String
    /// The `computers` file a patch count's dropped pairs were checked against.
    var computersStamp: String?
    var fileVaultRule: String?
    var staleDays: Int?
    var staleBasis: [String]?

    static let userInfoKey = "changeFilter"

    /// Nil for a count of 0 or not measured, an unreadable baseline, or a stamp that is not a
    /// snapshot stamp (it names a file, so it is never trusted as a path).
    static func from(_ part: ComputerChanges, kind: ChangeKind) -> ChangeFilter? {
        guard !kind.isPatch, part.baselineUnreadable != true,
              let count = kind.count(in: part), count > 0,
              let current = validStamp(part.currentStamp),
              let baseline = validStamp(part.baselineStamp) else { return nil }
        return ChangeFilter(
            kind: kind, currentStamp: current, baselineStamp: baseline,
            fileVaultRule: part.fileVaultRule, staleDays: part.staleDays,
            staleBasis: part.staleBasis)
    }

    /// Nil also without a `computers_stamp`, which summaries before B2c lack.
    static func from(_ part: PatchChanges, kind: ChangeKind) -> ChangeFilter? {
        guard kind.isPatch, let count = kind.count(in: part), count > 0,
              let current = validStamp(part.currentStamp),
              let baseline = validStamp(part.baselineStamp),
              let computers = validStamp(part.computersStamp) else { return nil }
        return ChangeFilter(
            kind: kind, currentStamp: current, baselineStamp: baseline,
            computersStamp: computers)
    }

    private static func validStamp(_ stamp: String?) -> String? {
        guard let stamp, PatchReleaseDateService.stampDate(stamp) != nil else { return nil }
        return stamp
    }

    var baselineDate: Date? { PatchReleaseDateService.stampDate(baselineStamp) }

    /// This filter with another kind of the same pair; the cache holds every kind of a pair.
    func with(kind: ChangeKind) -> ChangeFilter {
        var copy = self
        copy.kind = kind
        return copy
    }

    var json: String? {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    init?(json: String) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
              Self.validStamp(decoded.currentStamp) != nil,
              Self.validStamp(decoded.baselineStamp) != nil,
              decoded.computersStamp.map({ Self.validStamp($0) != nil }) ?? !decoded.kind.isPatch
        else { return nil }
        self = decoded
    }

    init(
        kind: ChangeKind, currentStamp: String, baselineStamp: String,
        computersStamp: String? = nil, fileVaultRule: String? = nil, staleDays: Int? = nil,
        staleBasis: [String]? = nil
    ) {
        self.kind = kind
        self.currentStamp = currentStamp
        self.baselineStamp = baselineStamp
        self.computersStamp = computersStamp
        self.fileVaultRule = fileVaultRule
        self.staleDays = staleDays
        self.staleBasis = staleBasis
    }

    func navigationUserInfo() -> [String: String] {
        var info = ["tab": Tab.devices.rawValue]
        info[Self.userInfoKey] = json
        return info
    }

    /// Only a post to Computers carries one, as `DeviceFilter.pending`.
    static func pending(from userInfo: [AnyHashable: Any]?, destination: Tab) -> String? {
        guard destination == .devices else { return nil }
        return userInfo?[userInfoKey] as? String
    }
}

/// A Mac a change list names: by Jamf ID, then serial, never by name.
struct MacKey: Sendable, Hashable {
    var jamfID: String?
    var serial: String?
}

struct ChangeFilterResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case macs([MacKey])
        case left([ComputerDates])
        case fileGone
        case unreadable(ComputerChanges.UnreadableReason)
        case cancelled
    }

    var outcome: Outcome
    /// The rule this kind depends on differs from the one the count was taken under.
    var ruleChanged: Bool = false
    /// Patch kinds: the policy failures behind the Macs, which is what the stored count holds.
    var failures: Int?
}

/// Finds the records a change list names, with `ComputerDateIndex`'s rules: an identifier two
/// keys share finds neither, and a serial never matches a record whose Jamf ID differs.
struct ChangeMatch: Sendable {
    private let index: ComputerDateIndex
    private let keyCount: Int

    init(_ keys: [MacKey]) {
        let unique = Array(Set(keys))
        index = ComputerDateIndex(unique.map { ComputerDates(jamfID: $0.jamfID, serial: $0.serial) })
        keyCount = unique.count
    }

    func contains(_ record: DeviceInventoryRecord) -> Bool {
        index.match(jamfID: record.jamfID, serial: record.serial) != nil
    }

    /// The keys no record matched: Macs from that comparison missing from today's list.
    func unmatchedCount(in records: [DeviceInventoryRecord]) -> Int {
        var matched = Set<ComputerDates>()
        for record in records {
            if let key = index.match(jamfID: record.jamfID, serial: record.serial) {
                matched.insert(key)
            }
        }
        return keyCount - matched.count
    }
}
