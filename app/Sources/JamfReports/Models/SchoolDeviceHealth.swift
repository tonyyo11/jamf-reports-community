import Foundation

/// What a Jamf School workspace's snapshots say about its devices, users, groups and classes:
/// one calculation the Overview card and the workbook's Device Health tab both read. Every
/// figure is a neutral count "N of M": an empty group or a class with no teacher is a normal
/// state in a district, so nothing here is graded. A figure is nil, never 0 of 0, when its
/// snapshot is missing or no row reports the field; a snapshot that could not be read is
/// `unreadable`, not empty.
struct SchoolDeviceHealth: Sendable, Equatable {

    enum Item: String, CaseIterable, Sendable {
        case adeNotEnrolled, usersNoDevice, groupsNoMembers, smartGroupsNoMembers
        case classesNoDevices, classesNoStudents, classesNoTeacher

        var title: String {
            switch self {
            case .adeNotEnrolled: L("Automated Device Enrollment devices not enrolled")
            case .usersNoDevice: L("Users with no device")
            case .groupsNoMembers: L("Device groups with no members")
            case .smartGroupsNoMembers: L("Smart device groups with no members")
            case .classesNoDevices: L("Classes with no devices")
            case .classesNoStudents: L("Classes with no students")
            case .classesNoTeacher: L("Classes with no teacher")
            }
        }

        var unit: String {
            switch self {
            case .adeNotEnrolled: L("devices")
            case .usersNoDevice: L("users")
            case .groupsNoMembers, .smartGroupsNoMembers: L("groups")
            case .classesNoDevices, .classesNoStudents, .classesNoTeacher: L("classes")
            }
        }

        /// The snapshot kinds the figure reads; any unreadable one makes it unreadable.
        var kinds: [String] {
            switch self {
            case .adeNotEnrolled:
                [SchoolFleetService.depDevicesKind, SchoolFleetService.devicesKind]
            case .usersNoDevice: [SchoolFleetService.usersKind]
            case .groupsNoMembers, .smartGroupsNoMembers: [SchoolFleetService.groupsKind]
            default: [SchoolFleetService.classesKind]
            }
        }
    }

    struct Figure: Sendable, Equatable {
        let count: Int
        let of: Int
    }

    /// Values and counts, most common first, at most `maxShown`; `distinct` is how many exist.
    struct Values: Sendable, Equatable {
        var shown: [(value: String, count: Int)] = []
        var distinct = 0

        static func == (a: Values, b: Values) -> Bool {
            a.distinct == b.distinct && a.shown.count == b.shown.count
                && zip(a.shown, b.shown).allSatisfy { $0 == $1 }
        }
    }

    static let maxShown = ManagementHealth.maxShownValues

    private(set) var figures: [Item: Figure] = [:]
    private(set) var unreadable: Set<Item> = []
    /// The DEP rows by `status`, as School gives it; empty when none carries one.
    private(set) var depStatuses = Values()
    /// The not-enrolled DEP rows by enrollment profile; a blank name reads "No profile".
    private(set) var notEnrolledProfiles = Values()
    /// The DEP rows counted in `.adeNotEnrolled`, in snapshot order.
    private(set) var notEnrolled: [SchoolFleetService.DEPDevice] = []

    /// Nil when the snapshot gives no figure and nothing unreadable to say.
    init?(_ snapshot: SchoolFleetService.Snapshot) {
        for item in Item.allCases
        where item.kinds.contains(where: snapshot.unreadable.contains) {
            unreadable.insert(item)
        }
        addEnrollment(snapshot)
        addUsers(snapshot)
        addGroups(snapshot)
        addClasses(snapshot)
        if figures.isEmpty && unreadable.isEmpty { return nil }
    }

    /// Items to show, in declaration order: those with a figure or unreadable.
    var items: [Item] {
        Item.allCases.filter { figures[$0] != nil || unreadable.contains($0) }
    }

    // MARK: - Figures

    private mutating func addEnrollment(_ snapshot: SchoolFleetService.Snapshot) {
        guard !unreadable.contains(.adeNotEnrolled) else { return }
        let withStatus = snapshot.depDevices.map(\.status).filter { !$0.isEmpty }
        depStatuses = Self.capped(Dictionary(withStatus.map { ($0, 1) }, uniquingKeysWith: +))
        guard snapshot.depDate != nil, snapshot.devicesDate != nil else { return }
        let enrolled = Set(snapshot.devices.map { Self.key($0.serial) })
        let reporting = snapshot.depDevices.filter { !Self.key($0.serial).isEmpty }
        guard !reporting.isEmpty else { return }
        notEnrolled = reporting.filter { !enrolled.contains(Self.key($0.serial)) }
        figures[.adeNotEnrolled] = Figure(count: notEnrolled.count, of: reporting.count)
        let profiles = notEnrolled.map { Self.profileName($0.profile) }
        notEnrolledProfiles = Self.capped(Dictionary(profiles.map { ($0, 1) }, uniquingKeysWith: +))
    }

    private mutating func addUsers(_ snapshot: SchoolFleetService.Snapshot) {
        guard let users = snapshot.users else { return }
        set(.usersNoDevice, users.map(\.deviceCount).map { $0.map { $0 == 0 } })
    }

    private mutating func addGroups(_ snapshot: SchoolFleetService.Snapshot) {
        guard let groups = snapshot.deviceGroups else { return }
        for (item, smart) in [(Item.groupsNoMembers, false), (.smartGroupsNoMembers, true)] {
            set(item, groups.map { $0.isSmart == smart ? $0.members.map { $0 == 0 } : nil })
        }
    }

    private mutating func addClasses(_ snapshot: SchoolFleetService.Snapshot) {
        guard let classes = snapshot.classes else { return }
        set(.classesNoDevices, classes.map { $0.devices.map { $0 == 0 } })
        set(.classesNoStudents, classes.map { $0.students.map { $0 == 0 } })
        set(.classesNoTeacher, classes.map { $0.teachers.map { $0 == 0 } })
    }

    /// `verdicts` has one entry per row: nil when the row does not report the field.
    private mutating func set(_ item: Item, _ verdicts: [Bool?]) {
        guard !unreadable.contains(item) else { return }
        let reported = verdicts.compactMap { $0 }
        guard !reported.isEmpty else { return }
        figures[item] = Figure(count: reported.filter { $0 }.count, of: reported.count)
    }

    // MARK: - Helpers

    /// A serial as joined: trimmed, case-insensitive.
    static func key(_ serial: String) -> String {
        serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func profileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("No profile") : trimmed
    }

    /// The values come from a snapshot a peer can write, so each goes through `displayText`.
    private static func capped(_ counts: [String: Int]) -> Values {
        let all = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
        let shown = all.prefix(maxShown).map {
            (value: ConfigSchema.displayText($0.key), count: $0.value)
        }
        return Values(shown: Array(shown), distinct: all.count)
    }

    /// "ASSIGNED 3 · PUSHED 1", with "5 of 12 values" when more exist than are shown.
    static func line(_ values: Values) -> String? {
        guard values.distinct > 0 else { return nil }
        let text = values.shown.map { "\($0.value) \($0.count)" }.joined(separator: " · ")
        return values.distinct > values.shown.count
            ? text + " · " + L("\(values.shown.count) of \(values.distinct) values") : text
    }
}
